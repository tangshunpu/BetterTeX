import AppKit
import SwiftTerm
import BetterTeXCore

final class AdaptiveTerminal: LocalProcessTerminalView {
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeBackgroundColor = Theme.base.usingColorSpace(.deviceRGB) ?? .textBackgroundColor
            nativeForegroundColor = Theme.text.usingColorSpace(.deviceRGB) ?? .textColor
            caretColor = Theme.accent
        }
    }
}

/// The multi-line prompt field: Return sends, Shift-Return inserts a line break.
/// The real product icons, read at run time from the Codex and Claude apps installed on this
/// Mac (nothing is bundled). Without the app, callers fall back to a generic symbol.
enum AgentLogo {
    private static let bundles = ["Codex": ["com.openai.codex", "com.openai.chat"], "Claude": ["com.anthropic.claudefordesktop"]]
    private static var cache: [String: NSImage?] = [:]
    static func image(for tab: String, side: CGFloat) -> NSImage? {
        if cache[tab] == nil {
            let app = (bundles[tab] ?? []).lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
            cache[tab] = .some(app.map { NSWorkspace.shared.icon(forFile: $0.path) })
        }
        guard let icon = cache[tab] ?? nil, let copy = icon.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: side, height: side); return copy
    }
}

final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !hasMarkedText(), event.modifierFlags.intersection([.shift, .option]).isEmpty { onSubmit?(); return }
        super.keyDown(with: event)
    }
}

