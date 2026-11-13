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
    /// A source line or PDF page the agent linked to in a reply.
    var onOpenLocation: ((AgentLocation) -> Void)?
    /// The open project, for resolving relative links before the first prompt of a resumed session.
    var projectRoot: (() -> URL?)?
    /// Called when a turn starts or ends, and when the conversation is cleared.
    var onChange: (() -> Void)?
    /// Receives Codex's own start-up warnings (configuration notices), which stay out of the conversation.
    var onLog: ((String) -> Void)?
    var onUsageChange: (() -> Void)?
    private(set) var contextUsage: AgentContextUsage?
    private(set) var quota: AgentQuotaSnapshot?
    private var codexHome: URL?
    private let usageQueue = DispatchQueue(label: "dev.bettertex.agent-usage", qos: .utility)
    private let usageReader = CodexSessionUsageReader()
    private var readingUsage = false
    private var usageReadPending = false
    private var lastUsageRead = Date.distantPast
    private var usageGeneration = UUID()
    private var turnStarted = false
    private(set) var running = false
    /// When the last turn ended; file changes seen just after still belong to it.
    private(set) var stoppedAt: Date?
    private(set) var thread: String?
    var isEmpty: Bool { order.isEmpty }

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let working = NSStackView()
    private let workingLabel = Theme.label(L10n.tr("正在工作…"), size: 12, color: Theme.muted)
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var rows: [String: NSView] = [:]
    private var expanded = Set<String>()
    /// Tool rows the user opened or closed by hand; the rest follow their default (collapsed).
    private var disclosed: [String: Bool] = [:]
    /// Consecutive tool calls share one summary row ("Read files, ran commands"); these map an item to
    /// its group and a group to its items, in order.
    private var groupOf: [String: String] = [:]
    private var groupMembers: [String: [String]] = [:]
    /// The row being built, and rows whose formulas are still being typeset.
    private var building: String?
    private var mathWaiting = Set<String>()
    /// A rebuild of the waiting rows is queued; further typeset callbacks fold into it.
    private var mathScheduled = false
    // A finished turn folds its steps behind a "Worked for …" line and lists the files it changed.
    private var turnIndex = 0
    private var turnOf: [String: Int] = [:]
    private var hiddenRows = Set<String>()
    private var folded: [Int: (duration: String?, steps: [String], tooltip: String?)] = [:]
    private var openTurns = Set<Int>()
    private var cardAll = Set<Int>(), cardClosed = Set<Int>(), cardFiles = Set<String>()
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
        activity = L10n.tr("\(provider.rawValue) 正在工作…")
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: Self.inset, bottom: 12, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .small; spinner.startAnimation(nil)
        let stop = ActionButton(L10n.tr("停止"), symbol: "stop.fill", style: .tinted) { [weak self] in self?.stop() }
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
    @discardableResult func send(prompt: String, display: String, executable: String, directory: URL, environment: [String: String], configuration: AgentConfiguration, sandbox: CodexSandbox) -> Bool {
        guard !running else { return false }
        // Both CLIs speak through the same event model; only the process differs.
        let token = NSObject()
        let run: (@escaping (CodexEvent) -> Void) throws -> (status: Int32, stderr: String)
        do {
            switch provider {
            case .codex:
                let request = CodexRequest(prompt: prompt, thread: thread, configuration: configuration, sandbox: sandbox, instructions: AgentInstructions.text); _ = try request.arguments()
                let process = CodexTurn(); cancelTurn = { process.cancel() }
                run = { try process.run(request, executable: executable, directory: directory, environment: environment, onEvent: $0) }
            case .claude:
                let request = ClaudeRequest(prompt: prompt, session: thread, configuration: configuration, sandbox: sandbox, instructions: AgentInstructions.text); _ = try request.arguments()
                let process = ClaudeTurn(); cancelTurn = { process.cancel() }
                run = { try process.run(request, executable: executable, directory: directory, environment: environment, onEvent: $0) }
            }
        } catch { append("s\(UUID().uuidString)", .status(error.localizedDescription, failed: true)); return false }
        turnNumber += 1; let number = turnNumber; turnStarted = false
        self.directory = directory
        codexHome = URL(fileURLWithPath: environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
        append("u\(number)", .user(display))
        let turn = token; self.turn = turn; setRunning(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try run { event in
                DispatchQueue.main.async { if let self, self.turn === turn { self.handle(event, turn: number) } }
            } }
            DispatchQueue.main.async {
                guard let self, self.turn === turn else { return }
                self.turn = nil; self.cancelTurn = nil; self.setRunning(false)
                self.refreshContextUsage(force: true)
                switch result {
                case .failure(let error): self.append("f\(number)", .status(error.localizedDescription, failed: true))
                case .success(let outcome):
                    // A turn that ended without a completion event failed before or outside the model call.
                    if outcome.status != 0, self.entries["d\(number)"] == nil {
                        let detail = outcome.stderr.components(separatedBy: "\n").last { !$0.isEmpty } ?? ""
                        self.append("f\(number)", .status(L10n.tr("\(self.name) 退出（\(outcome.status)）") + (detail.isEmpty ? "" : L10n.tr("：\(detail)")), failed: true))
                    }
                }
            }
        }
        return true
    }
    func stop() {
        guard running, turn != nil else { return }
        cancelTurn?(); cancelTurn = nil; turn = nil; setRunning(false)
        append("f\(turnNumber)", .status(L10n.tr("已停止"), failed: false))
    }
    /// Forgets the conversation; the next prompt starts a new Codex thread.
    func reset() {
        cancelTurn?(); cancelTurn = nil; turn = nil; thread = nil; running = false
        ticker?.invalidate(); ticker = nil
        usageGeneration = UUID(); readingUsage = false; usageReadPending = false; lastUsageRead = .distantPast
        contextUsage = nil; quota = nil; onUsageChange?()
        entries.removeAll(); order.removeAll(); rows.removeAll(); expanded.removeAll(); disclosed.removeAll(); groupOf.removeAll(); groupMembers.removeAll(); notices.removeAll()
        turnIndex = 0; turnOf.removeAll(); hiddenRows.removeAll(); folded.removeAll(); openTurns.removeAll(); cardAll.removeAll(); cardClosed.removeAll(); cardFiles.removeAll(); mathWaiting.removeAll()
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        onChange?()
    }
    /// Continues a conversation recorded by the Codex CLI. Its earlier messages are not shown.
    func resume(thread: String, title: String) {
        reset(); self.thread = thread
        append("s\(UUID().uuidString)", .status(L10n.tr("已接上之前的会话：\(title)。之前的消息不在这里显示，\(name) 仍记得上下文。"), failed: false))
    }
    /// Continues a recorded conversation and shows its earlier messages, read from the CLI's log
    /// off the main thread. If the log can't be read, it falls back to the plain notice.
    func resume(_ session: AgentSession, project: URL?) {
        reset(); thread = session.id; directory = project
        let generation = UUID(); usageGeneration = generation
        append("hload", .status(L10n.tr("正在载入之前的消息…"), failed: false))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (entries, omitted) = AgentTranscript.load(session, project: project)
            DispatchQueue.main.async {
                // Drop the result if the user started over, switched sessions or already sent a prompt.
                guard let self, self.usageGeneration == generation, self.thread == session.id, !self.running, self.order == ["hload"] else { return }
                guard !entries.isEmpty else { self.resume(thread: session.id, title: session.title); return }
                self.reset(); self.thread = session.id; self.usageGeneration = generation; self.directory = project
                if omitted > 0 { self.append("hmore", .status(L10n.tr("更早的 \(omitted) 条记录未显示"), failed: false)) }
                for (index, entry) in entries.enumerated() {
                    switch entry {
                    case .user(let text): self.append("h\(index).u", .user(text))
                    case .item(let item): self.append("h.\(item.id)", .item(item))
                    }
                }
                for turn in 0...self.turnIndex { self.finishTurn(turn, duration: nil) }
                self.append("hend", .status(L10n.tr("以上是之前的对话 · 继续输入即可接着聊"), failed: false))
                self.refreshContextUsage(force: true)
            }
        }
    }
    private var elapsed: String {
        let seconds = Int(Date().timeIntervalSince(started))
        return seconds < 60 ? L10n.tr("\(seconds) 秒") : L10n.tr("\(seconds / 60) 分 \(seconds % 60) 秒")
    }
    private func refreshWorking() {
        workingLabel.stringValue = running ? "\(activity)  \(elapsed)" : activity
        if running { refreshContextUsage() }
    }
    func configureUsage(environment: [String: String]) {
        codexHome = URL(fileURLWithPath: environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
    }
    /// Poll only this thread, off the UI thread, while it is running or on explicit refresh.
    func refreshContextUsage(force: Bool = false) {
        guard provider == .codex, let thread, let codexHome else { return }
        if readingUsage { if force { usageReadPending = true }; return }
        guard force || Date().timeIntervalSince(lastUsageRead) >= 2 else { return }
        readingUsage = true; lastUsageRead = Date()
        let generation = usageGeneration, reader = usageReader
        usageQueue.async { [weak self] in
            let snapshot = reader.read(thread: thread, home: codexHome)
            DispatchQueue.main.async {
                guard let self, self.usageGeneration == generation, self.thread == thread else { return }
                self.readingUsage = false
                defer {
                    if self.usageReadPending { self.usageReadPending = false; self.refreshContextUsage(force: true) }
                }
                guard let snapshot else { return }
                if snapshot.hasContextUpdate { self.contextUsage = snapshot.context }
                if let quota = snapshot.quota, quota.observedAt > (self.quota?.observedAt ?? .distantPast) { self.quota = quota }
                self.onUsageChange?()
            }
        }
    }
    private func setRunning(_ value: Bool) {
        let finished = running && !value
        running = value
        if finished { stoppedAt = Date() }
        if finished { finishTurn(turnIndex, duration: elapsed) }
        ticker?.invalidate(); ticker = nil
        if value {
            started = Date(); activity = L10n.tr("\(name) 正在工作…")
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshWorking() }
        }
        if value { if working.superview == nil { stack.addArrangedSubview(working); working.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Self.inset * 2).isActive = true } }
        else { stack.removeArrangedSubview(working); working.removeFromSuperview() }
        onChange?(); scrollToEnd()
    }
    private func handle(_ event: CodexEvent, turn number: Int) {
        switch event {
        case .threadStarted(let id): thread = id; refreshContextUsage(force: true)
        case .turnStarted: turnStarted = true
        case .item(let item):
            if item.kind == .notice {
                guard notices.insert(item.text).inserted else { return }
                // Anything Codex says before the turn begins is about its own setup, not this conversation.
                if !turnStarted { onLog?(item.text); return }
            }
            if item.kind == .message || item.kind == .reasoning, item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            append("i\(number).\(item.id)", .item(item))
            activity = item.status != .running ? L10n.tr("\(name) 正在工作…") : item.kind == .command ? L10n.tr("正在运行命令…") : item.kind == .message ? L10n.tr("\(name) 正在回复…") : item.kind == .reasoning ? L10n.tr("\(name) 正在思考…") : item.kind == .fileChange ? L10n.tr("正在修改文件…") : L10n.tr("\(name) 正在工作…")
            // Streamed text grows in place; keep its tail in view.
            if item.status == .running, item.kind == .message || item.kind == .reasoning { scrollToEnd() }
        case .turnCompleted(let input, let output):
            func short(_ value: Int) -> String { value >= 1000 ? String(format: "%.1fk", Double(value) / 1000) : "\(value)" }
            append("d\(number)", .status(L10n.tr("完成 · \(elapsed) · 输入 \(short(input)) / 输出 \(short(output)) tokens"), failed: false))
        case .turnFailed(let message): append("d\(number)", .status(message, failed: true))
        case .contextUsage(let update): contextUsage = update?.merging(contextUsage); onUsageChange?()
        case .rateLimits(let snapshot): quota = snapshot; onUsageChange?()
        }
    }

    // MARK: Rows
    private func groupable(_ entry: Entry) -> Bool {
        guard case .item(let item) = entry else { return false }
        return [.toolCall, .webSearch, .command, .fileChange, .reasoning].contains(item.kind)
    }
    private func append(_ key: String, _ entry: Entry) {
        let isNew = entries[key] == nil, previous = order.last
        entries[key] = entry; if isNew { order.append(key) }
        if isNew { if case .user = entry { turnIndex += 1 }; turnOf[key] = turnIndex }
        // A tool call joins the group of the row right above it, or starts a new one.
        var rowKey = key
        if groupable(entry) {
            if let group = groupOf[key] { rowKey = group }
            else {
                let group = previous.flatMap { groupOf[$0] } ?? "g." + key
                groupOf[key] = group; groupMembers[group, default: []].append(key); rowKey = group
                if turnOf[group] == nil { turnOf[group] = turnOf[key] }
            }
        }
        building = rowKey; defer { building = nil }
        let view = rowKey == key ? row(for: key, entry) : groupRow(rowKey)
        place(rowKey, view)
        if isNew { if order.count == 1 { onChange?() }; scrollToEnd() }
    }
    private func place(_ key: String, _ view: NSView) {
        if let old = rows[key], let index = stack.arrangedSubviews.firstIndex(of: old) {
            stack.removeArrangedSubview(old); old.removeFromSuperview(); stack.insertArrangedSubview(view, at: index)
        } else if running, let index = stack.arrangedSubviews.firstIndex(of: working) { stack.insertArrangedSubview(view, at: index) }
        else { stack.addArrangedSubview(view) }
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Self.inset * 2).isActive = true
        view.isHidden = hiddenRows.contains(key)
        rows[key] = view
    }
    /// Puts a row right after (or before) another one, for the rows a finished turn adds.
    private func insert(_ key: String, _ view: NSView, near anchor: String, after: Bool) {
        guard let anchorView = rows[anchor], let index = stack.arrangedSubviews.firstIndex(of: anchorView) else { return }
        stack.insertArrangedSubview(view, at: after ? index + 1 : index)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Self.inset * 2).isActive = true
        rows[key] = view
    }

    // MARK: Finished turns
    /// Folds a finished turn: its steps go behind one "Worked for …" line, the final reply stays,
    /// and the files it changed are listed under the reply. Failures and stops stay visible.
    private func finishTurn(_ turn: Int, duration: String?) {
        guard folded[turn] == nil else { return }
        let keys = order.filter { turnOf[$0] == turn }
        var rowKeys: [String] = []
        for key in keys { let row = groupOf[key] ?? key; if !rowKeys.contains(row) { rowKeys.append(row) } }
        let reply = keys.last { if case .item(let item)? = entries[$0] { return item.kind == .message }; return false }
        var steps: [String] = [], tooltip: String?, done: String?
        for key in rowKeys where key != reply {
            switch entries[key] {
            case .user?: continue
            case .status(let text, let failed)?:
                if !failed, key.hasPrefix("d") { done = key; tooltip = text }
            default: steps.append(key)
            }
        }
        guard !steps.isEmpty else { return }
        folded[turn] = (duration, steps, tooltip)
        for key in steps + [done].compactMap({ $0 }) { hiddenRows.insert(key); rows[key]?.isHidden = true }
        insert("th\(turn)", turnHeader(turn), near: steps[0], after: false)
        if !changedFiles(turn).isEmpty { insert("tc\(turn)", changeCard(turn), near: reply ?? steps[steps.count - 1], after: true) }
    }
    private func toggleTurn(_ turn: Int) {
        guard let info = folded[turn] else { return }
        let open = !openTurns.contains(turn)
        if open { openTurns.insert(turn) } else { openTurns.remove(turn) }
        for key in info.steps { if open { hiddenRows.remove(key) } else { hiddenRows.insert(key) }; rows[key]?.isHidden = !open }
        place("th\(turn)", turnHeader(turn))
    }
    private func turnHeader(_ turn: Int) -> NSView {
        let open = openTurns.contains(turn), info = folded[turn]
        let text = info?.duration.map { L10n.tr("已工作 \($0)") } ?? L10n.tr("工作过程")
        let label = Theme.label(text, size: 13, color: Theme.muted)
        let chevron = NSImageView(image: Theme.symbol(open ? "chevron.down" : "chevron.right", size: 9, weight: .semibold)!); chevron.contentTintColor = Theme.faint; chevron.size(12, 12)
        let line = NSStackView(views: [label, chevron]); line.spacing = 5; line.alignment = .centerY
        let button = RowButton(height: 26) { [weak self] in self?.toggleTurn(turn) }
        button.layer?.cornerRadius = 6; button.layer?.cornerCurve = .continuous
        button.pinRow(line, leading: 2, trailing: 6); button.setContentHuggingPriority(.required, for: .horizontal)
        button.setAccessibilityLabel(text); button.setAccessibilityExpanded(open); button.toolTip = info?.tooltip
        let top = NSStackView(views: [button, NSView()]); top.distribution = .fill
        let rule = Chip(fill: Theme.hairline, radius: 0); rule.size(nil, 1)
        return column([top, rule], spacing: 4)
    }

    /// One file a turn changed, with its line counts when the diff is known.
    private struct FileChange { var path: String; var added = 0; var removed = 0; var diff: [String] = []; var counted = true }
    private func changedFiles(_ turn: Int) -> [FileChange] {
        var files: [FileChange] = []
        for key in order where turnOf[key] == turn {
            guard case .item(let item)? = entries[key], item.kind == .fileChange, item.status != .failed else { continue }
            let paths = item.detail.components(separatedBy: "\n").compactMap { line -> String? in
                let parts = line.components(separatedBy: "  "); let path = parts.dropFirst().joined(separator: "  ")
                return path.isEmpty ? nil : path
            }
            let lines = item.diff.isEmpty ? [] : item.diff.components(separatedBy: "\n")
            for path in paths {
                var file = files.first { $0.path == path } ?? FileChange(path: path)
                if paths.count == 1, !lines.isEmpty {
                    file.added += lines.filter { $0.hasPrefix("+") }.count; file.removed += lines.filter { $0.hasPrefix("-") }.count; file.diff += lines
                } else { file.counted = false }
                if let index = files.firstIndex(where: { $0.path == path }) { files[index] = file } else { files.append(file) }
            }
        }
        return files
    }
    private func counts(_ added: Int, _ removed: Int, size: CGFloat = 12.5) -> NSTextField {
        let text = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        text.append(NSAttributedString(string: "+\(added)", attributes: [.font: font, .foregroundColor: Theme.adaptive(0x1A7F37, 0x7EE787)]))
        text.append(NSAttributedString(string: " −\(removed)", attributes: [.font: font, .foregroundColor: Theme.adaptive(0xCF222E, 0xFF9A93)]))
        let label = NSTextField(labelWithAttributedString: text); label.setContentCompressionResistancePriority(.required, for: .horizontal); label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }
    /// "3 files changed +52 −17", then a row per file (three until expanded). A row opens its diff.
    private func changeCard(_ turn: Int) -> NSView {
        let files = changedFiles(turn), closed = cardClosed.contains(turn)
        let added = files.reduce(0) { $0 + $1.added }, removed = files.reduce(0) { $0 + $1.removed }
        let title = Theme.label(files.count == 1 ? L10n.tr("1 个文件已更改") : L10n.tr("\(files.count) 个文件已更改"), size: 13, color: Theme.text, weight: .medium)
        var headerViews: [NSView] = [title]
        if files.contains(where: { $0.counted && $0.added + $0.removed > 0 }) { headerViews.append(counts(added, removed, size: 13)) }
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal); headerViews.append(spacer)
        let chevron = NSImageView(image: Theme.symbol(closed ? "chevron.right" : "chevron.down", size: 10, weight: .semibold)!); chevron.contentTintColor = Theme.muted; chevron.size(12, 12); headerViews.append(chevron)
        var rowsInCard: [NSView] = [cardRow(headerViews, height: 38) { [weak self] in
            guard let self else { return }
            if self.cardClosed.contains(turn) { self.cardClosed.remove(turn) } else { self.cardClosed.insert(turn) }
            self.place("tc\(turn)", self.changeCard(turn))
        }]
        if !closed {
            let shown = cardAll.contains(turn) ? files : Array(files.prefix(3))
            for file in shown {
                let id = "\(turn)|\(file.path)", open = cardFiles.contains(id)
                let relative = directory.map { file.path.hasPrefix($0.path + "/") ? String(file.path.dropFirst($0.path.count + 1)) : file.path } ?? file.path
                let name = Theme.label(relative, size: 12.5, color: Theme.soft); name.lineBreakMode = .byTruncatingHead
                name.setContentCompressionResistancePriority(.init(1), for: .horizontal); name.setContentHuggingPriority(.init(1), for: .horizontal); name.toolTip = file.path
                var views: [NSView] = [name]
                if file.counted, file.added + file.removed > 0 { views.append(counts(file.added, file.removed)) }
                let reveal = ActionButton("", symbol: "arrow.up.forward.square", style: .plain) { [weak self] in
                    guard let self else { return }
                    let url = file.path.hasPrefix("/") ? URL(fileURLWithPath: file.path) : (self.directory ?? self.projectRoot?() ?? URL(fileURLWithPath: "/")).appendingPathComponent(file.path)
                    self.onOpenLocation?(.source(url, line: nil))
                }
                reveal.toolTip = L10n.tr("在编辑器中打开 \(file.path)"); reveal.setContentHuggingPriority(.required, for: .horizontal); views.append(reveal)
                rowsInCard.append(cardRow(views, height: 34) { [weak self] in
                    guard let self, !file.diff.isEmpty else { return }
                    if self.cardFiles.contains(id) { self.cardFiles.remove(id) } else { self.cardFiles.insert(id) }
                    self.place("tc\(turn)", self.changeCard(turn))
                })
                if open, !file.diff.isEmpty {
                    let lines = file.diff.count > 120 ? Array(file.diff.prefix(120)) + [L10n.tr(" … 还有 \(file.diff.count - 120) 行")] : file.diff
                    let diff = wrapped(diffText(lines)); let holder = NSView(); diff.translatesAutoresizingMaskIntoConstraints = false; holder.addSubview(diff)
                    NSLayoutConstraint.activate([diff.topAnchor.constraint(equalTo: holder.topAnchor, constant: 6), diff.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -8), diff.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 14), diff.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -14)])
                    rowsInCard.append(holder)
                }
            }
            if files.count > 3 {
                let more = cardAll.contains(turn) ? L10n.tr("收起") : (files.count == 4 ? L10n.tr("查看另外 1 个文件") : L10n.tr("查看另外 \(files.count - 3) 个文件"))
                let chevron = NSImageView(image: Theme.symbol(cardAll.contains(turn) ? "chevron.up" : "chevron.right", size: 10, weight: .semibold)!); chevron.contentTintColor = Theme.muted; chevron.size(12, 12)
                let label = Theme.label(more, size: 12.5, color: Theme.muted); label.setContentHuggingPriority(.init(1), for: .horizontal)
                rowsInCard.append(cardRow([label, chevron], height: 34) { [weak self] in
                    guard let self else { return }
                    if self.cardAll.contains(turn) { self.cardAll.remove(turn) } else { self.cardAll.insert(turn) }
                    self.place("tc\(turn)", self.changeCard(turn))
                })
            }
        }
        // Rows separated by hairlines inside one rounded, bordered card.
        var separated: [NSView] = []
        for (index, view) in rowsInCard.enumerated() {
            if index > 0 { let rule = Chip(fill: Theme.hairline, radius: 0); rule.size(nil, 1); separated.append(rule) }
            separated.append(view)
        }
        let body = column(separated, spacing: 0)
        let card = Chip(fill: Theme.fillSoft, radius: 10, border: Theme.hairline)
        card.layer?.masksToBounds = true; card.pin(body)
        return card
    }
    private func cardRow(_ views: [NSView], height: CGFloat, action: @escaping () -> Void) -> NSView {
        let line = NSStackView(views: views); line.spacing = 8; line.alignment = .centerY; line.distribution = .fill
        let button = RowButton(height: height, action: action)
        button.pinRow(line, leading: 14, trailing: 12)
        return button
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
    /// Reply prose: Markdown, with TeX math typeset in place. Math is cut out before Markdown
    /// parsing, which would otherwise eat the backslashes in \( \) and the underscores in subscripts.
    private func prose(_ body: String) -> NSView {
        let spans = MathText.spans(in: body)
        guard !spans.isEmpty else { return linked(markdown(headings(body))) }
        let source = NSMutableString(string: body)
        for (index, span) in spans.enumerated().reversed() { source.replaceCharacters(in: span.range, with: String(UnicodeScalar(UInt32(0xE000 + index))!)) }
        let text = NSMutableAttributedString(attributedString: markdown(headings(source as String)))
        let renderer = MathRenderer.shared
        var missing: [(tex: String, display: Bool)] = []
        for (index, span) in spans.enumerated() {
            let marker = String(UnicodeScalar(UInt32(0xE000 + index))!)
            let range = (text.string as NSString).range(of: marker)
            guard range.location != NSNotFound else { continue }
            let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 13)
            switch renderer.state(span.tex, display: span.display) {
            case .ready(let image, let descent)?:
                let attachment = NSTextAttachment(); attachment.image = image
                // Wide display math shrinks to fit the panel rather than overflowing it.
                let fit = min(1, 340 / max(image.size.width, 1))
                attachment.bounds = CGRect(x: 0, y: -descent * fit, width: image.size.width * fit, height: image.size.height * fit)
                let piece = NSMutableAttributedString(attachment: attachment)
                piece.addAttribute(.font, value: font, range: NSRange(location: 0, length: piece.length))
                piece.addAttribute(.toolTip, value: span.tex, range: NSRange(location: 0, length: piece.length))
                text.replaceCharacters(in: range, with: piece)
                if span.display {
                    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.paragraphSpacing = 4; paragraph.paragraphSpacingBefore = 4
                    text.addAttribute(.paragraphStyle, value: paragraph, range: (text.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 1)))
                }
            case .failed?, nil:
                if renderer.state(span.tex, display: span.display) == nil { missing.append((span.tex, span.display)) }
                // Until it is typeset (or if TeX rejects it), show the formula's source.
                let original = (body as NSString).substring(with: span.range)
                text.replaceCharacters(in: range, with: NSAttributedString(string: original, attributes: [.font: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular), .foregroundColor: Theme.soft]))
            }
        }
        if !missing.isEmpty, renderer.tools != nil, let key = building {
            mathWaiting.insert(key)
            renderer.request(missing) { [weak self] in self?.scheduleMathReady() }
        }
        return linked(text)
    }
    /// The user's prompt as typed. A bare "@file" attachment reference is dropped; a reference to
    /// selected lines stays as a small caption above the text.
    private func prompt(_ text: String, size: CGFloat = 13) -> NSAttributedString {
        var lines = text.components(separatedBy: "\n"), caption: String?
        if let first = lines.first, first.range(of: "^@\\S+$", options: .regularExpression) != nil {
            lines.removeFirst(); while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            if first.range(of: ":\\d+(-\\d+)?$", options: .regularExpression) != nil { caption = first }
        }
        let result = NSMutableAttributedString()
        if let caption { result.append(plain(caption + (lines.isEmpty ? "" : "\n"), size: 11, color: Theme.muted, mono: true)) }
        result.append(plain(lines.isEmpty && caption == nil ? text : lines.joined(separator: "\n"), size: size))
        return result
    }
    /// Reply text whose links to source lines and PDF pages open inside BetterTeX. Plain mentions of
    /// project files ("sections/intro.tex:42") become links too.
    private func linked(_ text: NSAttributedString) -> NSView {
        let result = NSMutableAttributedString(attributedString: text), root = directory ?? projectRoot?()
        func local(_ target: String) -> URL? {
            guard AgentLocation.parse(target, project: root) != nil else { return nil }
            var parts = URLComponents(); parts.scheme = LinkTextView.scheme; parts.path = "open"; parts.queryItems = [URLQueryItem(name: "target", value: target)]
            return parts.url
        }
        let whole = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.link, in: whole) { value, range, _ in
            guard let value else { return }
            let target = (value as? URL).map { $0.scheme == nil ? ($0.relativeString.removingPercentEncoding ?? $0.relativeString) : $0.absoluteString } ?? (value as? String ?? "")
            if let url = local(target) { result.addAttribute(.link, value: url, range: range) }
        }
        let string = result.string as NSString
        for range in AgentLocation.mentions(in: result.string) where result.attribute(.link, at: range.location, effectiveRange: nil) == nil {
            if let url = local(string.substring(with: range)) { result.addAttribute(.link, value: url, range: range) }
        }
        let view = LinkTextView(result)
        view.onLocation = { [weak self] target in
            guard let self, let location = AgentLocation.parse(target, project: self.directory ?? self.projectRoot?()) else { return }
            self.onOpenLocation?(location)
        }
        return view
    }
    private func plain(_ text: String, size: CGFloat = 13, color: NSColor = Theme.text, mono: Bool = false) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size), .foregroundColor: color])
    }
    /// Inline Markdown (bold, italic, code) as the agent writes it; block structure stays as typed.
    private func markdown(_ text: String, size: CGFloat = 13, color: NSColor = Theme.text) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else { return plain(text) }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = NSFont.systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .semibold : .regular)
            if intent.contains(.code) { font = .monospacedSystemFont(ofSize: size - 1, weight: .regular) }
            else if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
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
    /// A row with a small glyph in the gutter: what kind of step it is, red when it failed, a spinner while it runs.
    private func timeline(_ color: NSColor, running: Bool = false, symbol: String, _ content: NSView) -> NSView {
        let marker: NSView
        if running { let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .mini; spinner.startAnimation(nil); spinner.size(11, 11); marker = spinner }
        else { let image = NSImageView(image: Theme.symbol(symbol, size: 11.5, weight: .regular) ?? NSImage()); image.contentTintColor = color; image.size(16, 16); marker = image }
        let gutter = NSView(); gutter.size(16, 22); marker.translatesAutoresizingMaskIntoConstraints = false; gutter.addSubview(marker)
        NSLayoutConstraint.activate([marker.centerXAnchor.constraint(equalTo: gutter.centerXAnchor), marker.centerYAnchor.constraint(equalTo: gutter.centerYAnchor)])
        content.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = NSStackView(views: [gutter, content]); line.spacing = 4; line.alignment = .top; line.distribution = .fill
        return line
    }
    private func statusColor(_ status: CodexItem.Status) -> NSColor { status == .failed ? Theme.red : Theme.muted }
    /// The glyph for one step: a terminal for commands, a pencil for edits, a page for reads.
    private func symbol(for item: CodexItem) -> String {
        switch item.kind {
        case .command: return "terminal"
        case .fileChange: return "pencil"
        case .webSearch: return "globe"
        case .reasoning: return "brain"
        case .todo: return "checklist"
        case .notice: return "exclamationmark.triangle"
        case .message: return "text.bubble"
        case .toolCall:
            switch verb(for: item) {
            case .read: return "doc.text"
            case .search: return "magnifyingglass"
            default: return "wrench.and.screwdriver"
            }
        }
    }
    private enum Verb: Int, CaseIterable { case think, read, search, web, run, edit, tool }
    private func verb(for item: CodexItem) -> Verb {
        switch item.kind {
        case .command: return .run
        case .fileChange: return .edit
        case .webSearch: return .web
        case .reasoning: return .think
        default:
            let tool = item.text.components(separatedBy: " · ")[0].lowercased()
            if ["read", "notebookread", "read_file", "view"].contains(tool) { return .read }
            if ["grep", "glob", "ls", "search", "list_files", "find"].contains(tool) { return .search }
            return .tool
        }
    }
    private func phrase(_ verb: Verb) -> String {
        switch verb {
        case .think: return L10n.tr("思考过程")
        case .read: return L10n.tr("读取文件")
        case .search: return L10n.tr("搜索代码")
        case .web: return L10n.tr("搜索网页")
        case .run: return L10n.tr("运行命令")
        case .edit: return L10n.tr("编辑文件")
        case .tool: return L10n.tr("调用工具")
        }
    }
    /// What a running step is doing, for the group's header.
    private func activity(_ item: CodexItem) -> String {
        switch verb(for: item) {
        case .think: return L10n.tr("\(name) 正在思考…")
        case .read: return L10n.tr("正在读取文件…")
        case .search, .web: return L10n.tr("正在搜索…")
        case .run: return L10n.tr("正在运行命令…")
        case .edit: return L10n.tr("正在修改文件…")
        case .tool: return L10n.tr("\(name) 正在工作…")
        }
    }
    /// One quiet line for a run of steps: "Read files, ran commands", with a chevron to list them.
    /// A lone step skips the summary and shows its own row.
    private func groupRow(_ group: String) -> NSView {
        let keys = groupMembers[group] ?? []
        if keys.count == 1, let key = keys.first, let entry = entries[key] { return row(for: key, entry) }
        let items = keys.compactMap { key -> CodexItem? in if case .item(let item) = entries[key] { return item }; return nil }
        let live = items.last { $0.status == .running }, failures = items.filter { $0.status == .failed }.count
        let open = isOpen(group)
        let verbs = Set(items.map(verb(for:)))
        var text: String
        if let live { text = activity(live) }
        else {
            // Thinking is only named when it is all the group did.
            let named = verbs.count > 1 ? verbs.subtracting([.think]) : verbs
            text = Verb.allCases.filter(named.contains).map(phrase).joined(separator: L10n.tr("、"))
            text = text.prefix(1).uppercased() + text.dropFirst()
        }
        let icon: NSView
        if live != nil { let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .mini; spinner.startAnimation(nil); spinner.size(12, 12); icon = spinner }
        else {
            let main = verbs.subtracting([.think])
            let name = main.count == 1 ? symbol(for: items.first { verb(for: $0) == main.first! }!) : main.isEmpty ? "brain" : "wrench.and.screwdriver"
            let image = NSImageView(image: Theme.symbol(name, size: 11.5, weight: .regular) ?? NSImage()); image.contentTintColor = Theme.muted; image.size(16, 16); icon = image
        }
        let gutter = NSView(); gutter.size(16, 16); icon.translatesAutoresizingMaskIntoConstraints = false; gutter.addSubview(icon)
        NSLayoutConstraint.activate([icon.centerXAnchor.constraint(equalTo: gutter.centerXAnchor), icon.centerYAnchor.constraint(equalTo: gutter.centerYAnchor)])
        let label = Theme.label(text, size: 13, color: Theme.muted); label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        var parts: [NSView] = [gutter, label]
        if failures > 0 { parts.append(Theme.label(L10n.tr("\(failures) 个失败"), size: 12, color: Theme.red, weight: .medium)) }
        let chevron = NSImageView(image: Theme.symbol(open ? "chevron.down" : "chevron.right", size: 9, weight: .semibold)!); chevron.contentTintColor = Theme.faint; chevron.size(12, 12)
        parts.append(chevron)
        let line = NSStackView(views: parts); line.spacing = 4; line.alignment = .centerY
        let header = RowButton(height: 24) { [weak self] in self?.toggle(group, from: open) }
        header.layer?.cornerRadius = 6; header.layer?.cornerCurve = .continuous
        header.pinRow(line, leading: 0, trailing: 6)
        header.setAccessibilityLabel(text); header.setAccessibilityExpanded(open)
        // The header hugs its text, so the hover highlight sits under the words, not the whole width.
        let top = NSStackView(views: [header, NSView()]); top.distribution = .fill; header.setContentHuggingPriority(.required, for: .horizontal)
        guard open else { return top }
        // Opened, the steps hang off a hairline under the icon.
        let steps = column(keys.compactMap { key in entries[key].map { row(for: key, $0) } }, spacing: 6)
        let rail = Chip(fill: Theme.hairline, radius: 0); rail.size(1, nil)
        let body = NSView(); [rail, steps].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; body.addSubview($0) }
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 7.5), rail.topAnchor.constraint(equalTo: body.topAnchor), rail.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            steps.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 18), steps.trailingAnchor.constraint(equalTo: body.trailingAnchor), steps.topAnchor.constraint(equalTo: body.topAnchor), steps.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
        return column([top, body], spacing: 4)
    }
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
    // MARK: Collapsible tool rows
    /// Tool calls start folded to a single line; failures open so the error is in view.
    private func isOpen(_ key: String, default value: Bool = false) -> Bool { disclosed[key] ?? value }
    /// Many typeset batches can finish in one main-queue pass; rebuild the waiting rows once after them.
    private func scheduleMathReady() {
        guard !mathScheduled else { return }
        mathScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mathScheduled = false; self.mathReady()
        }
    }
    /// Rebuilds the rows that were waiting for typeset formulas.
    private func mathReady() {
        let keys = mathWaiting; mathWaiting.removeAll()
        for key in keys {
            autoreleasepool {
                if groupMembers[key] != nil { building = key; place(key, groupRow(key)); building = nil }
                else if let entry = entries[key] { append(key, entry) }
            }
        }
    }
    private func toggle(_ key: String, from open: Bool) {
        if groupMembers[key] != nil { disclosed[key] = !open; place(key, groupRow(key)); return }
        guard let entry = entries[key] else { return }
        disclosed[key] = !open; append(key, entry)
    }
    /// One line: tool, argument (truncated), a quiet summary and a chevron. Clicking it folds the body.
    private func disclosure(_ key: String, open: Bool, tool: String, argument: String, summary: NSAttributedString? = nil, hasBody: Bool, trailing: [NSView] = []) -> NSView {
        let text = NSMutableAttributedString(string: tool, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: Theme.soft])
        let flat = argument.replacingOccurrences(of: "\n", with: " ⏎ ")
        if !flat.isEmpty { text.append(NSAttributedString(string: "  " + flat, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: Theme.muted])) }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        let title = NSTextField(labelWithAttributedString: text)
        title.cell?.wraps = false; title.usesSingleLineMode = true; title.lineBreakMode = .byTruncatingTail; title.maximumNumberOfLines = 1; title.toolTip = argument.isEmpty ? nil : argument
        title.setContentCompressionResistancePriority(.init(1), for: .horizontal); title.setContentHuggingPriority(.init(1), for: .horizontal)
        var views: [NSView] = [title]
        if let summary {
            let label = NSTextField(labelWithAttributedString: summary); label.setContentCompressionResistancePriority(.required, for: .horizontal); label.setContentHuggingPriority(.required, for: .horizontal)
            views.append(label)
        }
        if hasBody {
            let chevron = NSImageView(image: Theme.symbol(open ? "chevron.down" : "chevron.right", size: 9, weight: .bold)!)
            chevron.contentTintColor = Theme.faint; chevron.size(12, 12); views.append(chevron)
        }
        let line = NSStackView(views: views); line.spacing = 6; line.alignment = .centerY; line.distribution = .fill
        guard hasBody else {
            let row = NSStackView(views: [line] + trailing); row.spacing = 4; row.alignment = .centerY; row.distribution = .fill; row.size(nil, 20)
            return row
        }
        let button = RowButton(height: 22) { [weak self] in self?.toggle(key, from: open) }
        button.layer?.cornerRadius = 6; button.layer?.cornerCurve = .continuous
        button.pinRow(line, leading: 5, trailing: 6)
        button.setAccessibilityLabel(tool + (flat.isEmpty ? "" : " " + flat)); button.setAccessibilityExpanded(open)
        button.setContentHuggingPriority(.init(1), for: .horizontal)
        guard !trailing.isEmpty else { return button }
        let row = NSStackView(views: [button] + trailing); row.spacing = 2; row.alignment = .centerY; row.distribution = .fill
        return row
    }
    /// "12 行" in the faint summary style, or the exit code in red.
    private func summary(_ text: String, color: NSColor = Theme.faint) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: color])
    }
    private func diffSummary(_ diff: String) -> NSAttributedString? {
        let lines = diff.components(separatedBy: "\n")
        let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count, removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
        guard added + removed > 0 else { return nil }
        let result = NSMutableAttributedString()
        if added > 0 { result.append(summary("+\(added)", color: Theme.adaptive(0x1A7F37, 0x7EE787))) }
        if removed > 0 { result.append(summary((added > 0 ? " " : "") + "−\(removed)", color: Theme.adaptive(0xCF222E, 0xFF9A93))) }
        return result
    }
    /// Bodies sit a little in from the header so they read as belonging to it.
    private func indented(_ view: NSView) -> NSView {
        let holder = NSView(); view.translatesAutoresizingMaskIntoConstraints = false; holder.addSubview(view)
        NSLayoutConstraint.activate([view.topAnchor.constraint(equalTo: holder.topAnchor), view.bottomAnchor.constraint(equalTo: holder.bottomAnchor), view.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 5), view.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor)])
        if !(view is ActionButton) { view.trailingAnchor.constraint(equalTo: holder.trailingAnchor).isActive = true }
        return holder
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
        let toggle = ActionButton(open ? L10n.tr("收起") : L10n.tr("展开全部 \(lines.count) 行"), symbol: open ? "chevron.up" : "chevron.down", style: .plain) { [weak self] in
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
        guard parts.count > 2 else { return prose(text) }
        var views: [NSView] = []
        for (index, part) in parts.enumerated() {
            if index % 2 == 1 {
                // Drop the language tag on the fence line.
                var code = part; if let newline = code.firstIndex(of: "\n") { code = String(code[code.index(after: newline)...]) }
                let body = code.trimmingCharacters(in: .newlines); if !body.isEmpty { views.append(box(wrapped(plain(body, size: 11.5, mono: true)))) }
            } else {
                let body = part.trimmingCharacters(in: .newlines); if !body.isEmpty { views.append(prose(body)) }
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
            let label = wrapped(prompt(text)); label.translatesAutoresizingMaskIntoConstraints = false; bubble.addSubview(label)
            NSLayoutConstraint.activate([label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8), label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8), label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 10), label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -10)])
            bubble.setAccessibilityLabel(L10n.tr("你：\(text)")); return bubble
        case .item(let item):
            let running = item.status == .running
            switch item.kind {
            case .message: return rich(item.text.trimmingCharacters(in: .newlines))
            case .reasoning:
                let font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
                let lines = item.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
                // Live thinking shows its tail; once done it folds to its first line.
                let open = isOpen(key, default: running)
                let header = disclosure(key, open: open, tool: L10n.tr("思考"), argument: open ? "" : (lines.first ?? ""), hasBody: true)
                guard open else { return timeline(Theme.faint, running: running, symbol: "brain", header) }
                let (shown, toggle) = clipped(lines, key: key, collapsed: 3, tail: running)
                let label = wrapped(NSAttributedString(string: shown.joined(separator: "\n"), attributes: [.font: font, .foregroundColor: Theme.muted]))
                return timeline(Theme.faint, running: running, symbol: "brain", column([header, indented(label)] + (toggle.map { [indented($0)] } ?? []), spacing: 3))
            case .notice: return timeline(Theme.orange, symbol: "exclamationmark.triangle", wrapped(plain(item.text, size: 11.5, color: Theme.orange)))
            case .toolCall, .webSearch:
                let parts = item.text.components(separatedBy: " · ")
                let tool = item.kind == .webSearch ? "Web" : parts[0], argument = item.kind == .webSearch ? item.text : parts.dropFirst().joined(separator: " · ")
                let failed = item.status == .failed, open = isOpen(key, default: failed)
                var views: [NSView] = [disclosure(key, open: open, tool: tool, argument: argument, hasBody: !item.detail.isEmpty)]
                if open, !item.detail.isEmpty { views.append(indented(hanging(item.detail, failed: failed))) }
                return timeline(statusColor(item.status), running: running, symbol: symbol(for: item), column(views, spacing: 2))
            case .todo:
                let text = NSMutableAttributedString()
                let lines = item.detail.components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.soft]
                    if line.hasPrefix("☑") { attributes[.foregroundColor] = Theme.faint; attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    else if line.hasPrefix("▸") { attributes[.foregroundColor] = Theme.text; attributes[.font] = NSFont.systemFont(ofSize: 12.5, weight: .semibold) }
                    text.append(NSAttributedString(string: line + (index < lines.count - 1 ? "\n" : ""), attributes: attributes))
                }
                return timeline(statusColor(item.status), running: running, symbol: symbol(for: item), column([toolTitle(L10n.tr("待办"), ""), wrapped(text)], spacing: 3))
            case .command:
                let output = item.detail.trimmingCharacters(in: .newlines)
                let lines = output.isEmpty ? [] : output.components(separatedBy: "\n")
                let failed = item.status == .failed, open = isOpen(key, default: failed)
                var note: NSAttributedString?
                if let code = item.exitCode, code != 0 { note = summary(L10n.tr("退出码 \(code)"), color: Theme.red) }
                else if lines.count > 1 { note = summary(L10n.tr("\(lines.count) 行")) }
                var views: [NSView] = [disclosure(key, open: open, tool: "Bash", argument: item.text, summary: note, hasBody: !lines.isEmpty)]
                if open, !lines.isEmpty {
                    let (shown, toggle) = clipped(lines, key: key, collapsed: 12, tail: true)
                    views.append(indented(box(wrapped(plain(shown.joined(separator: "\n"), size: 11, color: failed ? Theme.red : Theme.muted, mono: true)))))
                    if let toggle { views.append(indented(toggle)) }
                }
                return timeline(statusColor(item.status), running: running, symbol: symbol(for: item), column(views, spacing: 4))
            case .fileChange:
                let change = item.detail.components(separatedBy: "\n")[0]
                let parts = change.components(separatedBy: "  "); let path = parts.dropFirst().joined(separator: "  ")
                let relative = directory.map { path.hasPrefix($0.path + "/") ? String(path.dropFirst($0.path.count + 1)) : path } ?? path
                let reveal = ActionButton("", symbol: "arrow.up.forward.square", style: .plain) { [weak self] in
                    guard let self, let directory = self.directory else { return }
                    self.onOpenFile?(path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path))
                }
                reveal.toolTip = L10n.tr("在编辑器中打开 \(path)"); reveal.setAccessibilityLabel(reveal.toolTip); reveal.setContentHuggingPriority(.required, for: .horizontal)
                let reason = item.detail.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                let failed = item.status == .failed, expandedRow = isOpen(key, default: failed)
                let tool = parts.first == L10n.tr("写入") ? "Write" : "Edit"
                var views: [NSView] = [disclosure(key, open: expandedRow, tool: tool, argument: relative, summary: diffSummary(item.diff), hasBody: !item.diff.isEmpty || (failed && !reason.isEmpty), trailing: [reveal])]
                if expandedRow, !item.diff.isEmpty {
                    let (shown, toggle) = clipped(item.diff.components(separatedBy: "\n"), key: key, collapsed: 16, tail: false)
                    views.append(indented(box(wrapped(diffText(shown))))); if let toggle { views.append(indented(toggle)) }
                }
                // A failed or denied edit explains itself on the lines after the path.
                if expandedRow, failed, !reason.isEmpty { views.append(indented(hanging(reason, failed: true))) }
                return timeline(statusColor(item.status), running: running, symbol: symbol(for: item), column(views, spacing: 4))
            }
        }
    }
    private func row(for key: String, _ entry: Entry) -> NSView {
        if provider == .claude, let view = claudeRow(for: key, entry) { return view }
        switch entry {
        case .user(let text):
            let bubble = Chip(fill: Theme.accent.withAlphaComponent(0.18), radius: 12)
            let label = wrapped(prompt(text)); label.translatesAutoresizingMaskIntoConstraints = false; bubble.addSubview(label)
            NSLayoutConstraint.activate([label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 7), label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -7), label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 11), label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -11)])
            let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let line = NSStackView(views: [spacer, bubble]); line.alignment = .top
            spacer.widthAnchor.constraint(greaterThanOrEqualTo: line.widthAnchor, multiplier: 0.12).isActive = true
            bubble.setAccessibilityLabel(L10n.tr("你：\(text)")); return line
        case .status(let text, let failed):
            return wrapped(plain(text, size: 11.5, color: failed ? Theme.red : Theme.faint), selectable: failed)
        case .item(let item):
            switch item.kind {
            case .message: return rich(item.text.trimmingCharacters(in: .newlines))
            case .reasoning: return wrapped(markdown(item.text.trimmingCharacters(in: .whitespacesAndNewlines), size: 12, color: Theme.muted))
            case .notice: return wrapped(plain(item.text, size: 11.5, color: Theme.orange))
            case .webSearch, .toolCall:
                let line = NSStackView(views: [statusIcon(item.status, symbol: item.kind == .webSearch ? "magnifyingglass" : "wrench.and.screwdriver"), wrapped(plain(item.text, size: 12, color: Theme.soft))]); line.spacing = 7; line.alignment = .firstBaseline
                return card(line)
            case .todo:
                let title = NSStackView(views: [statusIcon(item.status, symbol: "checklist"), Theme.label(L10n.tr("计划"), size: 12, color: Theme.soft, weight: .semibold)]); title.spacing = 7
                return card(column([title, wrapped(plain(item.detail, size: 12.5))]))
            case .fileChange:
                let title = NSStackView(views: [statusIcon(item.status, symbol: "doc.badge.gearshape"), Theme.label(L10n.tr("修改了 \(item.text)"), size: 12, color: Theme.soft, weight: .semibold)]); title.spacing = 7
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
                if let code = item.exitCode, code != 0 { header.append(Theme.label(L10n.tr("退出码 \(code)"), size: 11, color: Theme.red)) }
                let output = item.detail.trimmingCharacters(in: .newlines)
                let lines = output.isEmpty ? [] : output.components(separatedBy: "\n")
                // Output stays folded behind the line count; a failed command opens to show it.
                let open = isOpen(key, default: item.status == .failed)
                if !lines.isEmpty {
                    let toggle = ActionButton(L10n.tr("\(lines.count) 行"), symbol: open ? "chevron.down" : "chevron.right", style: .plain) { [weak self] in self?.toggle(key, from: open) }
                    toggle.setAccessibilityExpanded(open); header.append(toggle)
                }
                let top = NSStackView(views: header); top.spacing = 7; top.alignment = .centerY
                guard open, !lines.isEmpty else { return card(top) }
                return card(column([top, wrapped(plain(lines.suffix(400).joined(separator: "\n"), size: 11, color: item.status == .failed ? Theme.red : Theme.muted, mono: true))]))
            }
        }
    }
}

/// Selectable, wrapping text for replies that hands BetterTeX's own links to the chat instead of the
/// browser. Sizes itself to its text at the width layout gives it.
final class LinkTextView: NSTextView {
    static let scheme = "bettertex"
    var onLocation: ((String) -> Void)?
    convenience init(_ text: NSAttributedString) {
        let storage = NSTextStorage(attributedString: text), layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true; container.lineFragmentPadding = 0; layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        isEditable = false; isSelectable = true; drawsBackground = false; textContainerInset = .zero
        isVerticallyResizable = false; isHorizontallyResizable = false; isRichText = true
        linkTextAttributes = [.foregroundColor: Theme.accent, .cursor: NSCursor.pointingHand, .underlineStyle: 0]
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.init(1), for: .horizontal); setContentCompressionResistancePriority(.init(1), for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical); setContentCompressionResistancePriority(.required, for: .vertical)
    }
    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return .zero }
        // Measure at the width the view has now; the container only follows the frame later.
        if bounds.width > 0, textContainer.containerSize.width != bounds.width {
            textContainer.containerSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(layoutManager.usedRect(for: textContainer).height))
    }
    override func setFrameSize(_ size: NSSize) {
        let changed = size.width != frame.width
        super.setFrameSize(size)
        if changed { invalidateIntrinsicContentSize() }
    }
    override func clicked(onLink link: Any, at charIndex: Int) {
        let url = link as? URL ?? (link as? String).flatMap(URL.init(string:))
        if let url, url.scheme == Self.scheme {
            onLocation?(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "target" }?.value ?? "")
        } else if let url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
    }
}
