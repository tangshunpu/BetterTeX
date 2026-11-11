import AppKit
import BetterTeXCore

final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    var cachedChildren: [FileNode]?
    init(_ url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
    }
    var children: [FileNode] {
        if let cachedChildren { return cachedChildren }
        guard isDirectory else { return [] }
        let ignored: Set<String> = ["node_modules", "dist", "build", "__pycache__"]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        let items = urls.filter { !ignored.contains($0.lastPathComponent) }.map(FileNode.init).sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        cachedChildren = items; return items
    }
}

/// One heading of the active document, shown in the sidebar's outline card.
struct OutlineItem {
    let title: String
    let number: String
    let level: Int
    let line: Int
    /// Scans LaTeX source for the title, abstract and sectioning commands.
    static func parse(_ text: String) -> [OutlineItem] {
        guard let regex = try? NSRegularExpression(pattern: "\\\\(title|section|subsection|subsubsection)(\\*?)\\s*(?:\\[[^\\]]*\\])?\\s*\\{([^}]*)\\}|\\\\begin\\{(abstract)\\}") else { return [] }
        var items: [OutlineItem] = []; var counters = [0, 0, 0]
        var lineNumber = 0
        text.enumerateLines { line, _ in
            lineNumber += 1
            let ns = line as NSString
            // Ignore anything after an unescaped comment marker.
            var limit = ns.length
            if let comment = line.range(of: "(?<!\\\\)%", options: .regularExpression) { limit = NSRange(comment, in: line).location }
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: limit)) else { return }
            if match.range(at: 4).location != NSNotFound { items.append(OutlineItem(title: "Abstract", number: "", level: 0, line: lineNumber)); return }
            let kind = ns.substring(with: match.range(at: 1)); let starred = match.range(at: 2).length > 0
            let title = ns.substring(with: match.range(at: 3)).replacingOccurrences(of: "\\\\[a-zA-Z]+\\s*|[{}]", with: "", options: .regularExpression)
            if kind == "title" { items.append(OutlineItem(title: L10n.tr("标题"), number: "", level: 0, line: lineNumber)); return }
            let level = kind == "section" ? 0 : kind == "subsection" ? 1 : 2
            var number = ""
            if !starred {
                counters[level] += 1; for deeper in (level + 1)..<3 where deeper < 3 { counters[deeper] = 0 }
                number = counters[0...level].map(String.init).joined(separator: ".")
            }
            items.append(OutlineItem(title: title.trimmingCharacters(in: .whitespaces), number: number, level: level, line: lineNumber))
        }
        return items
    }
}

private final class FileRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.accent.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    override var isEmphasized: Bool { get { true } set {} }
}

private final class FileCell: NSTableCellView {
    let badge = FileBadge()
    let folder = NSImageView()
    let label = Theme.label("", size: 13)
    let dot = Chip(fill: Theme.muted, radius: -1)
    override init(frame: NSRect) {
        super.init(frame: frame)
        let row = NSStackView(views: [folder, badge, label, dot]); row.spacing = 9; row.alignment = .centerY
        folder.size(20, 20); dot.size(7, 7); label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), row.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            label.textColor = selected ? .white : Theme.text; label.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
            badge.onAccent = selected; dot.fill = selected ? NSColor.white.withAlphaComponent(0.8) : Theme.muted
            folder.contentTintColor = selected ? .white : Theme.accent
        }
    }
}

