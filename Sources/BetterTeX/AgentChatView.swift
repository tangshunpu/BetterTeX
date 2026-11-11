import AppKit
import BetterTeXCore

/// A native conversation with Codex: the user's prompts, the agent's replies and a card for each
/// thing it did (commands, file changes, plans). Each prompt runs one `codex exec` turn.
final class AgentChatView: NSView {
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
    private let workingLabel = Theme.label("Codex 正在工作…", size: 12, color: Theme.muted)
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var rows: [String: NSView] = [:]
    private var expanded = Set<String>()
    private var notices = Set<String>()
    private var turn: CodexTurn?
    private var turnNumber = 0
    private var directory: URL?
    private static let inset: CGFloat = 14

    override init(frame: NSRect) {
        super.init(frame: frame)
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
        let request = CodexRequest(prompt: prompt, thread: thread, configuration: configuration, sandbox: sandbox)
        do { _ = try request.arguments() } catch { append("s\(UUID().uuidString)", .status(error.localizedDescription, failed: true)); return }
        turnNumber += 1; let number = turnNumber; turnStarted = false
        self.directory = directory
        append("u\(number)", .user(display))
        let turn = CodexTurn(); self.turn = turn; setRunning(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try turn.run(request, executable: executable, directory: directory, environment: environment) { event in
                DispatchQueue.main.async { if let self, self.turn === turn { self.handle(event, turn: number) } }
            } }
            DispatchQueue.main.async {
                guard let self, self.turn === turn else { return }
                self.turn = nil; self.setRunning(false)
                switch result {
                case .failure(let error): self.append("f\(number)", .status(error.localizedDescription, failed: true))
                case .success(let outcome):
                    // A turn that ended without a completion event failed before or outside the model call.
                    if outcome.status != 0, self.entries["d\(number)"] == nil {
                        let detail = outcome.stderr.components(separatedBy: "\n").last { !$0.isEmpty } ?? ""
                        self.append("f\(number)", .status("Codex 退出（\(outcome.status)）" + (detail.isEmpty ? "" : "：\(detail)"), failed: true))
                    }
                }
            }
        }
    }
    func stop() {
        guard running, let turn else { return }
        turn.cancel(); self.turn = nil; setRunning(false)
        append("f\(turnNumber)", .status("已停止", failed: false))
    }
    /// Forgets the conversation; the next prompt starts a new Codex thread.
    func reset() {
        turn?.cancel(); turn = nil; thread = nil; running = false
        entries.removeAll(); order.removeAll(); rows.removeAll(); expanded.removeAll(); notices.removeAll()
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        onChange?()
    }
    /// Continues a conversation recorded by the Codex CLI. Its earlier messages are not shown.
    func resume(thread: String, title: String) {
        reset(); self.thread = thread
        append("s\(UUID().uuidString)", .status("已接上之前的会话：\(title)。之前的消息不在这里显示，Codex 仍记得上下文。", failed: false))
    }
    private func setRunning(_ value: Bool) {
        running = value
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
            if item.status == .running { workingLabel.stringValue = item.kind == .command ? "正在运行命令…" : "Codex 正在工作…" } else { workingLabel.stringValue = "Codex 正在工作…" }
        case .turnCompleted(let input, let output):
            func short(_ value: Int) -> String { value >= 1000 ? String(format: "%.1fk", Double(value) / 1000) : "\(value)" }
            append("d\(number)", .status("完成 · 输入 \(short(input)) / 输出 \(short(output)) tokens", failed: false))
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
    private func row(for key: String, _ entry: Entry) -> NSView {
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
