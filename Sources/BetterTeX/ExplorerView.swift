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
    /// Figures, tables and algorithms sit in the outline beside the headings; nil for headings.
    var float: TexStructure.BlockKind? = nil
    /// Last line of a float, so the outline only marks it current while the caret is inside it.
    var endLine: Int? = nil
    /// The row that holds `line`: the innermost float around it, else the last heading above it.
    static func current(in items: [OutlineItem], line: Int) -> Int {
        if let float = items.lastIndex(where: { $0.float != nil && $0.line <= line && line <= ($0.endLine ?? $0.line) }) { return float }
        return items.lastIndex { $0.float == nil && $0.line <= line } ?? -1
    }
    /// Headings plus the document's floats, in source order.
    static func parse(_ text: String) -> [OutlineItem] {
        let headings = parseHeadings(text)
        let structure = TexStructure.scan(text)
        guard !structure.blocks.isEmpty else { return headings }
        let ns = text as NSString
        // Line numbers for each float's first and last line, found in one pass over the text.
        var marks = structure.blocks.flatMap { [$0.header.location, NSMaxRange($0.range) - 1] }.sorted()
        var lineAt: [Int: Int] = [:]; var line = 1, index = 0
        for mark in marks {
            while index < min(mark, ns.length) { if ns.character(at: index) == 10 { line += 1 }; index += 1 }
            lineAt[mark] = line
        }
        marks.removeAll()
        let floats = structure.blocks.map { block -> OutlineItem in
            let name: String
            switch block.kind { case .figure: name = "Figure"; case .table: name = "Table"; case .algorithm: name = "Algorithm" }
            return OutlineItem(title: block.caption.flatMap { $0.isEmpty ? nil : $0 } ?? "\(name) \(block.number)", number: "\(block.number)", level: 3,
                               line: lineAt[block.header.location] ?? 1, float: block.kind, endLine: lineAt[NSMaxRange(block.range) - 1])
        }
        return (headings + floats).enumerated().sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }.map(\.element)
    }
    /// Scans LaTeX source for the title, abstract and sectioning commands.
    private static func parseHeadings(_ text: String) -> [OutlineItem] {
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
    private let outlineScroll = NSScrollView()
    private let outlineHeader = NSStackView()
    private let outlineCount = Theme.label("", size: 11, color: Theme.faint, weight: .medium)
    private let fileScroll = NSScrollView()
    /// The file list takes only the rows it shows, so the outline sits right under it.
    private var fileHeight: NSLayoutConstraint!
    private var currentRow: NSView?
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
        let scroll = fileScroll; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("files")); outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.headerView = nil; outline.rowHeight = 32; outline.indentationPerLevel = 16; outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.style = .plain; outline.backgroundColor = .clear; outline.focusRingType = .none
        outline.dataSource = self; outline.delegate = self; outline.target = self; outline.action = #selector(selected)
        let menu = NSMenu(); menu.delegate = self; outline.menu = menu
        scroll.documentView = outline

        outlineScroll.drawsBackground = false; outlineScroll.hasVerticalScroller = true; outlineScroll.autohidesScrollers = true
        let flipped = FlippedView(); outlineStack.orientation = .vertical; outlineStack.spacing = 1; outlineStack.alignment = .leading
        outlineStack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 10, right: 0)
        outlineStack.translatesAutoresizingMaskIntoConstraints = false; flipped.addSubview(outlineStack)
        flipped.translatesAutoresizingMaskIntoConstraints = false; outlineScroll.documentView = flipped
        NSLayoutConstraint.activate([
            outlineStack.topAnchor.constraint(equalTo: flipped.topAnchor), outlineStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor), outlineStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor), outlineStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            flipped.leadingAnchor.constraint(equalTo: outlineScroll.contentView.leadingAnchor), flipped.trailingAnchor.constraint(equalTo: outlineScroll.contentView.trailingAnchor), flipped.topAnchor.constraint(equalTo: outlineScroll.contentView.topAnchor)
        ])
        let outlineIcon = NSImageView(image: Theme.symbol("list.bullet.indent", size: 11, weight: .semibold)!); outlineIcon.contentTintColor = Theme.muted
        let rule = Chip(fill: Theme.hairline, radius: 0); rule.size(nil, 1); rule.setContentHuggingPriority(.init(1), for: .horizontal)
        for view in [outlineIcon, Theme.label(L10n.tr("大纲"), size: 12, color: Theme.muted, weight: .semibold), outlineCount, rule] { outlineHeader.addArrangedSubview(view) }
        outlineHeader.spacing = 6; outlineHeader.alignment = .centerY; outlineHeader.setCustomSpacing(10, after: outlineCount)
        fileHeight = scroll.heightAnchor.constraint(equalToConstant: 200)
        NotificationCenter.default.addObserver(self, selector: #selector(filesChanged), name: NSOutlineView.itemDidExpandNotification, object: outline)
        NotificationCenter.default.addObserver(self, selector: #selector(filesChanged), name: NSOutlineView.itemDidCollapseNotification, object: outline)

        for view in [header, scroll, outlineHeader, outlineScroll] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 10), header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), header.heightAnchor.constraint(equalToConstant: 30),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4), scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            fileHeight,
            outlineHeader.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10), outlineHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), outlineHeader.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), outlineHeader.heightAnchor.constraint(equalToConstant: 26),
            outlineScroll.topAnchor.constraint(equalTo: outlineHeader.bottomAnchor, constant: 4), outlineScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), outlineScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            outlineScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        setOutline([], cursorLine: 1)
    }
    required init?(coder: NSCoder) { fatalError() }
    func load(_ url: URL) { root = FileNode(url); outline.reloadData(); needsLayout = true }
    @objc private func filesChanged() { needsLayout = true }
    override func layout() {
        // Files keep the rows they need, up to about half the sidebar when an outline is showing.
        let available = max(0, bounds.height - 44 - 4)
        let rows = CGFloat(outline.numberOfRows) * (outline.rowHeight + outline.intercellSpacing.height) + 4
        fileHeight.constant = outlineItems.isEmpty ? available : max(min(rows, 96, available), min(rows, (available - 40) * 0.5))
        super.layout()
    }
    /// Empties the tree when no project is open.
    func unload() { root = nil; outline.reloadData(); setOutline([], cursorLine: 1); needsLayout = true }
    func refresh() {
        guard let root else { return }
        let expanded = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? FileNode }.filter { outline.isItemExpanded($0) }.map { $0.url.path }
        let selected = (outline.item(atRow: outline.selectedRow) as? FileNode)?.url
        root.cachedChildren = nil; outline.reloadData(); needsLayout = true
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
        let previous = currentOutline
        outlineItems = items
        outlineStack.arrangedSubviews.forEach { outlineStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        outlineHeader.isHidden = items.isEmpty; outlineScroll.isHidden = items.isEmpty
        let sections = items.filter { $0.level == 0 && !$0.number.isEmpty }.count
        outlineCount.stringValue = sections > 0 ? "\(sections)" : ""
        currentOutline = OutlineItem.current(in: items, line: cursorLine)
        // The section that holds the cursor stays emphasised while a subsection is current.
        let currentSection = currentOutline >= 0 ? items[...currentOutline].lastIndex { $0.level == 0 } : nil
        currentRow = nil
        for (index, item) in items.enumerated() {
            if index > 0, item.level == 0 {
                let gap = NSView(); gap.size(nil, 4); outlineStack.addArrangedSubview(gap)
            }
            let row = outlineRow(item, current: index == currentOutline, inCurrentSection: index == currentSection)
            outlineStack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: outlineStack.widthAnchor).isActive = true
            if index == currentOutline { currentRow = row }
        }
        needsLayout = true
        if currentOutline != previous, let row = currentRow {
            DispatchQueue.main.async { [weak self] in
                guard let self, row.superview != nil else { return }
                self.outlineStack.superview?.layoutSubtreeIfNeeded()
                row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -12))
            }
        }
    }
    private func outlineRow(_ item: OutlineItem, current: Bool, inCurrentSection: Bool) -> NSView {
        if let float = item.float { return floatRow(item, kind: float, current: current) }
        let level = min(item.level, 2)
        let row = RowButton(height: level == 0 ? 30 : 26) { [weak self] in self?.onJump?(item.line) }
        row.layer?.cornerRadius = 7; row.layer?.cornerCurve = .continuous
        row.setAccessibilityLabel(item.number.isEmpty ? item.title : "\(item.number) \(item.title)")
        if current {
            let highlight = Chip(fill: Theme.accent.withAlphaComponent(0.13), radius: 7); row.addSubview(highlight)
            highlight.translatesAutoresizingMaskIntoConstraints = false
            let bar = Chip(fill: Theme.accent, radius: 1.5); bar.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(bar)
            NSLayoutConstraint.activate([
                highlight.leadingAnchor.constraint(equalTo: row.leadingAnchor), highlight.trailingAnchor.constraint(equalTo: row.trailingAnchor), highlight.topAnchor.constraint(equalTo: row.topAnchor), highlight.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                bar.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 3), bar.widthAnchor.constraint(equalToConstant: 3), bar.topAnchor.constraint(equalTo: row.topAnchor, constant: 7), bar.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -7)
            ])
        }
        // Nested headings hang from a thin guide under their section's marker.
        for depth in 0..<level {
            let guide = Chip(fill: Theme.hairline, radius: 0); guide.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(guide)
            NSLayoutConstraint.activate([guide.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 22 + CGFloat(depth) * 16), guide.widthAnchor.constraint(equalToConstant: 1), guide.topAnchor.constraint(equalTo: row.topAnchor), guide.bottomAnchor.constraint(equalTo: row.bottomAnchor)])
        }
        let marker: NSView
        if item.number.isEmpty || level == 0 && item.title == L10n.tr("标题") {
            // Title, abstract and starred headings get a glyph instead of a number.
            let symbol = item.title == L10n.tr("标题") ? "textformat" : item.title == "Abstract" ? "text.quote" : level == 0 ? "number" : "circle.fill"
            let icon = NSImageView(image: Theme.symbol(symbol, size: level == 0 ? 11 : 5, weight: .semibold)!)
            icon.contentTintColor = current ? Theme.accent : level == 0 ? Theme.indigo : Theme.faint
            let holder = NSView(); holder.size(level == 0 ? 24 : 12, 18); icon.translatesAutoresizingMaskIntoConstraints = false; holder.addSubview(icon)
            NSLayoutConstraint.activate([icon.centerXAnchor.constraint(equalTo: holder.centerXAnchor), icon.centerYAnchor.constraint(equalTo: holder.centerYAnchor)])
            marker = holder
        } else if level == 0 {
            let number = Theme.label(item.number, size: 11, color: current || inCurrentSection ? .white : Theme.accent, weight: .semibold)
            number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold); number.alignment = .center
            let chip = Chip(fill: current || inCurrentSection ? Theme.accent : Theme.accent.withAlphaComponent(0.13), radius: 5)
            chip.size(nil, 18); chip.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true; chip.pinRow(number, leading: 5, trailing: 5)
            marker = chip
        } else {
            let number = Theme.label(item.number, size: 11.5, color: current ? Theme.accent : Theme.faint)
            number.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            marker = number
        }
        marker.setContentCompressionResistancePriority(.required, for: .horizontal); marker.setContentHuggingPriority(.required, for: .horizontal)
        let size: CGFloat = level == 0 ? 13 : level == 1 ? 12.5 : 12
        let color = current ? Theme.accent : level == 0 ? Theme.text : level == 1 ? Theme.soft : Theme.muted
        let weight: NSFont.Weight = current || level == 0 ? .semibold : .regular
        let title = Theme.label(item.title.isEmpty ? L10n.tr("（无标题）") : item.title, size: size, color: color, weight: weight)
        title.lineBreakMode = .byTruncatingTail; title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.init(1), for: .horizontal); title.toolTip = item.title
        let content = NSStackView(views: [marker, title]); content.spacing = level == 0 ? 8 : 6; content.alignment = .centerY
        row.pinRow(content, leading: level == 0 ? 10 : 30 + CGFloat(level - 1) * 16, trailing: 10)
        return row
    }
    /// A compact row for a figure/table: a tinted glyph, "Fig. 2" and its caption.
    private func floatRow(_ item: OutlineItem, kind: TexStructure.BlockKind, current: Bool) -> NSView {
        let row = RowButton(height: 22) { [weak self] in self?.onJump?(item.line) }
        row.layer?.cornerRadius = 6; row.layer?.cornerCurve = .continuous
        let color = Theme.structure(kind)
        if current {
            let highlight = Chip(fill: color.withAlphaComponent(0.14), radius: 6); highlight.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(highlight)
            NSLayoutConstraint.activate([highlight.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 22), highlight.trailingAnchor.constraint(equalTo: row.trailingAnchor), highlight.topAnchor.constraint(equalTo: row.topAnchor), highlight.bottomAnchor.constraint(equalTo: row.bottomAnchor)])
        }
        let symbol: String, short: String
        switch kind {
        case .figure: symbol = "photo"; short = "Fig."
        case .table: symbol = "tablecells"; short = "Tab."
        case .algorithm: symbol = "list.number"; short = "Alg."
        }
        row.setAccessibilityLabel("\(short) \(item.number) \(item.title)")
        let icon = NSImageView(image: Theme.symbol(symbol, size: 10, weight: .medium)!); icon.contentTintColor = color
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let tag = Theme.label("\(short) \(item.number)", size: 11, color: color, weight: .semibold)
        tag.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        tag.setContentCompressionResistancePriority(.required, for: .horizontal); tag.setContentHuggingPriority(.required, for: .horizontal)
        let title = Theme.label(item.title, size: 11.5, color: current ? Theme.text : Theme.muted)
        title.lineBreakMode = .byTruncatingTail; title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.init(1), for: .horizontal); title.toolTip = item.title
        let content = NSStackView(views: [icon, tag, title]); content.spacing = 5; content.alignment = .centerY
        row.pinRow(content, leading: 30, trailing: 10)
        return row
    }
    /// Moves the "current" marker when the cursor enters another section.
    func updateOutline(cursorLine: Int) {
        let current = OutlineItem.current(in: outlineItems, line: cursorLine)
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