final class TerminalPanel: Surface, LocalProcessTerminalViewDelegate, NSTextViewDelegate {
    let header = PanelHeader("agent", title: "Agent")
    // "Agent" is the native Codex conversation; the others are terminal sessions and the build log.
    private let tabNames = ["Agent", "Codex", "Claude", "Shell", "Output"]
    private let switcher = SegmentedTabs(["对话", "Codex", "Claude", "Shell", "输出"])
    let chat = AgentChatView()
    var onOpenFile: ((URL) -> Void)?
    private var sandboxButton: ActionButton!
    private var sandbox = CodexSandbox(rawValue: UserDefaults.standard.string(forKey: "agent.codex.sandbox") ?? "") ?? .workspaceWrite
    let content = Surface()
    let logView = NSTextView()
    let logScroll = NSScrollView()
    let hint = Theme.label("↩ 发送 · ⇧↩ 换行 · 使用本机登录", size: 11, color: Theme.muted)
    private let composer = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
    private let placeholder = Theme.label("让 Agent 修改或解释…", size: 13.5, color: Theme.muted)
    private var composerHeight: NSLayoutConstraint!
    private let composerScroll = NSScrollView()
    private var composerCard: NSView!
    private var composerTools: NSView!
    private var compactAttach: ActionButton!
    private var effortButton: ActionButton!
    private var includeContext = true
    private let contextChip = Chip(fill: Theme.fill, radius: -1)
    private let contextLabel = NSTextField(labelWithString: "")
    var terminals: [String: AdaptiveTerminal] = [:]
    var active = "Agent"
    var project: URL?
    var tools: Toolchain?
    var onError: ((String) -> Void)?
    var onDiagnostic: ((String, Int) -> Void)?
    var currentContext: (() -> String?)?
    /// Project-relative path of the file being edited, mentioned in prompts sent from the composer.
    var contextFile: String? { didSet { updateContextChip() } }
    /// Lines covered by the editor selection; when set, the selected source is sent with the prompt.
    var contextLines: ClosedRange<Int>? { didSet { if contextLines != oldValue { updateContextChip() } } }
    private var selectedProvider: AgentProvider = .codex
    private var configurations: [AgentProvider: AgentConfiguration] = [:]
    private var modelButton: ActionButton!
    private var pendingPrompt: String?
    private var pendingResume: AgentSession?
    private var history: [AgentSession] = []
    private var historyButton: ActionButton!
    let empty = NSStackView()
    /// Folded, the panel is a slim rail of tab buttons; sessions keep running behind it.
    var onFold: ((Bool) -> Void)?
    private let rail = Surface()
    private let railStack = NSStackView()
    private var railButtons: [String: ActionButton] = [:]
    private var railConstraints: [NSLayoutConstraint] = []
    static let railThickness: CGFloat = 40
    private var hero: NSView!
    private var suggestions: NSView!
    override init(frame: NSRect) {
        super.init(frame: frame); fill = Theme.base; content.fill = Theme.base
        for provider in AgentProvider.allCases {
            configurations[provider] = AgentConfiguration(model: UserDefaults.standard.string(forKey: "agent.\(provider.rawValue).model") ?? "", effort: UserDefaults.standard.string(forKey: "agent.\(provider.rawValue).effort") ?? "")
        }
        switcher.onSelect = { [weak self] index in guard let self else { return }; self.select(self.tabNames[index]) }
        switcher.setContentHuggingPriority(.init(1), for: .horizontal)
        header.setLeading(switcher)
        let new = ActionButton("", symbol: "square.and.pencil", style: .accentIcon) { [weak self] in self?.newSession() }; new.toolTip = "新建会话"
        let fold = ActionButton("", symbol: "chevron.right.2") { [weak self] in self?.onFold?(true) }; fold.toolTip = "折叠 Agent 面板  ⌘J"
        historyButton = ActionButton("", symbol: "clock.arrow.circlepath") { [weak self] in self?.showHistory() }; historyButton.toolTip = "会话历史"
        // One tight group keeps room for the tab titles in a narrow panel.
        let controls = NSStackView(views: [historyButton, new, fold]); controls.spacing = 0; controls.alignment = .centerY
        controls.setContentCompressionResistancePriority(.required, for: .horizontal)
        header.addControl(controls)
        header.menuActions = [("结束当前会话", "stop.circle", { [weak self] in self?.stopActive() })]

        // Composer: context chip, growing text field, then pickers and send in one card.
        contextChip.size(nil, 22); contextChip.pinRow(contextLabel, leading: 8, trailing: 8)
        contextChip.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggleContext)))
        contextChip.setAccessibilityElement(true); contextChip.setAccessibilityRole(.checkBox)
        // While a CLI session is on screen it has its own prompt, so the card shrinks to this row.
        compactAttach = ActionButton("加入 CLI 输入", symbol: "plus", style: .tinted) { [weak self] in self?.attachContext() }
        compactAttach.toolTip = "把当前文件 / 选区加入 CLI 的输入行"; compactAttach.isHidden = true
        let contextRow = NSStackView(views: [contextChip, NSView(), compactAttach]); contextRow.spacing = 6; contextRow.alignment = .centerY
        composer.isRichText = false; composer.drawsBackground = false; composer.font = .systemFont(ofSize: 13.5); composer.textColor = Theme.text
        composer.insertionPointColor = Theme.accent; composer.textContainerInset = NSSize(width: 0, height: 2); composer.textContainer?.lineFragmentPadding = 0
        composer.isVerticallyResizable = true; composer.isHorizontallyResizable = false; composer.autoresizingMask = [.width]
        composer.textContainer?.widthTracksTextView = true; composer.minSize = NSSize(width: 0, height: 22); composer.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        composer.isAutomaticQuoteSubstitutionEnabled = false; composer.isAutomaticDashSubstitutionEnabled = false; composer.allowsUndo = true
        composer.delegate = self; composer.onSubmit = { [weak self] in self?.sendPrompt() }; composer.setAccessibilityLabel("给 Agent 的消息")
        composerScroll.drawsBackground = false; composerScroll.borderType = .noBorder
        composerScroll.hasVerticalScroller = true; composerScroll.autohidesScrollers = true; composerScroll.documentView = composer
        composerHeight = composerScroll.heightAnchor.constraint(equalToConstant: 22); composerHeight.isActive = true
        let attach = ActionButton("", symbol: "plus") { [weak self] in self?.attachContext() }; attach.toolTip = "将当前文件 / 选区加入 CLI 输入"
        modelButton = ActionButton("", symbol: "chevron.down", style: .plain) { [weak self] in self?.showModelMenu() }; modelButton.toolTip = "选择模型"
        effortButton = ActionButton("", symbol: "chevron.down", style: .plain) { [weak self] in self?.showEffortMenu() }; effortButton.toolTip = "选择思考强度"
        for button in [modelButton!, effortButton!] { button.cell?.lineBreakMode = .byTruncatingTail; button.setContentCompressionResistancePriority(.init(200), for: .horizontal) }
        let send = ActionButton("", symbol: "arrow.up", style: .send) { [weak self] in self?.sendPrompt() }; send.toolTip = "发送  ↩"
        let toolSpacer = NSView(); toolSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        sandboxButton = ActionButton("", symbol: "chevron.down", style: .plain) { [weak self] in self?.showSandboxMenu() }; sandboxButton.toolTip = "Codex 可以做什么"
        sandboxButton.setContentCompressionResistancePriority(.init(600), for: .horizontal); sandboxButton.setTitle(sandbox.title)
        chat.onOpenFile = { [weak self] in self?.onOpenFile?($0) }
        chat.onLog = { [weak self] in self?.append("\nCodex\n" + $0 + "\n") }
        chat.onChange = { [weak self] in
            guard let self else { return }
            if self.active == "Agent" { self.showChatOrEmpty() }
            self.hint.stringValue = self.chat.running ? "Codex 正在工作 · 可在对话里点停止" : "↩ 发送给 Codex · ⇧↩ 换行 · 使用本机 codex 登录"
        }
        let toolRow = NSStackView(views: [attach, modelButton, effortButton, sandboxButton, toolSpacer, send]); toolRow.spacing = 2; toolRow.alignment = .centerY
        let cardStack = NSStackView(views: [contextRow, composerScroll, toolRow]); cardStack.orientation = .vertical; cardStack.spacing = 8; cardStack.alignment = .leading
        for row in [contextRow, composerScroll, toolRow] { row.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true }
        let field = Chip(fill: Theme.card, radius: 14, border: Theme.adaptive(0x3C3C43, 0xFFFFFF, lightAlpha: 0.18, darkAlpha: 0.12))
        composerCard = field; composerTools = toolRow
        cardStack.translatesAutoresizingMaskIntoConstraints = false; field.addSubview(cardStack)
        NSLayoutConstraint.activate([cardStack.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 12), cardStack.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -8), cardStack.topAnchor.constraint(equalTo: field.topAnchor, constant: 10), cardStack.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -6)])
        // The placeholder sits over the text view but outside the scroll view, which would otherwise tile it.
        placeholder.translatesAutoresizingMaskIntoConstraints = false; placeholder.lineBreakMode = .byTruncatingTail; field.addSubview(placeholder)
        NSLayoutConstraint.activate([placeholder.leadingAnchor.constraint(equalTo: composerScroll.leadingAnchor), placeholder.topAnchor.constraint(equalTo: composerScroll.topAnchor, constant: 2), placeholder.trailingAnchor.constraint(lessThanOrEqualTo: composerScroll.trailingAnchor)])
        field.addGestureRecognizer({ let click = NSClickGestureRecognizer(target: self, action: #selector(focusComposer)); click.delaysPrimaryMouseButtonEvents = false; return click }())
        hint.alignment = .center; hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        let footer = NSStackView(views: [field, hint]); footer.orientation = .vertical; footer.spacing = 8; footer.alignment = .leading
        for row in [field, hint] { row.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true }

        for view in [header, content, footer] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor), header.heightAnchor.constraint(equalToConstant: 46),
            content.topAnchor.constraint(equalTo: header.bottomAnchor), content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor), content.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
        buildRail()
        logView.isEditable = false; logView.isSelectable = true; logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSSize(width: 12, height: 10); logView.autoresizingMask = [.width]
        logView.isVerticallyResizable = true; logView.textContainer?.widthTracksTextView = true
        logScroll.hasVerticalScroller = true; logScroll.autohidesScrollers = true; logScroll.documentView = logView; logScroll.drawsBackground = false
        let gesture = NSClickGestureRecognizer(target: self, action: #selector(logClicked(_:))); gesture.numberOfClicksRequired = 2; logView.addGestureRecognizer(gesture)
        buildEmptyState()
        showEmpty(); updateColors(); updateModelButton(); updateContextChip()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A grouped inset list: rows on a card, separated by inset hairlines.
    private func card(_ rows: [NSView], separatorInset: CGFloat) -> NSView {
        let card = Chip(fill: Theme.card, radius: 12); card.layer?.masksToBounds = true
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 0; stack.alignment = .leading
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let holder = NSView(); let rule = Chip(fill: Theme.hairline, radius: 0); rule.translatesAutoresizingMaskIntoConstraints = false; holder.addSubview(rule)
                NSLayoutConstraint.activate([holder.heightAnchor.constraint(equalToConstant: 1), rule.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: separatorInset), rule.trailingAnchor.constraint(equalTo: holder.trailingAnchor), rule.topAnchor.constraint(equalTo: holder.topAnchor), rule.bottomAnchor.constraint(equalTo: holder.bottomAnchor)])
                stack.addArrangedSubview(holder); holder.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        card.pin(stack); return card
    }
    private func providerRow(_ name: String, detail: String, tile: NSColor, symbol: String, primary: Bool, tab: String) -> NSView {
        let icon: NSView
        if let logo = AgentLogo.image(for: tab, side: 34) { let view = NSImageView(image: logo); view.size(34, 34); icon = view }
        else {
            let chip = Chip(fill: tile, radius: 7); chip.size(30, 30)
            let glyph = NSImageView(image: Theme.symbol(symbol, size: 13, weight: .bold)!); glyph.contentTintColor = NSColor(hex: 0x1C1C1E)
            glyph.translatesAutoresizingMaskIntoConstraints = false; chip.addSubview(glyph)
            NSLayoutConstraint.activate([glyph.centerXAnchor.constraint(equalTo: chip.centerXAnchor), glyph.centerYAnchor.constraint(equalTo: chip.centerYAnchor)])
            icon = chip
        }
        let text = NSStackView(views: [Theme.label(name, size: 14, weight: .semibold), Theme.label(detail, size: 12, color: Theme.muted)]); text.orientation = .vertical; text.spacing = 1; text.alignment = .leading
        text.setHuggingPriority(.init(1), for: .horizontal)
        let launch = ActionButton("启动", style: primary ? .pill : .tinted) { [weak self] in self?.select(tab) }
        launch.setAccessibilityLabel("启动 \(name)")
        let row = NSStackView(views: [icon, text, launch]); row.spacing = 12; row.alignment = .centerY
        let holder = NSView(); holder.heightAnchor.constraint(equalToConstant: 56).isActive = true; holder.pinRow(row, leading: 12, trailing: 12)
        return holder
    }
    private func buildEmptyState() {
        let tile = Chip(fill: Theme.accent.withAlphaComponent(0.18), radius: 16); tile.size(56, 56)
        let sparkle = NSImageView(image: Theme.symbol("sparkles", size: 24, weight: .semibold)!); sparkle.contentTintColor = Theme.accent
        sparkle.translatesAutoresizingMaskIntoConstraints = false; tile.addSubview(sparkle)
        NSLayoutConstraint.activate([sparkle.centerXAnchor.constraint(equalTo: tile.centerXAnchor), sparkle.centerYAnchor.constraint(equalTo: tile.centerYAnchor)])
        let description = NSTextField(wrappingLabelWithString: "连接本机 Codex 或 Claude Code，在当前项目中继续你的工作。")
        description.font = .systemFont(ofSize: 13); description.textColor = Theme.muted; description.alignment = .center
        description.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        let heroStack = NSStackView(views: [tile, Theme.label("让 Agent 加入写作", size: 20, weight: .bold), description]); heroStack.orientation = .vertical; heroStack.spacing = 8; heroStack.alignment = .centerX
        heroStack.setCustomSpacing(14, after: tile); hero = heroStack
        let providers = card([
            providerRow("Codex", detail: "本机 CLI · 默认", tile: NSColor(hex: 0x64D2FF), symbol: "chevron.left.forwardslash.chevron.right", primary: true, tab: "Codex"),
            providerRow("Claude Code", detail: "本机 CLI", tile: NSColor(hex: 0xFF9F0A), symbol: "sparkle", primary: false, tab: "Claude")
        ], separatorInset: 54)
        let prompts = ["润色摘要，让它更简洁", "检查公式与引用编号", "修复编译警告"].map { prompt -> NSView in
            let row = RowButton(height: 44) { [weak self] in
                guard let self else { return }
                self.setComposer(prompt); self.window?.makeFirstResponder(self.composer)
            }
            row.setAccessibilityLabel(prompt)
            let chevron = NSImageView(image: Theme.symbol("chevron.right", size: 10, weight: .bold)!); chevron.contentTintColor = Theme.faint
            let label = Theme.label(prompt, size: 13); label.lineBreakMode = .byTruncatingTail; label.setContentHuggingPriority(.init(1), for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let content = NSStackView(views: [label, chevron]); content.spacing = 10; content.alignment = .centerY
            row.pinRow(content, leading: 12, trailing: 12); return row
        }
        let caption = Theme.label("试试这样问", size: 12, color: Theme.muted)
        let captionHolder = NSView(); captionHolder.pinRow(caption, leading: 12, trailing: 12); captionHolder.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let suggestionStack = NSStackView(views: [captionHolder, card(prompts, separatorInset: 12)]); suggestionStack.orientation = .vertical; suggestionStack.spacing = 6; suggestionStack.alignment = .leading
        for view in suggestionStack.arrangedSubviews { view.widthAnchor.constraint(equalTo: suggestionStack.widthAnchor).isActive = true }
        suggestions = suggestionStack
        empty.orientation = .vertical; empty.spacing = 22; empty.alignment = .centerX
        for view in [heroStack, providers, suggestionStack] { empty.addArrangedSubview(view) }
        providers.widthAnchor.constraint(equalTo: empty.widthAnchor).isActive = true; suggestionStack.widthAnchor.constraint(equalTo: empty.widthAnchor).isActive = true
    }
    override func layout() {
        // Keep the launch card visible when the pane is docked short.
        super.layout()
        // Keep the composer as wide as its scroll view so long lines wrap instead of running off the edge.
        let width = composerScroll.contentSize.width
        if width > 0, abs(composer.frame.width - width) > 0.5 {
            composer.setFrameSize(NSSize(width: width, height: composer.frame.height)); textDidChange(Notification(name: NSText.didChangeNotification))
        }
        let height = content.bounds.height
        if suggestions?.isHidden != (height < 500) { suggestions?.isHidden = height < 500 }
        if hero?.isHidden != (height < 300) { hero?.isHidden = height < 300 }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors(); updateContextChip() }
    func updateColors() { logView.backgroundColor = Theme.base; logView.textColor = Theme.muted }
    private func updateContextChip() {
        contextChip.isHidden = contextFile == nil
        let name = (contextFile as NSString?)?.lastPathComponent ?? ""
        let off: [NSAttributedString.Key: Any] = includeContext ? [:] : [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        let text = NSMutableAttributedString(string: "@", attributes: [.foregroundColor: includeContext ? Theme.accent : Theme.muted, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
        text.append(NSAttributedString(string: name, attributes: [.foregroundColor: includeContext ? Theme.text : Theme.muted, .font: NSFont.systemFont(ofSize: 12)].merging(off) { $1 }))
        if let lines = contextLines {
            let range = lines.lowerBound == lines.upperBound ? ":\(lines.lowerBound)" : ":\(lines.lowerBound)-\(lines.upperBound)"
            text.append(NSAttributedString(string: range, attributes: [.foregroundColor: Theme.muted, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)].merging(off) { $1 }))
        }
        contextLabel.attributedStringValue = text
        let what = contextLines == nil ? "当前文件" : "所选的 \(contextLines!.count) 行源码"
        contextChip.toolTip = includeContext ? "发送时附带\(what) · 点按以取消" : "发送时不附带上下文 · 点按以附带\(what)"
        contextChip.setAccessibilityLabel("附带上下文 \(name)"); contextChip.setAccessibilityValue(includeContext)
    }
    @objc private func toggleContext() { includeContext.toggle(); updateContextChip() }
    @objc private func focusComposer() { window?.makeFirstResponder(composer) }
    private func setComposer(_ text: String) { composer.string = text; textDidChange(Notification(name: NSText.didChangeNotification)) }
    private func buildRail() {
        rail.fill = Theme.base; rail.isHidden = true; rail.translatesAutoresizingMaskIntoConstraints = false; addSubview(rail)
        NSLayoutConstraint.activate([rail.topAnchor.constraint(equalTo: topAnchor), rail.bottomAnchor.constraint(equalTo: bottomAnchor), rail.leadingAnchor.constraint(equalTo: leadingAnchor), rail.trailingAnchor.constraint(equalTo: trailingAnchor)])
        let expand = ActionButton("", symbol: "chevron.left.2") { [weak self] in self?.onFold?(false) }; expand.toolTip = "展开 Agent 面板  ⌘J"
        railStack.addArrangedSubview(expand); railStack.setCustomSpacing(10, after: expand)
        for (name, symbol, title) in [("Agent", "bubble.left.and.text.bubble.right", "Codex 对话"), ("Codex", "chevron.left.forwardslash.chevron.right", "Codex 终端"), ("Claude", "sparkle", "Claude"), ("Shell", "terminal", "Shell"), ("Output", "text.alignleft", "编译与 Git 输出")] {
            let button = ActionButton("", symbol: symbol) { [weak self] in self?.onFold?(false); self?.select(name) }
            if let logo = AgentLogo.image(for: name, side: 20) { button.image = logo }
            button.toolTip = "展开并打开 \(title)"; button.setAccessibilityLabel(title); railButtons[name] = button; railStack.addArrangedSubview(button)
        }
        railStack.spacing = 4; railStack.translatesAutoresizingMaskIntoConstraints = false; rail.addSubview(railStack)
    }
    /// Shows the rail instead of the panel. `horizontal` lays the buttons in a row (bottom dock).
    func setFolded(_ folded: Bool, horizontal: Bool) {
        rail.isHidden = !folded
        for view in subviews where view !== rail { view.isHidden = folded }
        if !folded { updateComposerMode(); if let terminal = terminals[active] { window?.makeFirstResponder(terminal) }; return }
        NSLayoutConstraint.deactivate(railConstraints)
        railStack.orientation = horizontal ? .horizontal : .vertical
        railConstraints = horizontal ? [railStack.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 8), railStack.centerYAnchor.constraint(equalTo: rail.centerYAnchor)]
                                     : [railStack.topAnchor.constraint(equalTo: rail.topAnchor, constant: 8), railStack.centerXAnchor.constraint(equalTo: rail.centerXAnchor)]
        NSLayoutConstraint.activate(railConstraints); updateRail()
    }
    /// Tabs with a live session are tinted so a folded panel still shows what is running.
    private func updateRail() {
        for (name, button) in railButtons {
            let running = terminals[name] != nil
            button.contentTintColor = running ? Theme.accent : Theme.muted
            // Logos keep their own colours, so idle ones are dimmed instead of tinted.
            if AgentLogo.image(for: name, side: 20) != nil { button.alphaValue = running ? 1 : 0.5 }
        }
    }
    /// The full composer starts sessions. Once an agent CLI is showing, its own prompt takes over
    /// and only the context row remains; the shell and the build output need neither.
    private func updateComposerMode() {
        let agentRunning = AgentProvider(rawValue: active) != nil && terminals[active] != nil
        let hidden = active == "Shell" || active == "Output"
        composerCard.isHidden = hidden || !rail.isHidden; updateRail()
        sandboxButton.isHidden = active != "Agent"
        composerScroll.isHidden = agentRunning; composerTools.isHidden = agentRunning; compactAttach.isHidden = !agentRunning
        placeholder.isHidden = agentRunning || !composer.string.isEmpty
    }
    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = composerScroll.isHidden || !composer.string.isEmpty
        guard let layout = composer.layoutManager, let container = composer.textContainer else { return }
        layout.ensureLayout(for: container)
        composerHeight.constant = min(max(22, layout.usedRect(for: container).height + 4), 112)
    }
    func configure(project: URL, tools: Toolchain) { self.project = project; self.tools = tools }
    /// The conversation tab shows the start page until the first message.
    private func showChatOrEmpty() {
        if chat.isEmpty { showEmpty() }
        else if chat.superview !== content { content.subviews.forEach { $0.removeFromSuperview() }; content.pin(chat) }
    }
    private func showSandboxMenu() {
        let menu = NSMenu()
        for mode in CodexSandbox.allCases {
            let item = ClosureMenuItem(mode.title, checked: mode == sandbox) { [weak self] in
                guard let self else { return }
                self.sandbox = mode; UserDefaults.standard.set(mode.rawValue, forKey: "agent.codex.sandbox"); self.sandboxButton.setTitle(mode.title)
            }
            item.toolTip = mode.detail
            if #available(macOS 14.4, *) { item.subtitle = mode.detail }
            menu.addItem(item)
        }
        popUp(menu, from: sandboxButton)
    }
    func showEmpty() {
        content.subviews.forEach { $0.removeFromSuperview() }; empty.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(empty)
        switcher.selected = active == "Agent" ? 0 : -1
        NSLayoutConstraint.activate([empty.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), empty.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), empty.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
        needsLayout = true
    }
    /// Sends the composer text to the agent CLI, launching it with the prompt if needed.
    @objc private func sendPrompt() {
        let text = composer.string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{1b}", with: "")
        guard !text.isEmpty else { return }
        if active == "Agent" {
            guard !chat.running else { hint.stringValue = "Codex 还在处理上一条 · 等它完成或先点停止"; return }
            guard let project, let tools else { hint.stringValue = "请先打开一个项目"; return }
            guard let codex = tools["codex"] else { onError?("未检测到 codex。请先安装并登录 Codex CLI，然后在「工作区」菜单重新检测工具。"); return }
            var prompt = text
            if includeContext, let file = contextFile {
                if contextLines != nil, let excerpt = currentContext?() { prompt = "当前文件与选中的内容：\n" + excerpt.replacingOccurrences(of: "\u{1b}", with: "") + "\n\n" + text }
                else { prompt = "当前文件：\(file)\n\n" + text }
            }
            chat.send(prompt: prompt, display: text, executable: codex, directory: project, environment: tools.environment, configuration: configurations[.codex] ?? AgentConfiguration(), sandbox: sandbox)
            setComposer(""); return
        }
        let name = AgentProvider(rawValue: active)?.rawValue ?? selectedProvider.rawValue
        var message = text
        if includeContext, let file = contextFile {
            // A selection travels as a fenced excerpt; otherwise the file is only mentioned.
            if contextLines != nil, let excerpt = currentContext?() { message = excerpt.replacingOccurrences(of: "\u{1b}", with: "") + "\n" + text }
            else { message = "@\(file) " + text }
        }
        if let terminal = terminals[name] {
            guard terminal.getTerminal().bracketedPasteMode else { hint.stringValue = "等待 CLI 进入输入界面后再发送"; return }
            if active != name { select(name) }
            terminal.send(txt: "\u{1b}[200~" + message + "\u{1b}[201~")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak terminal] in terminal?.send(txt: "\r") }
        } else {
            pendingPrompt = message; select(name); pendingPrompt = nil
            guard terminals[name] != nil else { return }
        }
        setComposer(""); hint.stringValue = "已发送给 \(name)"; updateComposerMode()
    }
    func select(_ name: String) {
        active = name
        defer { updateComposerMode() }
        if let provider = AgentProvider(rawValue: name) { selectedProvider = provider; updateModelButton() }
        switcher.selected = tabNames.firstIndex(of: name) ?? -1
        content.subviews.forEach { $0.removeFromSuperview() }
        if name == "Agent" { selectedProvider = .codex; updateModelButton(); showChatOrEmpty(); hint.stringValue = chat.running ? "Codex 正在工作 · 可在对话里点停止" : "↩ 发送给 Codex · ⇧↩ 换行 · 使用本机 codex 登录"; return }
        if name == "Output" { content.pin(logScroll); hint.stringValue = "编译与 Git 输出 · 双击错误定位"; return }
        guard let project, let tools else { showEmpty(); onError?("正在检测本机工具，请稍候。"); return }
        if let existing = terminals[name] { content.pin(existing, inset: 10); window?.makeFirstResponder(existing); hint.stringValue = "\(name) · \(project.lastPathComponent)"; return }
        let binary = name == "Shell" ? (tools.environment["SHELL"] ?? "/bin/zsh") : tools[name.lowercased()]
        guard let binary else { showEmpty(); onError?("未检测到 \(name)。请先在本机安装对应 CLI，然后在“工作区”菜单重新检测工具。"); return }
        var options = TerminalOptions.default; options.scrollback = 2000
        let args: [String]
        do {
            let settings = name == "Shell" ? [] : try (configurations[selectedProvider] ?? AgentConfiguration()).arguments(for: selectedProvider)
            if name == "Shell" { args = ["-l"] }
            else if let session = pendingResume, session.provider == selectedProvider { args = try AgentHistory.resumeArguments(for: session) + settings }
            else { args = settings + (pendingPrompt.map { [$0] } ?? []) }
        }
        catch { showEmpty(); onError?(error.localizedDescription); return }
        let terminal = AdaptiveTerminal(frame: NSRect(x: 0, y: 0, width: max(240, content.bounds.width), height: max(100, content.bounds.height)), font: .monospacedSystemFont(ofSize: 12, weight: .regular), options: options)
        terminal.processDelegate = self; terminal.optionAsMetaKey = false; terminal.updateColors()
        terminals[name] = terminal; content.pin(terminal, inset: 10); content.layoutSubtreeIfNeeded()
        terminal.startProcess(executable: binary, args: args, environment: tools.environment.map { "\($0.key)=\($0.value)" }, currentDirectory: project.path)
        window?.makeFirstResponder(terminal); hint.stringValue = "\(name) · \(project.lastPathComponent)"
    }
    private static func effortTitle(_ value: String) -> String {
        ["": "CLI 默认", "none": "无 · none", "minimal": "最少 · minimal", "low": "低 · low", "medium": "中 · medium", "high": "高 · high", "xhigh": "极高 · xhigh", "max": "最大 · max", "ultra": "超高 · ultra"][value] ?? value
    }
    private func availableModels(for provider: AgentProvider) -> [AgentModel] {
        if provider == .codex {
            let home = tools?.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
            let data = try? Data(contentsOf: URL(fileURLWithPath: home).appendingPathComponent("models_cache.json"))
            return data.map(AgentConfiguration.codexModels(from:)) ?? []
        }
        return ["opus", "sonnet", "haiku"].map { AgentModel(id: $0, name: $0.capitalized, efforts: ["low", "medium", "high", "xhigh", "max"]) }
    }
    private func efforts(for provider: AgentProvider, model: String) -> [String] {
        availableModels(for: provider).first { $0.id == model }?.efforts ?? (provider == .codex ? AgentConfiguration.knownEfforts : ["low", "medium", "high", "xhigh", "max"])
    }
    private func updateModelButton() {
        let config = configurations[selectedProvider] ?? AgentConfiguration()
        let name = availableModels(for: selectedProvider).first { $0.id == config.model }?.name ?? config.model
        modelButton.setTitle(config.model.isEmpty ? "\(selectedProvider.rawValue) 默认" : name)
        effortButton.setTitle(config.effort.isEmpty ? "默认强度" : config.effort)
    }
    /// Pops a picker upward from a composer button without pre-highlighting any row.
    private func popUp(_ menu: NSMenu, from button: NSButton) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -(menu.size.height + 6)), in: button)
    }
    private func menuHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; return item
    }
    private func showModelMenu() {
        let provider = selectedProvider; let current = configurations[provider]?.model ?? ""
        let models = availableModels(for: provider)
        let menu = NSMenu(); menu.autoenablesItems = false; menu.addItem(menuHeader("\(provider.rawValue) 模型"))
        func add(_ title: String, _ id: String) {
            let item = NSMenuItem(title: title, action: #selector(modelPicked(_:)), keyEquivalent: ""); item.target = self
            item.representedObject = id; item.state = id == current ? .on : .off; menu.addItem(item)
        }
        add("CLI 默认", "")
        for model in models { add(model.name, model.id) }
        if !current.isEmpty, !models.contains(where: { $0.id == current }) { add(current, current) }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "自定义模型 ID…", action: #selector(customModel), keyEquivalent: ""); custom.target = self; menu.addItem(custom)
        addRestartItem(to: menu, provider: provider)
        popUp(menu, from: modelButton)
    }
    private func showEffortMenu() {
        let provider = selectedProvider; let config = configurations[provider] ?? AgentConfiguration()
        let menu = NSMenu(); menu.autoenablesItems = false; menu.addItem(menuHeader("思考强度"))
        for level in [""] + efforts(for: provider, model: config.model) {
            let item = NSMenuItem(title: Self.effortTitle(level), action: #selector(effortPicked(_:)), keyEquivalent: ""); item.target = self
            item.representedObject = level; item.state = level == config.effort ? .on : .off; menu.addItem(item)
        }
        addRestartItem(to: menu, provider: provider)
        popUp(menu, from: effortButton)
    }
    private func addRestartItem(to menu: NSMenu, provider: AgentProvider) {
        guard terminals[provider.rawValue] != nil else { return }
        menu.addItem(.separator())
        let restart = NSMenuItem(title: "用当前配置新建会话", action: #selector(restartSession), keyEquivalent: ""); restart.target = self; menu.addItem(restart)
    }
    @objc private func modelPicked(_ item: NSMenuItem) {
        var config = configurations[selectedProvider] ?? AgentConfiguration()
        config.model = item.representedObject as? String ?? ""
        // Drop an effort the newly chosen model cannot run.
        if !config.effort.isEmpty, !efforts(for: selectedProvider, model: config.model).contains(config.effort) { config.effort = "" }
        apply(config)
    }
    @objc private func effortPicked(_ item: NSMenuItem) {
        var config = configurations[selectedProvider] ?? AgentConfiguration()
        config.effort = item.representedObject as? String ?? ""; apply(config)
    }
    @objc private func customModel() {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "自定义 \(selectedProvider.rawValue) 模型"; alert.informativeText = "输入 CLI 支持的模型 ID。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); field.stringValue = configurations[selectedProvider]?.model ?? ""; field.placeholderString = "模型 ID"
        alert.accessoryView = field; alert.addButton(withTitle: "使用"); alert.addButton(withTitle: "取消"); alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            var config = self.configurations[self.selectedProvider] ?? AgentConfiguration()
            config.model = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); self.apply(config)
        }
    }
    @objc private func restartSession() { newSession(provider: selectedProvider) }
    private func apply(_ config: AgentConfiguration) {
        let provider = selectedProvider
        do { _ = try config.arguments(for: provider) } catch { onError?(error.localizedDescription); return }
        configurations[provider] = config
        UserDefaults.standard.set(config.model, forKey: "agent.\(provider.rawValue).model"); UserDefaults.standard.set(config.effort, forKey: "agent.\(provider.rawValue).effort")
        updateModelButton()
        hint.stringValue = terminals[provider.rawValue] == nil ? "配置已更新 · 下次启动 \(provider.rawValue) 时生效" : "配置已更新 · 新建会话后生效"
    }
    // MARK: History
    /// Lists this project's past Codex and Claude conversations, newest first, to resume one.
    private func showHistory() {
        guard let project else { hint.stringValue = "正在检测本机工具，请稍候"; return }
        let codexHome = tools?.environment["CODEX_HOME"]
        hint.stringValue = "正在读取会话历史…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let groups = AgentProvider.allCases.map { ($0, AgentHistory.sessions(for: $0, project: project, codexHome: codexHome)) }
            DispatchQueue.main.async {
                guard let self, self.project == project else { return }
                let menu = NSMenu(); menu.autoenablesItems = false
                let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .short; formatter.locale = Locale(identifier: "zh_CN")
                self.history = groups.flatMap(\.1)
                var index = 0
                for (provider, sessions) in groups {
                    if menu.numberOfItems > 0 { menu.addItem(.separator()) }
                    menu.addItem(self.menuHeader("\(provider.rawValue) · 此项目"))
                    if sessions.isEmpty {
                        let none = NSMenuItem(title: "还没有会话记录", action: nil, keyEquivalent: ""); none.isEnabled = false; menu.addItem(none)
                    }
                    for session in sessions {
                        let when = formatter.localizedString(for: session.date, relativeTo: Date())
                        // Keep the menu about as wide as the panel; the full prompt stays in the tooltip.
                        let short = session.title.count > 26 ? String(session.title.prefix(26)) + "…" : session.title
                        let item = NSMenuItem(title: short, action: #selector(self.historyPicked(_:)), keyEquivalent: ""); item.target = self; item.tag = index
                        if #available(macOS 14.4, *) { item.subtitle = when } else { item.title = short + "  ·  " + when }
                        item.toolTip = session.title; menu.addItem(item); index += 1
                    }
                }
                let count = self.history.count
                self.hint.stringValue = count == 0 ? "此项目还没有会话记录" : "共 \(count) 个最近会话 · 选择以恢复"
                menu.popUp(positioning: nil, at: NSPoint(x: self.historyButton.bounds.width - menu.size.width, y: self.historyButton.bounds.height + 6), in: self.historyButton)
            }
        }
    }
    @objc private func historyPicked(_ item: NSMenuItem) {
        guard history.indices.contains(item.tag) else { return }
        let session = history[item.tag]
        selectedProvider = session.provider; updateModelButton()
        newSession(provider: session.provider, resume: session)
    }
    private func newSession(provider: AgentProvider? = nil, resume: AgentSession? = nil) {
        // In the conversation tab, "new" and Codex history act on the native conversation.
        if active == "Agent", resume == nil || resume?.provider == .codex {
            let apply = { [weak self] in
                guard let self else { return }
                if let resume { self.chat.resume(thread: resume.id, title: resume.title) } else { self.chat.reset() }
                self.select("Agent")
            }
            if chat.running, let window {
                let alert = NSAlert(); alert.messageText = "停止当前任务并\(resume == nil ? "新建对话" : "切换会话")？"; alert.informativeText = "Codex 正在处理上一条消息，继续的话会先把它停掉。"
                alert.addButton(withTitle: "继续"); alert.addButton(withTitle: "取消")
                alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { apply() } }
            } else { apply() }
            return
        }
        let name = provider?.rawValue ?? (active == "Shell" ? "Shell" : selectedProvider.rawValue)
        let launch = { [weak self] in
            guard let self else { return }
            if let old = self.terminals.removeValue(forKey: name) { old.processDelegate = nil; old.terminate() }
            self.pendingResume = resume; self.select(name); self.pendingResume = nil
            if let resume, self.terminals[name] != nil { self.hint.stringValue = "已恢复：\(resume.title)" }
        }
        if terminals[name] != nil, let window {
            let alert = NSAlert(); alert.messageText = resume == nil ? "结束当前 \(name) 会话并新建？" : "结束当前 \(name) 会话并恢复历史会话？"
            alert.informativeText = resume == nil ? "当前任务会停止。新会话使用刚才选择的模型和思考强度。" : "当前任务会停止，然后恢复“\(resume!.title)”。"
            alert.addButton(withTitle: resume == nil ? "新建会话" : "恢复会话"); alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { launch() } }
        } else { launch() }
    }
    private func attachContext() {
        guard AgentProvider(rawValue: active) != nil, let terminal = terminals[active], let text = currentContext?() else { hint.stringValue = "先启动 Agent，再选择要附加的源码"; return }
        guard terminal.getTerminal().bracketedPasteMode else { hint.stringValue = "等待 CLI 进入输入界面后再附加上下文"; return }
        terminal.send(txt: "\u{1b}[200~" + text.replacingOccurrences(of: "\u{1b}", with: "") + "\u{1b}[201~")
        window?.makeFirstResponder(terminal); hint.stringValue = "上下文已加入输入 · 在 CLI 中确认发送"
    }
    func stopActive() {
        guard let terminal = terminals.removeValue(forKey: active) else { return }
        terminal.processDelegate = nil; terminal.terminate(); select("Agent")
        hint.stringValue = "会话已结束 · 点击标签重新启动"
    }
    func stopAll() {
        for terminal in terminals.values { terminal.processDelegate = nil; terminal.terminate() }
        terminals.removeAll(); chat.reset(); logView.string = ""; select("Agent")
    }
    func append(_ text: String) {
        let storage = logView.textStorage!
        storage.append(NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: Theme.muted]))
        if storage.length > 350_000 { storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - 300_000)) }
        logView.scrollToEndOfDocument(nil)
    }
    @objc func logClicked(_ recognizer: NSClickGestureRecognizer) {
        let position = logView.characterIndexForInsertion(at: recognizer.location(in: logView))
        let text = logView.string as NSString
        let line = text.substring(with: text.lineRange(for: NSRange(location: min(position, text.length), length: 0)))
        if let diagnostic = TeXDiagnostic.parse(line).first { onDiagnostic?(diagnostic.file, diagnostic.line) }
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let entry = self.terminals.first(where: { $0.value === source }) else { return }
            self.terminals.removeValue(forKey: entry.key); self.updateComposerMode()
            if self.active == entry.key { self.hint.stringValue = "\(entry.key) 已退出（\(exitCode ?? -1)）· 点击标签重启" }
        }
    }
}
