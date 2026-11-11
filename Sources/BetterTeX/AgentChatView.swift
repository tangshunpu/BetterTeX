import AppKit
import BetterTeXCore

/// A native conversation with an agent CLI: the user's prompts, the agent's replies and a card for
/// each thing it did (commands, file changes, plans). Each prompt runs one non-interactive turn:
/// `codex exec --json` for Codex, `claude -p --output-format stream-json` for Claude.
final class AgentChatView: NSView {
    let provider: AgentProvider
    private var name: String { provider.rawValue }
    private enum Entry {
        case user(String)
        case item(CodexItem)
        case status(String, failed: Bool)
    }
    var onOpenFile: ((URL) -> Void)?
    /// Called when a turn starts or ends, and when the conversation is cleared.
    var onChange: (() -> Void)?
    /// Receives Codex's own start-up warnings (configuration notices), which stay out of the conversation.
    var onLog: ((String) -> Void)?
    private var turnStarted = false
    private(set) var running = false
    private(set) var thread: String?
    var isEmpty: Bool { order.isEmpty }

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let working = NSStackView()
    private let workingLabel = Theme.label("正在工作…", size: 12, color: Theme.muted)
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var rows: [String: NSView] = [:]
    private var expanded = Set<String>()
    private var notices = Set<String>()
    /// Identity of the turn in flight, and how to cancel it.
    private var turn: AnyObject?
    private var cancelTurn: (() -> Void)?
    private var turnNumber = 0
    private var started = Date()
    private var ticker: Timer?
    /// What the agent is doing right now; the working row shows it with the elapsed time.
    private var activity = "" { didSet { refreshWorking() } }
    private var directory: URL?
    private static let inset: CGFloat = 14

