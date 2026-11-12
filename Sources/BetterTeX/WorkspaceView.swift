import AppKit
import BetterTeXCore

/// The custom title bar. Its empty area drags the window like a native title bar.
final class HeaderBar: Surface {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
    }
}

/// The BetterTeX mark: an accent tile carrying a "T" and a dropped block.
final class LogoMark: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // The mark is drawn on a 24-point grid and scaled to whatever size it is shown at.
        let scale = NSAffineTransform(); scale.scale(by: bounds.width / 24); scale.concat()
        Theme.accent.setFill(); NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 24, height: 24), xRadius: 6.5, yRadius: 6.5).fill()
        NSColor.white.setStroke(); NSColor.white.setFill()
        let stroke = NSBezierPath(); stroke.lineWidth = 2.4; stroke.lineCapStyle = .round
        stroke.move(to: NSPoint(x: 6, y: 7.5)); stroke.line(to: NSPoint(x: 15, y: 7.5))
        stroke.move(to: NSPoint(x: 10.5, y: 7.5)); stroke.line(to: NSPoint(x: 10.5, y: 17)); stroke.stroke()
        NSBezierPath(roundedRect: NSRect(x: 14, y: 13.5, width: 4.5, height: 5), xRadius: 1.2, yRadius: 1.2).fill()
    }
}

struct SearchResult {
    let title: String
    let detail: String
    let ext: String?
    let action: () -> Void
}

/// The title bar's search field with a results popover (files and headings).
final class SearchField: Chip, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let input = NSTextField()
    var results: ((String) -> [SearchResult])?
    private var items: [SearchResult] = []
    private let popover = NSPopover()
    private let table = NSTableView()
    private let hintChip = Chip(fill: Theme.fill, radius: 6)
    init() {
        super.init(fill: Theme.fill, radius: 10)
        let icon = NSImageView(image: Theme.symbol("magnifyingglass", size: 13, weight: .semibold)!); icon.contentTintColor = Theme.muted
        input.isBordered = false; input.drawsBackground = false; input.focusRingType = .none; input.font = .systemFont(ofSize: 13.5)
        input.textColor = Theme.text; input.placeholderString = L10n.tr("搜索文件或章节"); input.delegate = self
        input.cell?.usesSingleLineMode = true; input.cell?.isScrollable = true; input.setAccessibilityLabel(L10n.tr("搜索文件或章节"))
        input.setContentHuggingPriority(.init(1), for: .horizontal); input.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let hint = Theme.label("⌘K", size: 11.5, color: Theme.muted); hintChip.size(nil, 20); hintChip.pinRow(hint, leading: 6, trailing: 6)
        let row = NSStackView(views: [icon, input, hintChip]); row.spacing = 8; row.alignment = .centerY
        size(nil, 34); pinRow(row, leading: 10, trailing: 8)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 36; table.intercellSpacing = NSSize(width: 0, height: 2); table.style = .inset
        table.backgroundColor = .clear; table.dataSource = self; table.delegate = self; table.refusesFirstResponder = true
        table.target = self; table.action = #selector(rowClicked)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let controller = NSViewController(); controller.view = scroll
        popover.contentViewController = controller; popover.behavior = .semitransient; popover.animates = false
    }
    required init?(coder: NSCoder) { fatalError() }
    func focus() { window?.makeFirstResponder(input) }
    override func mouseDown(with event: NSEvent) { focus() }
    private func refresh() {
        items = results?(input.stringValue.trimmingCharacters(in: .whitespaces)) ?? []
        table.reloadData()
        guard !items.isEmpty, window != nil else { popover.close(); return }
        table.selectRowIndexes([0], byExtendingSelection: false)
        popover.contentSize = NSSize(width: max(320, bounds.width), height: CGFloat(min(items.count, 8)) * 38 + 20)
        if !popover.isShown { popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY) }
    }
    private func choose() {
        guard items.indices.contains(table.selectedRow) else { return }
        let item = items[table.selectedRow]; dismiss(); item.action()
    }
    private func dismiss() { popover.close(); input.stringValue = ""; hintChip.isHidden = false }
    @objc private func rowClicked() { choose() }
    func controlTextDidBeginEditing(_ obj: Notification) { hintChip.isHidden = true; refresh() }
    func controlTextDidChange(_ obj: Notification) { hintChip.isHidden = true; refresh() }
    func controlTextDidEndEditing(_ obj: Notification) { popover.close(); hintChip.isHidden = !input.stringValue.isEmpty }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !items.isEmpty else { refresh(); return true }
            let row = max(0, min(items.count - 1, table.selectedRow + (selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1)))
            table.selectRowIndexes([row], byExtendingSelection: false); table.scrollRowToVisible(row); return true
        case #selector(NSResponder.insertNewline(_:)): choose(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); window?.makeFirstResponder(nil); return true
        default: return false
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let badge: NSView
        if let ext = item.ext { let tile = FileBadge(); tile.ext = ext; badge = tile }
        else { let image = NSImageView(image: Theme.symbol("number", size: 13)!); image.contentTintColor = Theme.muted; image.size(20, 20); badge = image }
        let detail = Theme.label(item.detail, size: 12, color: Theme.muted); detail.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        let title = Theme.label(item.title, size: 13); title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let row = NSStackView(views: [badge, title, detail, NSView()]); row.spacing = 9; row.alignment = .centerY
        let cell = NSView(); cell.pinRow(row, leading: 4, trailing: 4); return cell
    }
}

