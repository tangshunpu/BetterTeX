import AppKit
import BetterTeXCore

/// What the editor shows with no file open: a way straight back into the document instead of a blank page.
/// The main file is one click away, recently closed and other source files are listed below it.
final class EditorEmptyState: Surface {
    var onOpen: ((URL) -> Void)?
    var onNew: (() -> Void)?
    var onSearch: (() -> Void)?
    private let column = NSStackView()
    private let title = Theme.label(L10n.tr("没有打开的文件"), size: 20, weight: .bold)
    private let subtitle = Theme.label("", size: 13, color: Theme.muted)
    private let primarySlot = NSStackView()
    private let listTitle = Theme.label(L10n.tr("最近与项目文件"), size: 12, color: Theme.muted, weight: .semibold)
    private let list = NSStackView()
    private let card = Chip(fill: Theme.fillSoft, radius: 10)

    override init(frame: NSRect) {
        super.init(frame: frame); fill = Theme.canvas
        let tile = Chip(fill: Theme.fill, radius: 16); tile.size(56, 56)
        let icon = NSImageView(image: Theme.symbol("doc.text", size: 24, weight: .regular)!); icon.contentTintColor = Theme.muted
        icon.translatesAutoresizingMaskIntoConstraints = false; tile.addSubview(icon)
        NSLayoutConstraint.activate([icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor), icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor)])
        subtitle.alignment = .center

        list.orientation = .vertical; list.spacing = 0; list.alignment = .leading
        card.layer?.masksToBounds = true; card.pin(list)

        let search = ActionButton(L10n.tr("搜索文件  ⌘K"), style: .plain) { [weak self] in self?.onSearch?() }
        let new = ActionButton(L10n.tr("新建文件  ⌘N"), style: .plain) { [weak self] in self?.onNew?() }
        let dot = Theme.label("·", size: 12, color: Theme.faint)
        let shortcuts = NSStackView(views: [search, dot, new]); shortcuts.spacing = 6; shortcuts.alignment = .centerY

        column.orientation = .vertical; column.alignment = .centerX; column.spacing = 6
        for view in [tile, title, subtitle, primarySlot, listTitle, card, shortcuts] as [NSView] { column.addArrangedSubview(view) }
        column.setCustomSpacing(14, after: tile); column.setCustomSpacing(18, after: subtitle)
        column.setCustomSpacing(26, after: primarySlot); column.setCustomSpacing(8, after: listTitle); column.setCustomSpacing(18, after: card)
        column.translatesAutoresizingMaskIntoConstraints = false; addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor), column.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 380), column.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
            card.widthAnchor.constraint(equalTo: column.widthAnchor), listTitle.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 8)
        ])
        let wide = column.widthAnchor.constraint(equalToConstant: 380); wide.priority = .defaultLow; wide.isActive = true
        configure(main: nil, files: [], project: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `main` gets the primary button; `files` (already ordered, most relevant first) fill the list.
    func configure(main: URL?, files: [URL], project: URL?) {
        primarySlot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let main {
            let open = ActionButton(L10n.tr("打开 \(main.lastPathComponent)"), symbol: "doc.text", style: .pill) { [weak self] in self?.onOpen?(main) }
            open.toolTip = L10n.tr("主文件"); primarySlot.addArrangedSubview(open)
        }
        primarySlot.isHidden = main == nil
        subtitle.stringValue = main == nil && files.isEmpty ? L10n.tr("这个项目还没有 .tex 文件") : L10n.tr("从左侧选择一个文件，或从这里继续")

        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, url) in files.prefix(6).enumerated() {
            if index > 0 {
                let rule = Chip(fill: Theme.hairline, radius: 0); rule.size(nil, 1)
                list.addArrangedSubview(rule); rule.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            let row = RowButton(height: 36) { [weak self] in self?.onOpen?(url) }
            row.setAccessibilityLabel(url.lastPathComponent)
            let badge = FileBadge(); badge.ext = url.pathExtension.lowercased()
            let name = Theme.label(url.lastPathComponent, size: 13); name.lineBreakMode = .byTruncatingMiddle
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let folder = project.map { url.deletingLastPathComponent().path.replacingOccurrences(of: $0.path, with: "") } ?? ""
            let detail = Theme.label(folder.isEmpty ? "" : String(folder.dropFirst()), size: 11.5, color: Theme.faint)
            detail.lineBreakMode = .byTruncatingHead; detail.setContentCompressionResistancePriority(.init(100), for: .horizontal)
            let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let content = NSStackView(views: [badge, name, spacer, detail]); content.spacing = 9; content.alignment = .centerY
            row.pinRow(content, leading: 12, trailing: 12)
            list.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        listTitle.isHidden = files.isEmpty; card.isHidden = files.isEmpty
    }
}