    init(provider: AgentProvider = .codex) {
        self.provider = provider
        super.init(frame: .zero)
        activity = "\(provider.rawValue) 正在工作…"
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: Self.inset, bottom: 12, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .small; spinner.startAnimation(nil)
        let stop = ActionButton("停止", symbol: "stop.fill", style: .tinted) { [weak self] in self?.stop() }
        working.setViews([spinner, workingLabel, NSView(), stop], in: .leading); working.spacing = 8; working.alignment = .centerY
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor), stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Conversation
    /// Starts a turn. `display` is what the user typed; `prompt` may add file context to it.
    func send(prompt: String, display: String, executable: String, directory: URL, environment: [String: String], configuration: AgentConfiguration, sandbox: CodexSandbox) {
        guard !running else { return }
        // Both CLIs speak through the same event model; only the process differs.
        let token = NSObject()
        let run: (@escaping (CodexEvent) -> Void) throws -> (status: Int32, stderr: String)
        do {
            switch provider {
            case .codex:
                let request = CodexRequest(prompt: prompt, thread: thread, configuration: configuration, sandbox: sandbox); _ = try request.arguments()
                let process = CodexTurn(); cancelTurn = { process.cancel() }
                run = { try process.run(request, executable: executable, directory: directory, environment: environment, onEvent: $0) }
            case .claude:
                let request = ClaudeRequest(prompt: prompt, session: thread, configuration: configuration, sandbox: sandbox); _ = try request.arguments()
                let process = ClaudeTurn(); cancelTurn = { process.cancel() }
                run = { try process.run(request, executable: executable, directory: directory, environment: environment, onEvent: $0) }
            }
        } catch { append("s\(UUID().uuidString)", .status(error.localizedDescription, failed: true)); return }
        turnNumber += 1; let number = turnNumber; turnStarted = false
        self.directory = directory
        append("u\(number)", .user(display))
        let turn = token; self.turn = turn; setRunning(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try run { event in
                DispatchQueue.main.async { if let self, self.turn === turn { self.handle(event, turn: number) } }
            } }
            DispatchQueue.main.async {
                guard let self, self.turn === turn else { return }
                self.turn = nil; self.cancelTurn = nil; self.setRunning(false)
                switch result {
                case .failure(let error): self.append("f\(number)", .status(error.localizedDescription, failed: true))
                case .success(let outcome):
                    // A turn that ended without a completion event failed before or outside the model call.
                    if outcome.status != 0, self.entries["d\(number)"] == nil {
                        let detail = outcome.stderr.components(separatedBy: "\n").last { !$0.isEmpty } ?? ""
                        self.append("f\(number)", .status("\(self.name) 退出（\(outcome.status)）" + (detail.isEmpty ? "" : "：\(detail)"), failed: true))
                    }
                }
            }
        }
    }
    func stop() {
        guard running, turn != nil else { return }
        cancelTurn?(); cancelTurn = nil; turn = nil; setRunning(false)
        append("f\(turnNumber)", .status("已停止", failed: false))
    }
    /// Forgets the conversation; the next prompt starts a new Codex thread.
    func reset() {
        cancelTurn?(); cancelTurn = nil; turn = nil; thread = nil; running = false
        entries.removeAll(); order.removeAll(); rows.removeAll(); expanded.removeAll(); notices.removeAll()
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        onChange?()
    }
    /// Continues a conversation recorded by the Codex CLI. Its earlier messages are not shown.
    func resume(thread: String, title: String) {
        reset(); self.thread = thread
        append("s\(UUID().uuidString)", .status("已接上之前的会话：\(title)。之前的消息不在这里显示，\(name) 仍记得上下文。", failed: false))
    }
    private var elapsed: String {
        let seconds = Int(Date().timeIntervalSince(started))
        return seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分 \(seconds % 60) 秒"
    }
    private func refreshWorking() { workingLabel.stringValue = running ? "\(activity)  \(elapsed)" : activity }
    private func setRunning(_ value: Bool) {
        running = value
        ticker?.invalidate(); ticker = nil
        if value {
            started = Date(); activity = "\(name) 正在工作…"
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshWorking() }
        }
        if value { if working.superview == nil { stack.addArrangedSubview(working); working.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Self.inset * 2).isActive = true } }
        else { stack.removeArrangedSubview(working); working.removeFromSuperview() }
        onChange?(); scrollToEnd()
    }
    private func handle(_ event: CodexEvent, turn number: Int) {
        switch event {
        case .threadStarted(let id): thread = id
        case .turnStarted: turnStarted = true
        case .item(let item):
            if item.kind == .notice {
                guard notices.insert(item.text).inserted else { return }
                // Anything Codex says before the turn begins is about its own setup, not this conversation.
                if !turnStarted { onLog?(item.text); return }
            }
            if item.kind == .message || item.kind == .reasoning, item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            append("i\(number).\(item.id)", .item(item))
            activity = item.status != .running ? "\(name) 正在工作…" : item.kind == .command ? "正在运行命令…" : item.kind == .message ? "\(name) 正在回复…" : item.kind == .reasoning ? "\(name) 正在思考…" : item.kind == .fileChange ? "正在修改文件…" : "\(name) 正在工作…"
            // Streamed text grows in place; keep its tail in view.
            if item.status == .running, item.kind == .message || item.kind == .reasoning { scrollToEnd() }
        case .turnCompleted(let input, let output):
            func short(_ value: Int) -> String { value >= 1000 ? String(format: "%.1fk", Double(value) / 1000) : "\(value)" }
            append("d\(number)", .status("完成 · \(elapsed) · 输入 \(short(input)) / 输出 \(short(output)) tokens", failed: false))
        case .turnFailed(let message): append("d\(number)", .status(message, failed: true))
        }
    }

    // MARK: Rows
    private func append(_ key: String, _ entry: Entry) {
        let isNew = entries[key] == nil
        entries[key] = entry; if isNew { order.append(key) }
        let view = row(for: key, entry)
        if let old = rows[key], let index = stack.arrangedSubviews.firstIndex(of: old) {
            stack.removeArrangedSubview(old); old.removeFromSuperview(); stack.insertArrangedSubview(view, at: index)
        } else if running, let index = stack.arrangedSubviews.firstIndex(of: working) { stack.insertArrangedSubview(view, at: index) }
        else { stack.addArrangedSubview(view) }
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Self.inset * 2).isActive = true
        rows[key] = view
        if isNew { if order.count == 1 { onChange?() }; scrollToEnd() }
    }
    private func scrollToEnd() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let document = self.scroll.documentView else { return }
            self.layoutSubtreeIfNeeded()
            self.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - self.scroll.contentView.bounds.height)))
            self.scroll.reflectScrolledClipView(self.scroll.contentView)
        }
    }
    private func wrapped(_ text: NSAttributedString, selectable: Bool = true) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: ""); label.attributedStringValue = text; label.isSelectable = selectable
        label.setContentCompressionResistancePriority(.init(1), for: .horizontal); return label
    }
    private func plain(_ text: String, size: CGFloat = 13, color: NSColor = Theme.text, mono: Bool = false) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size), .foregroundColor: color])
    }
    /// Inline Markdown (bold, italic, code) as the agent writes it; block structure stays as typed.
    private func markdown(_ text: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else { return plain(text) }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = NSFont.systemFont(ofSize: 13, weight: intent.contains(.stronglyEmphasized) ? .semibold : .regular)
            if intent.contains(.code) { font = .monospacedSystemFont(ofSize: 12, weight: .regular) }
            else if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.text]
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
    private func card(_ content: NSView) -> NSView {
        let card = Chip(fill: Theme.fillSoft, radius: 10)
        content.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(content)
        NSLayoutConstraint.activate([content.topAnchor.constraint(equalTo: card.topAnchor, constant: 8), content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8), content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10), content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10)])
        return card
    }
    private func statusIcon(_ status: CodexItem.Status, symbol: String) -> NSView {
        if status == .running { let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .mini; spinner.startAnimation(nil); spinner.size(14, 14); return spinner }
        let image = NSImageView(image: Theme.symbol(status == .failed ? "xmark.circle.fill" : symbol, size: 12, weight: .semibold)!)
        image.contentTintColor = status == .failed ? Theme.red : Theme.muted; image.size(14, 14); return image
    }
    private func column(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let column = NSStackView(views: views); column.orientation = .vertical; column.alignment = .leading; column.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return column
    }
    // MARK: Claude Code styling
    // The Claude tab follows the Claude Code extension: a timeline of bulleted entries, each tool
    // named with its argument, results hanging beneath, and edits shown as coloured diffs.
    private static let claude = NSColor(hex: 0xD97757)
    private func timeline(_ color: NSColor, running: Bool = false, _ content: NSView) -> NSView {
        let marker: NSView
        if running { let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .mini; spinner.startAnimation(nil); spinner.size(11, 11); marker = spinner }
        else { let dot = Chip(fill: color, radius: -1); dot.size(7, 7); marker = dot }
        let gutter = NSView(); gutter.size(14, 18); marker.translatesAutoresizingMaskIntoConstraints = false; gutter.addSubview(marker)
        NSLayoutConstraint.activate([marker.centerXAnchor.constraint(equalTo: gutter.centerXAnchor), marker.topAnchor.constraint(equalTo: gutter.topAnchor, constant: running ? 3 : 5.5)])
        content.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = NSStackView(views: [gutter, content]); line.spacing = 6; line.alignment = .top
        return line
    }
    private func statusColor(_ status: CodexItem.Status) -> NSColor { status == .failed ? Theme.red : Theme.green }
    /// "Read  sections/intro.tex": the tool in bold, its argument in quiet monospace.
    private func toolTitle(_ tool: String, _ argument: String) -> NSTextField {
        let text = NSMutableAttributedString(string: tool, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Theme.text])
        if !argument.isEmpty { text.append(NSAttributedString(string: "  " + argument.replacingOccurrences(of: "\n", with: " ⏎ "), attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: Theme.muted])) }
        let label = wrapped(text); label.maximumNumberOfLines = 3; label.cell?.truncatesLastVisibleLine = true; label.toolTip = argument
        return label
    }
    private func hanging(_ text: String, failed: Bool = false) -> NSTextField {
        let label = wrapped(plain("⎿  " + text, size: 11.5, color: failed ? Theme.red : Theme.muted)); label.maximumNumberOfLines = 4; label.cell?.truncatesLastVisibleLine = true
        return label
    }
    private func box(_ content: NSView) -> NSView {
        let box = Chip(fill: Theme.fillSoft, radius: 7)
        content.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(content)
        NSLayoutConstraint.activate([content.topAnchor.constraint(equalTo: box.topAnchor, constant: 6), content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6), content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8), content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8)])
        return box
    }
    /// A long block shows its first or last lines with a toggle to see the rest.
    private func clipped(_ lines: [String], key: String, collapsed: Int, tail: Bool) -> (shown: [String], toggle: NSView?) {
        guard lines.count > collapsed else { return (lines, nil) }
        let open = expanded.contains(key)
        let toggle = ActionButton(open ? "收起" : "展开全部 \(lines.count) 行", symbol: open ? "chevron.up" : "chevron.down", style: .plain) { [weak self] in
            guard let self, let entry = self.entries[key] else { return }
            if self.expanded.contains(key) { self.expanded.remove(key) } else { self.expanded.insert(key) }
            self.append(key, entry)
        }
        return (open ? Array(lines.prefix(400)) : Array(tail ? lines.suffix(collapsed) : lines.prefix(collapsed)), toggle)
    }
    private func diffText(_ lines: [String]) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.muted]
            if line.hasPrefix("+") { attributes[.foregroundColor] = Theme.adaptive(0x1A7F37, 0x7EE787); attributes[.backgroundColor] = Theme.green.withAlphaComponent(0.14) }
            else if line.hasPrefix("-") { attributes[.foregroundColor] = Theme.adaptive(0xCF222E, 0xFF9A93); attributes[.backgroundColor] = Theme.red.withAlphaComponent(0.14) }
            result.append(NSAttributedString(string: (line.isEmpty ? " " : line) + (index < lines.count - 1 ? "\n" : ""), attributes: attributes))
        }
        return result
    }
    /// Message text with fenced code blocks set apart and Markdown headings shown bold.
    private func rich(_ text: String) -> NSView {
        let parts = text.components(separatedBy: "```")
        guard parts.count > 2 else { return wrapped(markdown(headings(text))) }
        var views: [NSView] = []
        for (index, part) in parts.enumerated() {
            if index % 2 == 1 {
                // Drop the language tag on the fence line.
                var code = part; if let newline = code.firstIndex(of: "\n") { code = String(code[code.index(after: newline)...]) }
                let body = code.trimmingCharacters(in: .newlines); if !body.isEmpty { views.append(box(wrapped(plain(body, size: 11.5, mono: true)))) }
            } else {
                let body = part.trimmingCharacters(in: .newlines); if !body.isEmpty { views.append(wrapped(markdown(headings(body)))) }
            }
        }
        return column(views)
    }
    private func headings(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            guard let range = line.range(of: "^#{1,6}\\s+", options: .regularExpression) else { return line }
            let title = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? line : "**\(title.replacingOccurrences(of: "**", with: ""))**"
        }.joined(separator: "\n")
    }
    private func claudeRow(for key: String, _ entry: Entry) -> NSView? {
        switch entry {
        case .status: return nil
        case .user(let text):
            let bubble = Chip(fill: Theme.fillSoft, radius: 8, border: Theme.adaptive(0x3C3C43, 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.12))
            let label = wrapped(plain(text)); label.translatesAutoresizingMaskIntoConstraints = false; bubble.addSubview(label)
            NSLayoutConstraint.activate([label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8), label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8), label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 10), label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -10)])
            bubble.setAccessibilityLabel("你：\(text)"); return bubble
        case .item(let item):
            let running = item.status == .running
            switch item.kind {
            case .message: return timeline(running ? Self.claude : Theme.text, rich(item.text.trimmingCharacters(in: .newlines)))
            case .reasoning:
                let font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
                let lines = item.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
                let (shown, toggle) = clipped(lines, key: key, collapsed: 3, tail: running)
                let label = wrapped(NSAttributedString(string: shown.joined(separator: "\n"), attributes: [.font: font, .foregroundColor: Theme.muted]))
                return timeline(Theme.faint, running: running, column([toolTitle("思考", ""), label] + (toggle.map { [$0] } ?? []), spacing: 3))
            case .notice: return timeline(Theme.orange, wrapped(plain(item.text, size: 11.5, color: Theme.orange)))
            case .toolCall, .webSearch:
                let parts = item.text.components(separatedBy: " · ")
                let tool = item.kind == .webSearch ? "Web" : parts[0], argument = item.kind == .webSearch ? item.text : parts.dropFirst().joined(separator: " · ")
                var views: [NSView] = [toolTitle(tool, argument)]
                if !item.detail.isEmpty { views.append(hanging(item.detail, failed: item.status == .failed)) }
                return timeline(statusColor(item.status), running: running, column(views, spacing: 2))
            case .todo:
                let text = NSMutableAttributedString()
                let lines = item.detail.components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.soft]
                    if line.hasPrefix("☑") { attributes[.foregroundColor] = Theme.faint; attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    else if line.hasPrefix("▸") { attributes[.foregroundColor] = Theme.text; attributes[.font] = NSFont.systemFont(ofSize: 12.5, weight: .semibold) }
                    text.append(NSAttributedString(string: line + (index < lines.count - 1 ? "\n" : ""), attributes: attributes))
                }
                return timeline(statusColor(item.status), running: running, column([toolTitle("待办", ""), wrapped(text)], spacing: 3))
            case .command:
                var views: [NSView] = [toolTitle("Bash", item.text)]
                let output = item.detail.trimmingCharacters(in: .newlines)
                if !output.isEmpty {
                    let (shown, toggle) = clipped(output.components(separatedBy: "\n"), key: key, collapsed: 4, tail: true)
                    views.append(box(wrapped(plain(shown.joined(separator: "\n"), size: 11, color: item.status == .failed ? Theme.red : Theme.muted, mono: true))))
                    if let toggle { views.append(toggle) }
                }
                return timeline(statusColor(item.status), running: running, column(views, spacing: 4))
            case .fileChange:
                let change = item.detail.components(separatedBy: "\n")[0]
                let parts = change.components(separatedBy: "  "); let path = parts.dropFirst().joined(separator: "  ")
                let relative = directory.map { path.hasPrefix($0.path + "/") ? String(path.dropFirst($0.path.count + 1)) : path } ?? path
                let open = ActionButton(relative, symbol: "arrow.up.forward", style: .plain) { [weak self] in
                    guard let self, let directory = self.directory else { return }
                    self.onOpenFile?(path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path))
                }
                open.toolTip = "在编辑器中打开 \(path)"; open.cell?.lineBreakMode = .byTruncatingMiddle; open.setContentCompressionResistancePriority(.init(1), for: .horizontal)
                let title = Theme.label(parts.first == "写入" ? "Write" : "Edit", size: 12.5, weight: .semibold); title.setContentCompressionResistancePriority(.required, for: .horizontal)
                let header = NSStackView(views: [title, open, NSView()]); header.spacing = 4; header.alignment = .centerY
                var views: [NSView] = [header]
                if !item.diff.isEmpty {
                    let (shown, toggle) = clipped(item.diff.components(separatedBy: "\n"), key: key, collapsed: 12, tail: false)
                    views.append(box(wrapped(diffText(shown)))); if let toggle { views.append(toggle) }
                }
                // A failed or denied edit explains itself on the lines after the path.
                let reason = item.detail.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                if item.status == .failed, !reason.isEmpty { views.append(hanging(reason, failed: true)) }
                return timeline(statusColor(item.status), running: running, column(views, spacing: 4))
            }
        }
    }
    private func row(for key: String, _ entry: Entry) -> NSView {
        if provider == .claude, let view = claudeRow(for: key, entry) { return view }
        switch entry {
        case .user(let text):
            let bubble = Chip(fill: Theme.accent.withAlphaComponent(0.18), radius: 12)
            let label = wrapped(plain(text)); label.translatesAutoresizingMaskIntoConstraints = false; bubble.addSubview(label)
            NSLayoutConstraint.activate([label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 7), label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -7), label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 11), label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -11)])
            let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let line = NSStackView(views: [spacer, bubble]); line.alignment = .top
            spacer.widthAnchor.constraint(greaterThanOrEqualTo: line.widthAnchor, multiplier: 0.12).isActive = true
            bubble.setAccessibilityLabel("你：\(text)"); return line
        case .status(let text, let failed):
            return wrapped(plain(text, size: 11.5, color: failed ? Theme.red : Theme.faint), selectable: failed)
        case .item(let item):
            switch item.kind {
            case .message: return wrapped(markdown(item.text.trimmingCharacters(in: .newlines)))
            case .reasoning: return wrapped(plain(item.text.trimmingCharacters(in: .whitespacesAndNewlines), size: 12, color: Theme.muted))
            case .notice: return wrapped(plain(item.text, size: 11.5, color: Theme.orange))
            case .webSearch, .toolCall:
                let line = NSStackView(views: [statusIcon(item.status, symbol: item.kind == .webSearch ? "magnifyingglass" : "wrench.and.screwdriver"), wrapped(plain(item.text, size: 12, color: Theme.soft))]); line.spacing = 7; line.alignment = .firstBaseline
                return card(line)
            case .todo:
                let title = NSStackView(views: [statusIcon(item.status, symbol: "checklist"), Theme.label("计划", size: 12, color: Theme.soft, weight: .semibold)]); title.spacing = 7
                return card(column([title, wrapped(plain(item.detail, size: 12.5))]))
            case .fileChange:
                let title = NSStackView(views: [statusIcon(item.status, symbol: "doc.badge.gearshape"), Theme.label("修改了 \(item.text)", size: 12, color: Theme.soft, weight: .semibold)]); title.spacing = 7
                var lines: [NSView] = [title]
                for change in item.detail.split(separator: "\n") {
                    let parts = change.components(separatedBy: "  "); let path = parts.dropFirst().joined(separator: "  ")
                    let name = (path as NSString).lastPathComponent
                    let button = ActionButton("\(parts.first ?? "")  \(name)", style: .plain) { [weak self] in
                        guard let self, let directory = self.directory else { return }
                        self.onOpenFile?(path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path))
                    }
                    button.toolTip = path; lines.append(button)
                }
                let stack = NSStackView(views: lines); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 2
                return card(stack)
            case .command:
                let command = Theme.label(item.text.replacingOccurrences(of: "\n", with: " ⏎ "), size: 12, color: Theme.text); command.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                command.lineBreakMode = .byTruncatingTail; command.toolTip = item.text; command.setContentCompressionResistancePriority(.init(1), for: .horizontal)
                var header: [NSView] = [statusIcon(item.status, symbol: "terminal"), command]
                if let code = item.exitCode, code != 0 { header.append(Theme.label("退出码 \(code)", size: 11, color: Theme.red)) }
                let output = item.detail.trimmingCharacters(in: .newlines)
                let lines = output.isEmpty ? [] : output.components(separatedBy: "\n")
                let open = expanded.contains(key)
                if lines.count > 4 {
                    let toggle = ActionButton(open ? "收起" : "\(lines.count) 行", symbol: open ? "chevron.up" : "chevron.down", style: .plain) { [weak self] in
                        guard let self, let entry = self.entries[key] else { return }
                        if self.expanded.contains(key) { self.expanded.remove(key) } else { self.expanded.insert(key) }
                        self.append(key, entry)
                    }
                    header.append(toggle)
                }
                let top = NSStackView(views: header); top.spacing = 7; top.alignment = .centerY
                guard !lines.isEmpty else { return card(top) }
                // Collapsed, a long output shows its tail; expanded, up to 400 lines.
                let shown = open ? lines.suffix(400) : lines.suffix(4)
                return card(column([top, wrapped(plain(shown.joined(separator: "\n"), size: 11, color: Theme.muted, mono: true))]))
            }
        }
    }
}