private final class StatusDot: NSView {
    var color: NSColor = Theme.green { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.18).setFill(); NSBezierPath(ovalIn: bounds).fill()
        color.setFill(); NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).fill()
    }
}

/// A slim bar in the status bar for long transfers: indeterminate while preparing or waiting, filling while bytes move.
final class TransferBar: NSProgressIndicator {
    enum State: Equatable { case hidden, waiting, fraction(Double) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        style = .bar; controlSize = .small; minValue = 0; maxValue = 1; isDisplayedWhenStopped = false
        translatesAutoresizingMaskIntoConstraints = false; widthAnchor.constraint(equalToConstant: 120).isActive = true
        isHidden = true; alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    var state: State = .hidden {
        didSet {
            guard state != oldValue else { return }
            switch state {
            case .hidden:
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; animator().alphaValue = 0 }) { [weak self] in
                    guard let self, self.state == .hidden else { return }
                    self.stopAnimation(nil); self.isHidden = true
                }
            case .waiting:
                isIndeterminate = true; startAnimation(nil); reveal()
            case .fraction(let value):
                if isIndeterminate { stopAnimation(nil); isIndeterminate = false }
                doubleValue = min(max(value, 0), 1); reveal()
            }
        }
    }
    private func reveal() {
        guard isHidden || alphaValue < 1 else { return }
        isHidden = false; NSAnimationContext.runAnimationGroup { $0.duration = 0.2; animator().alphaValue = 1 }
    }
}

