import AppKit
import BetterTeXCore

/// A project folder BetterTeX has opened before.
struct LocalProject {
    let url: URL
    let opened: Date?
    /// When a file in the project last changed on disk.
    var modified: Date? = nil
    let link: OverleafLink?
}

/// What the dashboard knows about the Overleaf account.
enum OverleafListState {
    case signedOut, loading, signedIn([OverleafProject]), failed(String)
}

private final class ReturnKeyTable: NSTableView {
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
    }
}

/// A sidebar entry that stays highlighted while its filter is active.
private final class FilterRow: NSView {
    var onClick: (() -> Void)?
    var selected = false { didSet { needsDisplay = true; refresh() } }
    private var hovering = false { didSet { needsDisplay = true } }
    private let icon = NSImageView()
    private let title: NSTextField
    let count = Theme.label("", size: 12, color: Theme.muted)
    init(_ text: String, symbol: String) {
        title = Theme.label(text, size: 13.5)
        super.init(frame: .zero); wantsLayer = true; layer?.cornerRadius = 8; layer?.cornerCurve = .continuous
        icon.image = Theme.symbol(symbol, size: 14); icon.size(20, 20)
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let row = NSStackView(views: [icon, title, NSView(), count]); row.spacing = 9; row.alignment = .centerY
        size(nil, 34); pinRow(row, leading: 10, trailing: 12)
        setAccessibilityElement(true); setAccessibilityRole(.radioButton); setAccessibilityLabel(text); refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func refresh() {
        title.font = .systemFont(ofSize: 13.5, weight: selected ? .semibold : .regular)
        icon.contentTintColor = selected ? Theme.accent : Theme.muted; setAccessibilityValue(selected)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = (selected ? Theme.fill : hovering ? Theme.fillSoft : NSColor.clear).cgColor }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// The project dashboard shown while no project is open: every local project BetterTeX knows and,
/// once signed in, every Overleaf project, in one searchable list. A click opens the project.
final class WelcomeView: Surface, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    private struct Row {
        let name: String
        let url: URL?
        let remote: OverleafProject?
        let linked: Bool
        let date: Date?
        let place: String
        /// For a linked folder: its Overleaf project is in the trash, or not in the account at all.
        var linkIssue: LinkIssue? = nil
    }
    private enum LinkIssue { case trashed, missing }
    private enum Filter: Int { case all, local, overleaf }
    var onOpen: (() -> Void)?
    var onClone: (() -> Void)?
    var onSample: (() -> Void)?
    var onRecent: ((URL) -> Void)?
    var onForget: ((URL) -> Void)?
    var onDownload: ((OverleafProject) -> Void)?
    var onSignIn: (() -> Void)?
    var onSignOut: (() -> Void)?
    var onRefresh: (() -> Void)?

    private var local: [LocalProject] = []
    private var overleaf = OverleafListState.signedOut
    private var filter = Filter.all
    private var rows: [Row] = []
    private let table = ReturnKeyTable()
    private let search = NSTextField()
    private let heading = Theme.label(L10n.tr("全部项目"), size: 22, weight: .bold)
    private let progress = Theme.label("", size: 12, color: Theme.muted)
    private let spinner = NSProgressIndicator()
    private let filters: [FilterRow] = [FilterRow(L10n.tr("全部项目"), symbol: "square.grid.2x2"), FilterRow(L10n.tr("本机项目"), symbol: "internaldrive"), FilterRow(L10n.tr("Overleaf 项目"), symbol: "leaf")]
    private let accountTitle = Theme.label("Overleaf", size: 12.5, weight: .semibold)
    private let accountDetail = NSTextField(wrappingLabelWithString: "")
    private var accountButton: ActionButton!
    private let empty = NSStackView()
    private let emptyTitle = Theme.label("", size: 20, weight: .bold)
    private let emptyDetail = NSTextField(wrappingLabelWithString: "")
    private var emptySignIn: ActionButton!
    private var emptyOpen: ActionButton!
    private var emptyMore: NSView!
    private let listScroll = NSScrollView()
    private let formatter: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; f.locale = L10n.locale; return f }()
    private let fullDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = L10n.locale; f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame); fill = Theme.base

        // Sidebar: start something new, narrow the list, and the Overleaf account.
        let side = Surface(); side.fill = Theme.sidebar; side.lineColor = Theme.line; side.trailingLine = true
        let new = ActionButton(L10n.tr("打开或新建"), symbol: "plus", style: .pill) { [weak self] in self?.showNewMenu() }
        new.toolTip = L10n.tr("打开文件夹、克隆仓库或创建示例项目"); newButton = new
        for (index, row) in filters.enumerated() { row.onClick = { [weak self] in self?.select(Filter(rawValue: index) ?? .all) } }
        let filterStack = NSStackView(views: filters); filterStack.orientation = .vertical; filterStack.spacing = 2; filterStack.alignment = .leading
        accountDetail.font = .systemFont(ofSize: 12); accountDetail.textColor = Theme.muted
        accountButton = ActionButton(L10n.tr("登录 Overleaf"), style: .tinted) { [weak self] in self?.accountTapped() }
        let account = NSStackView(views: [accountTitle, accountDetail, accountButton]); account.orientation = .vertical; account.spacing = 6; account.alignment = .leading
        account.setCustomSpacing(10, after: accountDetail)
        let accountCard = Chip(fill: Theme.fillSoft, radius: 12)
        account.translatesAutoresizingMaskIntoConstraints = false; accountCard.addSubview(account)
        NSLayoutConstraint.activate([account.topAnchor.constraint(equalTo: accountCard.topAnchor, constant: 12), account.bottomAnchor.constraint(equalTo: accountCard.bottomAnchor, constant: -12), account.leadingAnchor.constraint(equalTo: accountCard.leadingAnchor, constant: 12), account.trailingAnchor.constraint(equalTo: accountCard.trailingAnchor, constant: -12)])
        for view in [new, filterStack, accountCard] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; side.addSubview(view) }
        for row in filters { row.widthAnchor.constraint(equalTo: filterStack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            new.topAnchor.constraint(equalTo: side.topAnchor, constant: 18), new.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 14), new.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -15), new.heightAnchor.constraint(equalToConstant: 36),
            filterStack.topAnchor.constraint(equalTo: new.bottomAnchor, constant: 18), filterStack.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 10), filterStack.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -11),
            accountCard.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 12), accountCard.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -13), accountCard.bottomAnchor.constraint(equalTo: side.bottomAnchor, constant: -14)
        ])

        // Header: which list this is, progress of a download, and the search field.
        let glass = NSImageView(image: Theme.symbol("magnifyingglass", size: 13, weight: .semibold)!); glass.contentTintColor = Theme.muted
        search.isBordered = false; search.drawsBackground = false; search.focusRingType = .none; search.font = .systemFont(ofSize: 13.5)
        search.textColor = Theme.text; search.placeholderString = L10n.tr("搜索项目"); search.delegate = self; search.setAccessibilityLabel(L10n.tr("搜索项目"))
        search.cell?.usesSingleLineMode = true; search.cell?.isScrollable = true
        search.setContentHuggingPriority(.init(1), for: .horizontal); search.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let searchRow = NSStackView(views: [glass, search]); searchRow.spacing = 8; searchRow.alignment = .centerY
        let searchBox = Chip(fill: Theme.fill, radius: 10); searchBox.size(280, 34); searchBox.pinRow(searchRow, leading: 10, trailing: 10)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let refresh = ActionButton("", symbol: "arrow.clockwise") { [weak self] in self?.onRefresh?() }; refresh.toolTip = L10n.tr("刷新项目列表")
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [heading, spinner, progress, spacer, refresh, searchBox]); header.spacing = 10; header.alignment = .centerY
        progress.lineBreakMode = .byTruncatingTail; progress.setContentCompressionResistancePriority(.init(100), for: .horizontal)

        // The list.
        for (id, title, width) in [("name", L10n.tr("名称"), 320.0), ("place", L10n.tr("位置"), 300.0), ("date", L10n.tr("修改时间"), 130.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; column.minWidth = id == "name" ? 200 : 90
            // Click a header to sort by it; click again to reverse. Dates start newest first.
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id != "date")
            column.headerToolTip = id == "date" ? L10n.tr("本机项目：文件最后修改的时间；Overleaf 项目：在 Overleaf 上最后修改的时间") : nil
            table.addTableColumn(column)
        }
        // Remember the chosen order between launches; the default is newest modification first.
        if let saved = UserDefaults.standard.string(forKey: "projects.sortKey"), ["name", "place", "date"].contains(saved) {
            sortKey = saved; sortAscending = UserDefaults.standard.bool(forKey: "projects.sortAscending")
        }
        table.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: sortAscending)]
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 46; table.intercellSpacing = NSSize(width: 12, height: 0); table.style = .inset; table.backgroundColor = .clear
        table.allowsMultipleSelection = false; table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(rowClicked)
        table.onReturn = { [weak self] in self?.open(row: self?.table.selectedRow ?? -1) }
        table.setAccessibilityLabel(L10n.tr("项目列表"))
        let menu = NSMenu(); menu.delegate = self; table.menu = menu
        listScroll.drawsBackground = false; listScroll.hasVerticalScroller = true; listScroll.autohidesScrollers = true; listScroll.documentView = table

        // Shown instead of the list when there is nothing to list.
        let tile = LogoMark(); tile.size(56, 56)
        emptyDetail.font = .systemFont(ofSize: 13); emptyDetail.textColor = Theme.muted; emptyDetail.alignment = .center
        emptyDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        emptySignIn = ActionButton(L10n.tr("登录 Overleaf"), symbol: "leaf.fill", style: .pill) { [weak self] in self?.onSignIn?() }
        emptyOpen = ActionButton(L10n.tr("打开已有项目…"), style: .tinted) { [weak self] in self?.onOpen?() }
        let primary = NSStackView(views: [emptySignIn, emptyOpen]); primary.spacing = 10
        let clone = ActionButton(L10n.tr("从 GitHub 克隆…"), style: .plain) { [weak self] in self?.onClone?() }
        let sample = ActionButton(L10n.tr("创建示例项目"), style: .plain) { [weak self] in self?.onSample?() }
        let more = NSStackView(views: [clone, sample]); more.spacing = 4; emptyMore = more
        empty.orientation = .vertical; empty.spacing = 8; empty.alignment = .centerX
        for view in [tile, emptyTitle, emptyDetail, primary, more] as [NSView] { empty.addArrangedSubview(view) }
        empty.setCustomSpacing(16, after: tile); empty.setCustomSpacing(18, after: emptyDetail); empty.setCustomSpacing(10, after: primary)

        for view in [side, header, listScroll, empty] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: topAnchor), side.bottomAnchor.constraint(equalTo: bottomAnchor), side.leadingAnchor.constraint(equalTo: leadingAnchor), side.widthAnchor.constraint(equalToConstant: 236),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 18), header.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 28), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24), header.heightAnchor.constraint(equalToConstant: 36),
            listScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14), listScroll.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 12), listScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), listScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: listScroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: listScroll.centerYAnchor, constant: -20)
        ])
        select(.all)
    }
    required init?(coder: NSCoder) { fatalError() }
    private var newButton: ActionButton!

    // MARK: Data
    func setLocal(_ projects: [LocalProject]) { local = projects; rebuild() }
    func setOverleaf(_ state: OverleafListState) { overleaf = state; rebuild() }
    /// Shows a line of progress next to the heading, e.g. while a project downloads.
    func setProgress(_ text: String?) {
        progress.stringValue = text ?? ""
        if text == nil { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
    }
    func focusSearch() { window?.makeFirstResponder(search) }
    private func select(_ value: Filter) {
        filter = value
        for (index, row) in filters.enumerated() { row.selected = index == value.rawValue }
        heading.stringValue = [L10n.tr("全部项目"), L10n.tr("本机项目"), L10n.tr("Overleaf 项目")][value.rawValue]
        rebuild()
    }
    private func rebuild() {
        var remote: [OverleafProject] = []; var signedIn = false
        if case .signedIn(let projects) = overleaf { remote = projects; signedIn = true }
        let linkedIDs = Set(local.compactMap { $0.link?.projectID })
        let remoteDates = Dictionary(remote.compactMap { project in project.lastUpdated.map { (project.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var all = local.map { project -> Row in
            // A linked project changed whenever either side did; unlinked ones fall back to when they were opened.
            let dates = [project.modified, project.link.flatMap { remoteDates[$0.projectID] }].compactMap { $0 }
            var issue: LinkIssue?
            // Only links to the server the dashboard is signed in to can be checked against its list.
            let signedHost = UserDefaults.standard.string(forKey: "overleaf.host") ?? OverleafClient.defaultHost
            func trimmed(_ host: String) -> String { host.hasSuffix("/") ? String(host.dropLast()) : host }
            if signedIn, let link = project.link, trimmed(link.host) == trimmed(signedHost) {
                issue = remoteByID[link.projectID].map { $0.trashed ? .trashed : nil } ?? .missing
            }
            return Row(name: project.url.lastPathComponent, url: project.url, remote: nil, linked: project.link != nil, date: dates.max() ?? project.opened,
                       place: (project.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath, linkIssue: issue)
        }
        // An Overleaf project already downloaded appears once, as its local folder.
        all += remote.filter { !linkedIDs.contains($0.id) && !$0.trashed && !$0.archived }.map { Row(name: $0.name, url: nil, remote: $0, linked: false, date: $0.lastUpdated, place: L10n.tr("Overleaf · 点按下载到本机")) }
        filters[0].count.stringValue = "\(all.count)"
        filters[1].count.stringValue = "\(all.filter { $0.url != nil }.count)"
        filters[2].count.stringValue = signedIn ? "\(all.filter { $0.remote != nil || $0.linked }.count)" : ""
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        rows = all.filter { row in
            (filter == .all || (filter == .local && row.url != nil) || (filter == .overleaf && (row.remote != nil || row.linked)))
                && (query.isEmpty || row.name.lowercased().contains(query) || row.place.lowercased().contains(query))
        }.sorted { a, b in
            let byName = a.name.localizedStandardCompare(b.name)
            switch sortKey {
            case "name": if byName != .orderedSame { return (byName == .orderedAscending) == sortAscending }
            case "place":
                let byPlace = a.place.localizedStandardCompare(b.place)
                if byPlace != .orderedSame { return (byPlace == .orderedAscending) == sortAscending }
            default:
                // Projects without a date always sink to the bottom.
                if a.date != b.date {
                    guard let first = a.date else { return false }
                    guard let second = b.date else { return true }
                    return (first < second) == sortAscending
                }
            }
            return byName == .orderedAscending
        }
        table.reloadData()

        // Account card
        switch overleaf {
        case .signedOut: accountDetail.stringValue = L10n.tr("登录后，你在 Overleaf 上的全部项目会出现在列表里，点按即可下载并保持同步。"); accountButton.setTitle(L10n.tr("登录 Overleaf"))
        case .loading: accountDetail.stringValue = L10n.tr("正在读取 Overleaf 项目…"); accountButton.setTitle(L10n.tr("登录 Overleaf"))
        case .signedIn(let projects): accountDetail.stringValue = L10n.tr("已登录 · \(projects.count) 个项目"); accountButton.setTitle(L10n.tr("退出登录"))
        case .failed(let message): accountDetail.stringValue = L10n.tr("无法读取 Overleaf 项目：\(message)"); accountButton.setTitle(L10n.tr("重新登录"))
        }
        if case .loading = overleaf { accountButton.isHidden = true } else { accountButton.isHidden = false }

        // Empty states
        let nothingAtAll = all.isEmpty
        empty.isHidden = !rows.isEmpty; listScroll.isHidden = rows.isEmpty
        emptySignIn.isHidden = signedIn; emptyMore.isHidden = !nothingAtAll
        if nothingAtAll {
            emptyTitle.stringValue = L10n.tr("还没有项目")
            emptyDetail.stringValue = signedIn ? L10n.tr("你的 Overleaf 账户里没有项目。打开本机上已有的 LaTeX 文件夹开始写作。") : L10n.tr("登录 Overleaf 查看并下载你的全部项目，或者打开本机上已有的 LaTeX 文件夹。")
            emptyOpen.isHidden = false
        } else if filter == .overleaf && !signedIn {
            emptyTitle.stringValue = L10n.tr("登录 Overleaf"); emptyDetail.stringValue = L10n.tr("登录后这里会列出你在 Overleaf 上的全部项目。"); emptyOpen.isHidden = true
        } else {
            emptyTitle.stringValue = L10n.tr("没有匹配的项目"); emptyDetail.stringValue = query.isEmpty ? L10n.tr("这个分类下还没有项目。") : L10n.tr("没有名称或位置包含「\(search.stringValue)」的项目。")
            emptyOpen.isHidden = true; emptySignIn.isHidden = true
        }
    }

    // MARK: Actions
    private func accountTapped() { if case .signedIn = overleaf { onSignOut?() } else { onSignIn?() } }
    private func showNewMenu() {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(L10n.tr("打开文件夹…")) { [weak self] in self?.onOpen?() })
        menu.addItem(ClosureMenuItem(L10n.tr("从 GitHub 克隆…")) { [weak self] in self?.onClone?() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L10n.tr("创建示例项目")) { [weak self] in self?.onSample?() })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: newButton.bounds.height + 6), in: newButton)
    }
    private func open(row: Int) {
        guard rows.indices.contains(row) else { return }
        if let url = rows[row].url { onRecent?(url) } else if let remote = rows[row].remote { onDownload?(remote) }
    }
    @objc private func rowClicked() { open(row: table.clickedRow) }
    func controlTextDidChange(_ obj: Notification) { rebuild() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Return opens the top match; Down moves into the list.
        if selector == #selector(NSResponder.insertNewline(_:)) { open(row: 0); return true }
        if selector == #selector(NSResponder.moveDown(_:)), !rows.isEmpty { window?.makeFirstResponder(table); table.selectRowIndexes([0], byExtendingSelection: false); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { search.stringValue = ""; rebuild(); return true }
        return false
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard rows.indices.contains(table.clickedRow) else { return }
        let row = rows[table.clickedRow], index = table.clickedRow
        if let url = row.url {
            menu.addItem(ClosureMenuItem(L10n.tr("打开")) { [weak self] in self?.open(row: index) })
            menu.addItem(ClosureMenuItem(L10n.tr("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L10n.tr("从列表中移除")) { [weak self] in self?.onForget?(url) })
        } else { menu.addItem(ClosureMenuItem(L10n.tr("下载并打开")) { [weak self] in self?.open(row: index) }) }
    }

    // MARK: Table
    private var sortKey = "date"
    private var sortAscending = false
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        sortKey = key; sortAscending = descriptor.ascending
        UserDefaults.standard.set(key, forKey: "projects.sortKey"); UserDefaults.standard.set(descriptor.ascending, forKey: "projects.sortAscending")
        rebuild()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]; let cell = NSView()
        switch tableColumn?.identifier.rawValue {
        case "name":
            let icon = NSImageView(image: Theme.symbol(entry.url == nil ? "icloud.and.arrow.down" : "folder.fill", size: 15)!); icon.contentTintColor = entry.url == nil ? Theme.green : Theme.accent; icon.size(24, 24)
            let name = Theme.label(entry.name, size: 13.5, weight: .medium); name.lineBreakMode = .byTruncatingTail; name.setContentCompressionResistancePriority(.init(200), for: .horizontal)
            var views: [NSView] = [icon, name]
            if entry.linked {
                let leaf = NSImageView(image: Theme.symbol(entry.linkIssue == .missing ? "leaf" : "leaf.fill", size: 10)!); leaf.size(14, 14)
                switch entry.linkIssue {
                case .missing?:
                    leaf.contentTintColor = Theme.faint; leaf.toolTip = L10n.tr("在你的 Overleaf 账户中找不到关联的项目，打开后可重新上传或改关联")
                    leaf.setAccessibilityLabel(L10n.tr("关联的 Overleaf 项目已不可用"))
                case .trashed?:
                    leaf.contentTintColor = Theme.orange; leaf.toolTip = L10n.tr("关联的 Overleaf 项目在回收站中")
                    leaf.setAccessibilityLabel(L10n.tr("关联的 Overleaf 项目在回收站中"))
                case nil:
                    leaf.contentTintColor = Theme.green; leaf.toolTip = L10n.tr("已与 Overleaf 关联并同步")
                    leaf.setAccessibilityLabel(L10n.tr("已与 Overleaf 关联"))
                }
                views.append(leaf)
            }
            views.append(NSView())
            let line = NSStackView(views: views); line.spacing = 9; line.alignment = .centerY; cell.pinRow(line, leading: 2, trailing: 0)
        case "place":
            let place = Theme.label(entry.place, size: 12, color: Theme.muted); place.lineBreakMode = entry.url == nil ? .byTruncatingTail : .byTruncatingHead
            place.toolTip = entry.url?.path; cell.pinRow(place, leading: 0, trailing: 0)
        default:
            let date = Theme.label(entry.date.map { formatter.localizedString(for: $0, relativeTo: Date()) } ?? "—", size: 12, color: Theme.muted)
            date.toolTip = entry.date.map { fullDateFormatter.string(from: $0) }
            cell.pinRow(date, leading: 0, trailing: 0)
        }
        cell.setAccessibilityLabel(entry.name); return cell
    }
    // Swallow clicks so nothing behind the dashboard reacts.
    override func mouseDown(with event: NSEvent) {}
}