/// The sidebar: project files above an outline of the active document.
final class ExplorerPane: Surface, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let outline = NSOutlineView()
    private let outlineStack = NSStackView()
    private let outlineCard = Chip(fill: Theme.fillSoft, radius: 10)
    private let outlineTitle = Theme.label(L10n.tr("大纲"), size: 12, color: Theme.muted, weight: .semibold)
    private var outlineHeight: NSLayoutConstraint!
    private var outlineItems: [OutlineItem] = []
    private var currentOutline = -1
    var root: FileNode?
    var dirty = Set<URL>() { didSet { if dirty != oldValue { refreshCells() } } }
    var onOpen: ((URL) -> Void)?
    var onNew: (() -> Void)?
    var onSearch: (() -> Void)?
    var onCloseProject: (() -> Void)?
    var onJump: ((Int) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame); fill = Theme.sidebar; lineColor = Theme.line; trailingLine = true
        let search = ActionButton("", symbol: "magnifyingglass") { [weak self] in self?.onSearch?() }; search.toolTip = L10n.tr("搜索文件  ⌘K")
        let plus = ActionButton("", symbol: "plus", style: .accentIcon) { [weak self] in self?.onNew?() }; plus.toolTip = L10n.tr("新建文件  ⌘N")
        let close = ActionButton("", symbol: "rectangle.portrait.and.arrow.right") { [weak self] in self?.onCloseProject?() }; close.toolTip = L10n.tr("关闭项目，回到起始页"); close.setAccessibilityLabel(L10n.tr("关闭项目"))
        let header = NSStackView(views: [Theme.label(L10n.tr("文件"), size: 12, color: Theme.muted, weight: .semibold), NSView(), search, plus, close]); header.spacing = 2; header.alignment = .centerY
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("files")); outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.headerView = nil; outline.rowHeight = 32; outline.indentationPerLevel = 16; outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.style = .plain; outline.backgroundColor = .clear; outline.focusRingType = .none
        outline.dataSource = self; outline.delegate = self; outline.target = self; outline.action = #selector(selected)
        let menu = NSMenu(); menu.delegate = self; outline.menu = menu
        scroll.documentView = outline

        let outlineScroll = NSScrollView(); outlineScroll.drawsBackground = false; outlineScroll.hasVerticalScroller = true; outlineScroll.autohidesScrollers = true
        let flipped = FlippedView(); outlineStack.orientation = .vertical; outlineStack.spacing = 0; outlineStack.alignment = .leading
        outlineStack.translatesAutoresizingMaskIntoConstraints = false; flipped.addSubview(outlineStack)
        flipped.translatesAutoresizingMaskIntoConstraints = false; outlineScroll.documentView = flipped
        NSLayoutConstraint.activate([
            outlineStack.topAnchor.constraint(equalTo: flipped.topAnchor), outlineStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor), outlineStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor), outlineStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            flipped.leadingAnchor.constraint(equalTo: outlineScroll.contentView.leadingAnchor), flipped.trailingAnchor.constraint(equalTo: outlineScroll.contentView.trailingAnchor), flipped.topAnchor.constraint(equalTo: outlineScroll.contentView.topAnchor)
        ])
        outlineCard.layer?.masksToBounds = true; outlineCard.pin(outlineScroll)
        outlineHeight = outlineCard.heightAnchor.constraint(equalToConstant: 0)

        for view in [header, scroll, outlineTitle, outlineCard] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 10), header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), header.heightAnchor.constraint(equalToConstant: 30),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4), scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            outlineTitle.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12), outlineTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            outlineCard.topAnchor.constraint(equalTo: outlineTitle.bottomAnchor, constant: 6), outlineCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), outlineCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            outlineCard.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12), outlineHeight
        ])
        setOutline([], cursorLine: 1)
    }
    required init?(coder: NSCoder) { fatalError() }
    func load(_ url: URL) { root = FileNode(url); outline.reloadData() }
    /// Empties the tree when no project is open.
    func unload() { root = nil; outline.reloadData(); setOutline([], cursorLine: 1) }
    func refresh() {
        guard let root else { return }
        let expanded = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? FileNode }.filter { outline.isItemExpanded($0) }.map { $0.url.path }
        let selected = (outline.item(atRow: outline.selectedRow) as? FileNode)?.url
        root.cachedChildren = nil; outline.reloadData()
        var row = 0
        while row < outline.numberOfRows { if let node = outline.item(atRow: row) as? FileNode, expanded.contains(node.url.path) { outline.expandItem(node) }; row += 1 }
        if let selected { reveal(selected) }
    }
    /// Mirrors the editor's active file in the sidebar selection.
    func reveal(_ url: URL) {
        for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? FileNode)?.url == url {
            outline.selectRowIndexes([row], byExtendingSelection: false); return
        }
        outline.deselectAll(nil)
    }
    private func refreshCells() {
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? FileNode, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell else { continue }
            cell.dot.isHidden = !dirty.contains(node.url)
        }
    }

    // MARK: Outline card
    func setOutline(_ items: [OutlineItem], cursorLine: Int) {
        outlineItems = items
        outlineStack.arrangedSubviews.forEach { outlineStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        outlineTitle.isHidden = items.isEmpty; outlineCard.isHidden = items.isEmpty
        outlineHeight.constant = items.isEmpty ? 0 : min(CGFloat(items.count) * 37 - 1, 223)
        currentOutline = items.lastIndex { $0.line <= cursorLine } ?? -1
        for (index, item) in items.enumerated() {
            if index > 0 {
                let rule = Chip(fill: Theme.hairline, radius: 0); rule.size(nil, 1)
                let holder = NSView(); holder.translatesAutoresizingMaskIntoConstraints = false; rule.translatesAutoresizingMaskIntoConstraints = false; holder.addSubview(rule)
                NSLayoutConstraint.activate([rule.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 28), rule.trailingAnchor.constraint(equalTo: holder.trailingAnchor), rule.topAnchor.constraint(equalTo: holder.topAnchor), rule.bottomAnchor.constraint(equalTo: holder.bottomAnchor)])
                outlineStack.addArrangedSubview(holder); holder.widthAnchor.constraint(equalTo: outlineStack.widthAnchor).isActive = true
            }
            let current = index == currentOutline
            let row = RowButton(height: 36) { [weak self] in self?.onJump?(item.line) }
            row.setAccessibilityLabel(item.title)
            let dot = Chip(fill: current ? Theme.accent : .clear, radius: -1); dot.size(6, 6)
            let number = Theme.label(item.number, size: 13, color: Theme.muted); number.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular); number.isHidden = item.number.isEmpty
            let title = Theme.label(item.title, size: 13, color: current ? Theme.text : Theme.soft, weight: current ? .medium : .regular)
            title.lineBreakMode = .byTruncatingTail; title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            title.setContentHuggingPriority(.init(1), for: .horizontal)
            let badge = Theme.label(L10n.tr("当前"), size: 11.5, color: Theme.accent); badge.isHidden = !current
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
            let content = NSStackView(views: [dot, number, title, badge]); content.spacing = 8; content.alignment = .centerY
            content.setCustomSpacing(10 + CGFloat(item.level) * 12, after: dot)
            row.pinRow(content, leading: 12, trailing: 12)
            outlineStack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: outlineStack.widthAnchor).isActive = true
        }
    }
    /// Moves the "current" marker when the cursor enters another section.
    func updateOutline(cursorLine: Int) {
        let current = outlineItems.lastIndex { $0.line <= cursorLine } ?? -1
        if current != currentOutline { setOutline(outlineItems, cursorLine: cursorLine) }
    }
    var outlineItemsForSearch: [OutlineItem] { outlineItems }
    var currentOutlineTitle: String? { outlineItems.indices.contains(currentOutline) ? outlineItems[currentOutline].title : nil }

    // MARK: File list
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? FileNode ?? root)?.children.count ?? 0 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? FileNode ?? root)!.children[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.isDirectory ?? false }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { FileRowView() }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("fileCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? FileCell ?? FileCell()
        cell.identifier = id
        cell.label.stringValue = node.url.lastPathComponent
        cell.folder.isHidden = !node.isDirectory; cell.badge.isHidden = node.isDirectory
        cell.folder.image = Theme.symbol("folder.fill", size: 15); cell.folder.contentTintColor = Theme.accent
        cell.badge.ext = node.url.pathExtension.lowercased()
        cell.dot.isHidden = !dirty.contains(node.url)
        return cell
    }
    @objc func selected() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.animator().collapseItem(node) } else { outline.animator().expandItem(node) }
            outline.deselectRow(outline.clickedRow)
        } else { onOpen?(node.url) }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if outline.item(atRow: outline.clickedRow) is FileNode {
            let finder = NSMenuItem(title: L10n.tr("在访达中显示"), action: #selector(showInFinder), keyEquivalent: ""); finder.target = self; menu.addItem(finder)
            let copy = NSMenuItem(title: L10n.tr("拷贝路径"), action: #selector(copyPath), keyEquivalent: ""); copy.target = self; menu.addItem(copy)
            menu.addItem(.separator())
        }
        let new = NSMenuItem(title: L10n.tr("新建文件…"), action: #selector(newFile), keyEquivalent: ""); new.target = self; menu.addItem(new)
    }
    private var clickedURL: URL? { (outline.item(atRow: outline.clickedRow) as? FileNode)?.url }
    @objc private func showInFinder() { if let url = clickedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    @objc private func copyPath() {
        guard let url = clickedURL else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string)
    }
    @objc private func newFile() { onNew?() }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }
