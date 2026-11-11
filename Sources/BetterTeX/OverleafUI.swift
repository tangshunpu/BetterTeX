import AppKit
import BetterTeXCore

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: enabled ? #selector(run) : nil, keyEquivalent: "")
        target = self; state = checked ? .on : .off
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

/// A collaborator's avatar: initials on a disc tinted with the collaborator's own colour.
final class AvatarView: NSView {
    let initials: String
    let color: NSColor
    init(_ presence: OverleafPresence, side: CGFloat = 22) {
        initials = presence.initials; color = AvatarView.color(presence)
        super.init(frame: .zero); size(side, side); toolTip = presence.name
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel(presence.name)
    }
    required init?(coder: NSCoder) { fatalError() }
    static func color(_ presence: OverleafPresence) -> NSColor { NSColor(hue: presence.hue, saturation: 0.62, brightness: 0.78, alpha: 1) }
    override func draw(_ dirtyRect: NSRect) {
        Theme.header.setFill(); NSBezierPath(ovalIn: bounds).fill()
        color.setFill(); NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: bounds.height * 0.42, weight: .semibold), .foregroundColor: NSColor.white]
        let text = initials as NSString; let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

/// The title bar's Overleaf control: connection state plus the avatars of people online.
final class OverleafChip: Chip {
    var onClick: (() -> Void)?
    private let dot = Chip(fill: Theme.faint, radius: 3.5)
    private let label = Theme.label("Overleaf", size: 12.5, color: Theme.soft, weight: .medium)
    private let avatars = NSStackView()
    init() {
        super.init(fill: Theme.fill, radius: 8)
        let icon = NSImageView(image: Theme.symbol("leaf.fill", size: 11, weight: .semibold)!); icon.contentTintColor = Theme.green
        dot.size(7, 7); avatars.spacing = -6; avatars.alignment = .centerY
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, label, dot, avatars]); row.spacing = 6; row.alignment = .centerY
        size(nil, 32); pinRow(row, leading: 10, trailing: 10)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(L10n.tr("Overleaf 同步"))
        set(title: "Overleaf", color: nil, people: [], tip: L10n.tr("连接 Overleaf"))
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(title: String, color: NSColor?, people: [OverleafPresence], tip: String) {
        label.stringValue = title; toolTip = tip
        dot.isHidden = color == nil; if let color { dot.fill = color }
        avatars.arrangedSubviews.forEach { avatars.removeArrangedSubview($0); $0.removeFromSuperview() }
        for person in people.prefix(4) { avatars.addArrangedSubview(AvatarView(person)) }
        if people.count > 4 { let more = Theme.label("  +\(people.count - 4)", size: 11, color: Theme.muted); avatars.addArrangedSubview(more) }
        avatars.isHidden = people.isEmpty
    }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// A searchable list of the account's Overleaf projects, shown inside an alert.
final class ProjectPicker: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let all: [OverleafProject]
    private var shown: [OverleafProject]
    private let table = NSTableView()
    private let search = NSSearchField()
    var selected: OverleafProject? { shown.indices.contains(table.selectedRow) ? shown[table.selectedRow] : nil }
    init(_ projects: [OverleafProject]) {
        all = projects; shown = projects
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 320))
        search.frame = NSRect(x: 0, y: 290, width: 460, height: 26); search.placeholderString = L10n.tr("筛选项目"); search.delegate = self; addSubview(search)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); column.width = 440; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 26; table.dataSource = self; table.delegate = self; table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 282)); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        addSubview(scroll)
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }
    required init?(coder: NSCoder) { fatalError() }
    func controlTextDidChange(_ obj: Notification) {
        let needle = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        shown = needle.isEmpty ? all : all.filter { $0.name.lowercased().contains(needle) }
        table.reloadData(); if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let project = shown[row]
        let role = ["owner": L10n.tr("所有者"), "readAndWrite": L10n.tr("可编辑"), "readOnly": L10n.tr("只读"), "review": L10n.tr("审阅")][project.accessLevel] ?? project.accessLevel
        let line = NSStackView(views: [Theme.label(project.name, size: 13), NSView(), Theme.label(role, size: 11.5, color: Theme.muted)]); line.alignment = .centerY
        let cell = NSView(); cell.pinRow(line, leading: 6, trailing: 8); return cell
    }

    /// Runs the picker modally; nil when cancelled.
    static func choose(_ projects: [OverleafProject], title: String, confirm: String) -> OverleafProject? {
        let alert = NSAlert(); alert.messageText = title
        alert.informativeText = projects.isEmpty ? L10n.tr("这个账户下还没有项目。") : L10n.tr("共 \(projects.count) 个项目。")
        alert.addButton(withTitle: confirm); alert.addButton(withTitle: L10n.tr("取消"))
        let picker = ProjectPicker(projects); alert.accessoryView = picker
        alert.window.initialFirstResponder = picker.search
        return alert.runModal() == .alertFirstButtonReturn ? picker.selected : nil
    }
}

/// What the collaboration popover shows; rebuilt whenever presence or comments change.
struct OverleafPanelModel {
    struct Person { let presence: OverleafPresence; let place: String; let isSelf: Bool }
    struct Comment { let thread: OverleafThread; let quote: String; let offset: Int }
    var title = "Overleaf"
    var status = ""
    var people: [Person] = []
    var comments: [Comment] = []
    var canComment = false
    var commentHint = ""
}

final class OverleafPanel: NSViewController {
    var onJump: ((Int) -> Void)?
    var onReply: ((String, String) -> Void)?
    var onResolve: ((String) -> Void)?
    var onAddComment: ((String) -> Void)?
    var onInvite: (() -> Void)?
    private let stack = NSStackView()
    private var actions: [() -> Void] = []
    private var fields: [NSTextField] = []
    private static let width: CGFloat = 340

    override func loadView() {
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 440)); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = document
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalToConstant: Self.width), document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor)
        ])
        view = scroll
    }
    private func button(_ title: String, style: ActionButton.Style = .tinted, _ action: @escaping () -> Void) -> ActionButton { ActionButton(title, style: style, action: action) }
    private func wrapped(_ text: String, size: CGFloat = 12.5, color: NSColor = Theme.text) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: size); label.textColor = color; label.isSelectable = false
        label.preferredMaxLayoutWidth = Self.width - 52; return label
    }
    private func field(_ placeholder: String) -> NSTextField {
        let field = NSTextField(); field.placeholderString = placeholder; field.font = .systemFont(ofSize: 12.5); field.bezelStyle = .roundedBezel
        field.setContentHuggingPriority(.init(1), for: .horizontal); field.target = self; field.action = #selector(submitted(_:)); field.tag = fields.count
        fields.append(field); return field
    }
    @objc private func submitted(_ sender: NSTextField) { if actions.indices.contains(sender.tag) { actions[sender.tag]() } }

    func show(_ model: OverleafPanelModel) {
        _ = view
        // Keep a half-typed reply from being wiped by a background refresh.
        if let editor = view.window?.firstResponder as? NSTextView, fields.contains(where: { $0.currentEditor() === editor && !$0.stringValue.isEmpty }) { return }
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        actions.removeAll(); fields.removeAll()
        func add(_ view: NSView, fill: Bool = true) {
            stack.addArrangedSubview(view)
            if fill { view.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true }
        }
        let header = NSStackView(views: [Theme.label(model.title, size: 14, weight: .semibold), NSView(), button(L10n.tr("邀请")) { [weak self] in self?.onInvite?() }]); header.alignment = .centerY
        add(header); add(wrapped(model.status, size: 12, color: Theme.muted))

        add(Theme.label(L10n.tr("在线协作者 · \(model.people.count)"), size: 11.5, color: Theme.muted, weight: .semibold), fill: false)
        if model.people.isEmpty { add(wrapped(L10n.tr("目前只有你在线。"), size: 12, color: Theme.faint)) }
        for person in model.people {
            let name = Theme.label(person.presence.name + (person.isSelf ? L10n.tr("（你）") : ""), size: 13); name.lineBreakMode = .byTruncatingTail
            let place = Theme.label(person.place, size: 11.5, color: Theme.muted); place.setContentCompressionResistancePriority(.init(200), for: .horizontal)
            let row = NSStackView(views: [AvatarView(person.presence, side: 24), name, NSView(), place]); row.spacing = 8; row.alignment = .centerY
            add(row)
        }

        add(Theme.label(L10n.tr("当前文件的评论 · \(model.comments.count)"), size: 11.5, color: Theme.muted, weight: .semibold), fill: false)
        stack.setCustomSpacing(14, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        if model.comments.isEmpty { add(wrapped(model.commentHint, size: 12, color: Theme.faint)) }
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .short; formatter.locale = L10n.locale
        for comment in model.comments {
            let card = Chip(fill: Theme.fillSoft, radius: 10)
            let body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 5
            let offset = comment.offset
            let quote = button("“" + comment.quote.replacingOccurrences(of: "\n", with: " ").prefix(60) + "”", style: .plain) { [weak self] in self?.onJump?(offset) }
            quote.toolTip = L10n.tr("跳到评论位置"); body.addArrangedSubview(quote)
            for message in comment.thread.messages {
                let stamp = message.date.timeIntervalSince1970 > 0 ? " · " + formatter.localizedString(for: message.date, relativeTo: Date()) : ""
                body.addArrangedSubview(Theme.label(message.author + stamp, size: 11, color: Theme.muted, weight: .medium))
                body.addArrangedSubview(wrapped(message.content))
            }
            let reply = field(L10n.tr("回复…")); let id = comment.thread.id
            let send = { [weak self, weak reply] in
                guard let reply else { return }
                let text = reply.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { reply.stringValue = ""; self?.onReply?(id, text) }
            }
            actions.append(send)
            let controls = NSStackView(views: [reply, button(L10n.tr("回复"), send), button(L10n.tr("解决")) { [weak self] in self?.onResolve?(id) }]); controls.spacing = 6
            body.addArrangedSubview(controls); controls.widthAnchor.constraint(equalToConstant: Self.width - 52).isActive = true
            body.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(body)
            NSLayoutConstraint.activate([body.topAnchor.constraint(equalTo: card.topAnchor, constant: 10), body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10), body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12), body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12)])
            add(card)
        }
        if model.canComment {
            let input = field(L10n.tr("为选中的文字添加评论…"))
            let send = { [weak self, weak input] in
                guard let input else { return }
                let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { input.stringValue = ""; self?.onAddComment?(text) }
            }
            actions.append(send)
            let row = NSStackView(views: [input, button(L10n.tr("添加"), send)]); row.spacing = 6; add(row)
        }
    }
}