/// The whole window content: title bar, sidebar, editor / PDF / agent panes and status bar.
final class WorkspaceView: Surface {
    enum Activity { case idle, busy, failed }
    static let headerHeight: CGFloat = 54
    let explorer = ExplorerPane()
    let editor = EditorPane()
    let preview = PDFPane()
    let terminal = TerminalPanel()
    let search = SearchField()
    let overleaf = OverleafChip()
    let welcome = WelcomeView()
    let status = Theme.label(L10n.tr("正在检测本机工具…"), size: 11.5, color: Theme.soft)
    let branch = Theme.label("", size: 11.5, color: Theme.muted)
    let transfer = TransferBar()
    let position = Theme.label("Ln 1, Col 1", size: 11.5, color: Theme.muted)
    private let projectLabel = Theme.label("BetterTeX", size: 13.5, weight: .semibold)
    private let fileLabel = Theme.label("", size: 13.5, color: Theme.muted, weight: .medium)
    private let slash = Theme.label("/", size: 13.5, color: Theme.muted)
    private let errorLabel = Theme.label("", size: 11.5, color: Theme.muted)
    private let warningLabel = Theme.label("", size: 11.5, color: Theme.muted)
    private var toolButton: ActionButton!
    private let syncLabel = Theme.label("SyncTeX", size: 11.5, color: Theme.muted)
    private let syncIcon = NSImageView()
    private let statusDot = StatusDot()
    private var engineButton: ActionButton!
    private var buildButton: ActionButton!
    private var layoutButton: ActionButton!
    private var pullButton: ActionButton!
    private var pushButton: ActionButton!
    private let gitLabel = Theme.label("GitHub", size: 12.5, color: Theme.soft, weight: .medium)
    private var headerLeading: NSLayoutConstraint!
    let mainSplit = PaneSplitController()
    let bodySplit = PaneSplitController()
    let documentSplit = PaneSplitController()
    var terminalItem: PaneItem!
    var explorerItem: PaneItem!
    var pdfItem: PaneItem!
    private var editorItem: PaneItem!
    private var docItem: PaneItem!
    private var agentDock = DockPosition(rawValue: UserDefaults.standard.string(forKey: "layout.agentDock") ?? "") ?? .right
    private var pdfDock = DockPosition(rawValue: UserDefaults.standard.string(forKey: "layout.pdfDock") ?? "") ?? .right
    private let dockOverlay = DockOverlay()
    private var agentFolded = UserDefaults.standard.bool(forKey: "layout.agentFolded")
    private let engines = ["Auto", "latexmk", "pdfLaTeX", "XeLaTeX", "LuaLaTeX"]
    private(set) var selectedEngine = "Auto"
    var autoBuildEnabled: Bool {
        get { preview.autoSwitch.state == .on }
        set { preview.autoSwitch.state = newValue ? .on : .off }
    }
    var activity: Activity = .idle {
        didSet {
            statusDot.color = activity == .busy ? Theme.orange : activity == .failed ? Theme.red : Theme.green
            preview.state = activity == .busy ? .building : activity == .failed ? .failed : (preview.pdfView.document == nil ? .none : .synced)
        }
    }
    var projectURL: URL?
    var onBuild: (() -> Void)?
    var onPush: (() -> Void)?
    var onPull: (() -> Void)?
    var onAuto: ((Bool) -> Void)?
    var onOpenFile: ((URL) -> Void)?
    var onHome: (() -> Void)?
    var onOverleaf: ((NSView) -> Void)?
    var onShowTools: (() -> Void)?
    var onDetectTools: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame); fill = Theme.base

        // Title bar
        let top = HeaderBar(); top.fill = Theme.header; top.lineColor = Theme.line; top.bottomLine = true
        let sidebarToggle = ActionButton("", symbol: "sidebar.left") { [weak self] in self?.toggleSidebar() }; sidebarToggle.toolTip = L10n.tr("显示 / 隐藏边栏  ⌃⌘S")
        let mark = LogoMark(); mark.size(24, 24)
        let wordmark = NSTextField(labelWithAttributedString: Self.wordmark()); wordmark.setAccessibilityLabel("BetterTeX")
        for label in [projectLabel, fileLabel] { label.lineBreakMode = .byTruncatingTail; label.setContentCompressionResistancePriority(.init(300), for: .horizontal) }
        wordmark.setContentCompressionResistancePriority(.required, for: .horizontal)
        let home = ActionButton("", symbol: "square.grid.2x2") { [weak self] in self?.onHome?() }; home.toolTip = L10n.tr("所有项目  ⇧⌘P")
        let identity = NSStackView(views: [sidebarToggle, home, mark, wordmark, Theme.divider(height: 16), projectLabel, slash, fileLabel]); identity.spacing = 8; identity.alignment = .centerY
        identity.setCustomSpacing(2, after: sidebarToggle)
        identity.setCustomSpacing(10, after: sidebarToggle); identity.setCustomSpacing(10, after: wordmark)
        engineButton = ActionButton(selectedEngine, symbol: "chevron.up.chevron.down", style: .chip) { [weak self] in self?.showEngineMenu() }
        engineButton.toolTip = L10n.tr("编译引擎；Auto 读取 TeX 指令并优先使用 latexmk")
        buildButton = ActionButton(L10n.tr("编译"), symbol: "play.fill", style: .pill) { [weak self] in self?.onBuild?() }; buildButton.toolTip = L10n.tr("编译 / 停止  ⌘↩")
        pullButton = ActionButton("", symbol: "arrow.down") { [weak self] in self?.onPull?() }
        pushButton = ActionButton("", symbol: "arrow.up") { [weak self] in self?.onPush?() }
        let gitIcon = NSImageView(image: Theme.symbol("arrow.triangle.branch", size: 11, weight: .semibold)!); gitIcon.contentTintColor = Theme.muted
        gitLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let gitRow = NSStackView(views: [gitIcon, gitLabel, Theme.divider(height: 16), pullButton, Theme.divider(height: 16), pushButton]); gitRow.spacing = 0; gitRow.alignment = .centerY
        gitRow.setCustomSpacing(5, after: gitIcon); gitRow.setCustomSpacing(9, after: gitLabel)
        let git = Chip(fill: Theme.fill, radius: 8); git.size(nil, 32); git.pinRow(gitRow, leading: 10, trailing: 1)
        git.setAccessibilityElement(true); git.setAccessibilityRole(.group); git.setAccessibilityLabel(L10n.tr("GitHub 同步"))
        setGitHost("GitHub")
        let agent = ActionButton("", symbol: "terminal") { [weak self] in self?.toggleTerminal() }; agent.toolTip = L10n.tr("显示 / 隐藏 Agent 面板  ⌘J")
        layoutButton = ActionButton("", symbol: "rectangle.split.3x1") { [weak self] in self?.showLayoutMenu() }; layoutButton.toolTip = L10n.tr("面板与布局")
        overleaf.onClick = { [weak self] in if let self { self.onOverleaf?(self.overleaf) } }
        let actions = NSStackView(views: [engineButton, buildButton, Theme.divider(height: 20), git, overleaf, agent, layoutButton]); actions.spacing = 8; actions.alignment = .centerY
        actions.setCustomSpacing(12, after: buildButton); actions.setCustomSpacing(4, after: agent)
        for view in [identity, search, actions] { view.translatesAutoresizingMaskIntoConstraints = false; top.addSubview(view) }
        headerLeading = identity.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 84)
        let centered = search.centerXAnchor.constraint(equalTo: top.centerXAnchor); centered.priority = .init(240)
        let wide = search.widthAnchor.constraint(equalToConstant: 420); wide.priority = .init(250)
        NSLayoutConstraint.activate([
            headerLeading, identity.centerYAnchor.constraint(equalTo: top.centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -14), actions.centerYAnchor.constraint(equalTo: top.centerYAnchor),
            search.centerYAnchor.constraint(equalTo: top.centerYAnchor), centered, wide, search.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            search.leadingAnchor.constraint(greaterThanOrEqualTo: identity.trailingAnchor, constant: 16), search.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -16)
        ])
        search.results = { [weak self] in self?.searchResults($0) ?? [] }

        // Panes
        mainSplit.splitView.isVertical = true; bodySplit.splitView.isVertical = true; documentSplit.splitView.isVertical = true
        mainSplit.sizing = .fixedFirst; mainSplit.persistenceKey = "layout.sidebarSizes"; bodySplit.sizing = .fixedLast
        func item(_ view: NSView, min: CGFloat) -> PaneItem { let vc = NSViewController(); vc.view = view; let item = PaneItem(viewController: vc); item.minimumThickness = min; return item }
        explorerItem = item(explorer, min: 200); explorerItem.maximumThickness = 340; explorerItem.canCollapse = true
        mainSplit.addSplitViewItem(explorerItem)
        let bodyItem = PaneItem(viewController: bodySplit); bodyItem.minimumThickness = 900; mainSplit.addSplitViewItem(bodyItem)
        docItem = PaneItem(viewController: documentSplit)
        terminalItem = item(terminal, min: 380); terminalItem.canCollapse = true
        editorItem = item(editor, min: 250); pdfItem = item(preview, min: 340); pdfItem.canCollapse = true
        applyDocking()

        // Status bar
        toolButton = ActionButton(L10n.tr("本机工具"), symbol: "chevron.up.chevron.down", style: .plain) { [weak self] in self?.showToolsMenu() }
        toolButton.toolTip = L10n.tr("查看或重新检测本机工具")
        let bottom = Surface(); bottom.fill = Theme.sidebar; bottom.lineColor = Theme.line; bottom.topLine = true
        statusDot.size(13, 13); syncIcon.image = Theme.symbol("checkmark", size: 9, weight: .bold); syncIcon.contentTintColor = Theme.green
        let sync = NSStackView(views: [syncLabel, syncIcon]); sync.spacing = 4
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottomRow = NSStackView(views: [statusDot, status, transfer, errorLabel, warningLabel, spacer, branch, toolButton, sync, position, Theme.label("UTF-8", size: 11.5, color: Theme.muted), Theme.label("LaTeX", size: 11.5, color: Theme.muted)])
        bottomRow.spacing = 16; bottomRow.setCustomSpacing(6, after: statusDot); bottomRow.setCustomSpacing(10, after: status); bottomRow.alignment = .centerY; bottom.pinRow(bottomRow, leading: 12, trailing: 14)
        position.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); status.lineBreakMode = .byTruncatingTail
        for label in [errorLabel, warningLabel, branch] { label.isHidden = true }
        sync.isHidden = true; syncLabel.superview?.isHidden = true
        activity = .idle

        for view in [top, mainSplit.view, bottom] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor), top.leadingAnchor.constraint(equalTo: leadingAnchor), top.trailingAnchor.constraint(equalTo: trailingAnchor), top.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor), bottom.leadingAnchor.constraint(equalTo: leadingAnchor), bottom.trailingAnchor.constraint(equalTo: trailingAnchor), bottom.heightAnchor.constraint(equalToConstant: 28),
            mainSplit.view.leadingAnchor.constraint(equalTo: leadingAnchor), mainSplit.view.trailingAnchor.constraint(equalTo: trailingAnchor), mainSplit.view.topAnchor.constraint(equalTo: top.bottomAnchor), mainSplit.view.bottomAnchor.constraint(equalTo: bottom.topAnchor)
        ])
        terminal.header.onHide = { [weak self] in self?.terminalItem.isCollapsed = true }
        terminal.onFold = { [weak self] in self?.setAgentFolded($0) }
        preview.header.onHide = { [weak self] in self?.pdfItem.isCollapsed = true }
        terminal.header.onMove = { [weak self] in self?.movePanel("agent", to: $0) }
        preview.header.onMove = { [weak self] in self?.movePanel("pdf", to: $0) }
        preview.onAuto = { [weak self] in self?.onAuto?($0) }
        explorer.onSearch = { [weak self] in self?.search.focus() }
        for header in [terminal.header, preview.header] {
            let id = header.panelID
            header.onDrag = { [weak self] point in self?.showDropTarget(id, at: point) }
            header.onDrop = { [weak self] point in
                guard let self else { return }; self.dockOverlay.isHidden = true
                if let (position, _) = self.dropTarget(id, at: point) { self.movePanel(id, to: position) }
            }
        }
        welcome.isHidden = true; welcome.translatesAutoresizingMaskIntoConstraints = false; addSubview(welcome)
        NSLayoutConstraint.activate([welcome.topAnchor.constraint(equalTo: top.bottomAnchor), welcome.bottomAnchor.constraint(equalTo: bottom.topAnchor), welcome.leadingAnchor.constraint(equalTo: leadingAnchor), welcome.trailingAnchor.constraint(equalTo: trailingAnchor)])
        dockOverlay.frame = bounds; dockOverlay.autoresizingMask = [.width, .height]; dockOverlay.isHidden = true; addSubview(dockOverlay)
    }
    required init?(coder: NSCoder) { fatalError() }
    private static func wordmark() -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 14.5, weight: .bold)
        let text = NSMutableAttributedString(string: "Better", attributes: [.font: font, .foregroundColor: Theme.text, .kern: -0.3])
        // The lowered "E" echoes the TeX logotype.
        for (letter, drop) in [("T", 0.0), ("E", -3.2), ("X", 0.0)] {
            text.append(NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: Theme.accent, .baselineOffset: drop, .kern: -0.9]))
        }
        return text
    }
    func initialLayout() {
        layoutSubtreeIfNeeded()
        mainSplit.resetPreferredSizes(first: 236); resetPaneSizes()
        documentSplit.view.layoutSubtreeIfNeeded()
        preview.pdfView.autoScales = true
    }
    /// In full screen the traffic lights disappear, so the title bar content moves to the edge.
    func setFullScreen(_ fullScreen: Bool) { headerLeading.constant = fullScreen ? 14 : 84 }
    func setTitle(project: String, file: String?) {
        projectLabel.stringValue = project; fileLabel.stringValue = file ?? ""
        fileLabel.isHidden = file == nil; slash.isHidden = file == nil
    }
    private func showToolsMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(L10n.tr("本机工具…"), symbol: "wrench.and.screwdriver") { [weak self] in self?.onShowTools?() })
        menu.addItem(ClosureMenuItem(L10n.tr("重新检测工具"), symbol: "arrow.clockwise") { [weak self] in self?.onDetectTools?() })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: toolButton.bounds.height + 4), in: toolButton)
    }
    func setTools(engines: Int, syncTeX: Bool) {
        toolButton.setTitle(engines == 0 ? L10n.tr("TeX 未安装") : L10n.tr("\(engines) 个引擎"))
        syncLabel.superview?.isHidden = !syncTeX
    }
    func setDiagnostics(errors: Int, warnings: Int) {
        errorLabel.stringValue = L10n.tr("\(errors) 错误"); warningLabel.stringValue = L10n.tr("\(warnings) 警告")
        errorLabel.textColor = errors > 0 ? Theme.red : Theme.muted; warningLabel.textColor = warnings > 0 ? Theme.orange : Theme.muted
        errorLabel.isHidden = false; warningLabel.isHidden = false
    }
    /// Names the service behind the pull / push pair ("GitHub", or "Git" for other remotes).
    func setGitHost(_ name: String) {
        gitLabel.stringValue = name
        pullButton.toolTip = L10n.tr("从 \(name) 拉取 · git pull --ff-only"); pushButton.toolTip = L10n.tr("提交并推送到 \(name)")
    }
    func setBranch(_ text: String) { branch.stringValue = text; branch.isHidden = text.isEmpty }
    func toggleSidebar() { explorerItem.isCollapsed.toggle() }
    /// ⌘J folds the Agent panel to a rail and back; a fully hidden panel comes back unfolded.
    func toggleTerminal() {
        if terminalItem.isCollapsed { terminalItem.isCollapsed = false; setAgentFolded(false) } else { setAgentFolded(!agentFolded) }
    }
    func setAgentFolded(_ folded: Bool) {
        agentFolded = folded; UserDefaults.standard.set(folded, forKey: "layout.agentFolded")
        applyAgentFold(); bodySplit.resizePanes(); layoutSubtreeIfNeeded()
    }
    private func applyAgentFold() {
        bodySplit.freezeSizes = agentFolded
        terminalItem.minimumThickness = agentFolded ? TerminalPanel.railThickness : (agentDock == .bottom ? 240 : 380)
        terminalItem.maximumThickness = agentFolded ? TerminalPanel.railThickness : (agentDock == .bottom ? 520 : 1000)
        terminal.setFolded(agentFolded, horizontal: agentDock == .bottom)
    }
    func togglePDF() { pdfItem.isCollapsed.toggle() }
    func showOutput() { terminalItem.isCollapsed = false; if agentFolded { setAgentFolded(false) }; terminal.select("Output") }
    func showAgent() { terminalItem.isCollapsed = false; if agentFolded { setAgentFolded(false) } }
    private var buildingIndicator: DispatchWorkItem?
    func setBuilding(_ building: Bool) {
        buildingIndicator?.cancel(); buildingIndicator = nil
        func apply(_ busy: Bool) {
            buildButton.image = Theme.symbol(busy ? "stop.fill" : "play.fill", size: 10, weight: .bold)
            buildButton.setTitle(busy ? L10n.tr("停止") : L10n.tr("编译"))
            if busy { activity = .busy } else { preview.stage = nil; if activity == .busy { activity = .idle } }
        }
        guard building else { apply(false); return }
        // Builds that finish almost at once (nothing to do) never show the busy state, so the UI does not flash.
        let job = DispatchWorkItem { apply(true) }; buildingIndicator = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: job)
    }
    /// Names the program currently running inside a build.
    func setBuildStage(_ stage: BuildStage) { preview.stage = L10n.tr("第 \(stage.step) 步 · \(stage.title)") }

    // MARK: Search
    private func searchResults(_ query: String) -> [SearchResult] {
        guard let projectURL else { return [] }
        let needle = query.lowercased()
        var results: [SearchResult] = []
        if !needle.isEmpty {
            for item in explorer.outlineItemsForSearch where item.title.lowercased().contains(needle) {
                let line = item.line
                results.append(SearchResult(title: item.title, detail: L10n.tr("第 \(line) 行"), ext: nil) { [weak self] in self?.explorer.onJump?(line) })
            }
        }
        let excluded: Set<String> = [".bettertex", "node_modules", "dist", "build", "__pycache__"]
        var files: [(URL, String)] = []
        if let iterator = FileManager.default.enumerator(at: projectURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            var visited = 0
            while let url = iterator.nextObject() as? URL {
                visited += 1; if visited > 5000 { break }
                if excluded.contains(url.lastPathComponent) { iterator.skipDescendants(); continue }
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
                let relative = url.path.replacingOccurrences(of: projectURL.path + "/", with: "")
                if needle.isEmpty || relative.lowercased().contains(needle) { files.append((url, relative)) }
            }
        }
        files.sort { a, b in
            let pa = a.0.lastPathComponent.lowercased().hasPrefix(needle), pb = b.0.lastPathComponent.lowercased().hasPrefix(needle)
            return pa != pb ? pa : a.1.localizedStandardCompare(b.1) == .orderedAscending
        }
        for (url, relative) in files.prefix(20) {
            let folder = (relative as NSString).deletingLastPathComponent
            results.append(SearchResult(title: url.lastPathComponent, detail: folder, ext: url.pathExtension.lowercased()) { [weak self] in self?.onOpenFile?(url) })
        }
        return results
    }

    // MARK: Menus
    private func showEngineMenu() {
        let menu = NSMenu()
        for name in engines {
            let item = NSMenuItem(title: name, action: #selector(engineSelected(_:)), keyEquivalent: ""); item.target = self
            item.state = name == selectedEngine ? .on : .off; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: engineButton.bounds.height + 6), in: engineButton)
    }
    @objc private func engineSelected(_ item: NSMenuItem) { selectedEngine = item.title; engineButton.setTitle(selectedEngine) }
    private func showLayoutMenu() {
        let menu = NSMenu()
        for (title, hidden, selector) in [(L10n.tr("边栏"), explorerItem.isCollapsed, #selector(menuToggleSidebar)), (L10n.tr("PDF 预览"), pdfItem.isCollapsed, #selector(menuTogglePDF)), (L10n.tr("Agent 面板"), terminalItem.isCollapsed, #selector(menuToggleTerminal))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; item.state = hidden ? .off : .on; menu.addItem(item)
        }
        menu.addItem(.separator())
        for (id, title) in [("pdf", L10n.tr("PDF 预览位置")), ("agent", L10n.tr("Agent 面板位置"))] {
            let group = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let submenu = NSMenu()
            for position in DockPosition.allCases {
                let item = NSMenuItem(title: position.title, action: #selector(layoutSelected(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = [id, position.rawValue]; submenu.addItem(item)
                item.image = NSImage(systemSymbolName: position.symbol, accessibilityDescription: nil)
                item.state = (id == "agent" ? agentDock : pdfDock) == position ? .on : .off
            }
            group.submenu = submenu; menu.addItem(group)
        }
        menu.addItem(.separator()); let reset = NSMenuItem(title: L10n.tr("恢复默认布局"), action: #selector(resetLayout), keyEquivalent: ""); reset.target = self; menu.addItem(reset)
        menu.popUp(positioning: nil, at: NSPoint(x: layoutButton.bounds.width - 180, y: layoutButton.bounds.height + 6), in: layoutButton)
    }
    @objc private func menuToggleSidebar() { toggleSidebar() }
    @objc private func menuTogglePDF() { togglePDF() }
    @objc private func menuToggleTerminal() { toggleTerminal() }

    // MARK: Docking
    private func applyDocking() {
        documentSplit.splitView.isVertical = pdfDock != .bottom
        editorItem.minimumThickness = pdfDock == .bottom ? 160 : 250
        pdfItem.minimumThickness = pdfDock == .bottom ? 180 : 340
        documentSplit.persistenceKey = "layout.pdfSizes.\(pdfDock.rawValue)"
        documentSplit.replaceItems(pdfDock == .left ? [pdfItem, editorItem] : [editorItem, pdfItem])
        bodySplit.splitView.isVertical = agentDock != .bottom
        bodySplit.sizing = agentDock == .left ? .fixedFirst : .fixedLast
        bodySplit.persistenceKey = "layout.agentSizes.\(agentDock.rawValue)"
        docItem.minimumThickness = agentDock == .bottom ? 220 : (pdfDock == .bottom ? 340 : 600)
        applyAgentFold()
        bodySplit.replaceItems(agentDock == .left ? [terminalItem, docItem] : [docItem, terminalItem])
        terminal.header.position = agentDock; preview.header.position = pdfDock
        resetPaneSizes()
    }
    private func resetPaneSizes() {
        bodySplit.resetPreferredSizes(first: 344, last: agentDock == .bottom ? 300 : 400)
        documentSplit.resetPreferredSizes(ratio: 0.5)
    }
    func movePanel(_ panel: String, to position: DockPosition) {
        if panel == "agent" { agentDock = position; terminalItem.isCollapsed = false }
        else { pdfDock = position; pdfItem.isCollapsed = false }
        UserDefaults.standard.set(agentDock.rawValue, forKey: "layout.agentDock")
        UserDefaults.standard.set(pdfDock.rawValue, forKey: "layout.pdfDock")
        applyDocking(); layoutSubtreeIfNeeded()
    }
    @objc private func layoutSelected(_ item: NSMenuItem) {
        if let pair = item.representedObject as? [String], let position = DockPosition(rawValue: pair[1]) { movePanel(pair[0], to: position) }
    }
    @objc func resetLayout() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("layout.") { UserDefaults.standard.removeObject(forKey: key) }
        agentDock = .right; pdfDock = .right; agentFolded = false; explorerItem.isCollapsed = false; terminalItem.isCollapsed = false; pdfItem.isCollapsed = false
        applyDocking(); mainSplit.resetPreferredSizes(first: 236)
    }
    private func dropTarget(_ panel: String, at windowPoint: NSPoint) -> (DockPosition, NSRect)? {
        let target = panel == "agent" ? bodySplit.view : documentSplit.view
        let rect = convert(target.bounds, from: target); let point = convert(windowPoint, from: nil)
        guard rect.contains(point) else { return nil }
        if point.y > rect.maxY - rect.height * 0.25 { return (.bottom, NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)) }
        let left = point.x < rect.midX
        return (left ? .left : .right, NSRect(x: left ? rect.minX : rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height))
    }
    private func showDropTarget(_ panel: String, at point: NSPoint) {
        guard let (position, rect) = dropTarget(panel, at: point) else { dockOverlay.isHidden = true; return }
        dockOverlay.zone = rect; dockOverlay.title = (panel == "agent" ? "Agent · " : "PDF · ") + position.title
        dockOverlay.isHidden = false
    }
}
