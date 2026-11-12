import AppKit
import BetterTeXCore

private final class CompletionRow: NSTableRowView {
    // The list never takes keyboard focus, so draw its selection as if it had it.
    override var isEmphasized: Bool { get { true } set {} }
}

/// Switches its label colors when the row is selected, so they stay legible on the accent fill.
private final class CompletionCell: NSTableCellView {
    let label: NSTextField, detail: NSTextField
    init(label: NSTextField, detail: NSTextField) {
        self.label = label; self.detail = detail
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            label.textColor = selected ? .alternateSelectedControlTextColor : Theme.text
            detail.textColor = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8) : Theme.muted
        }
    }
}

/// The completion list shown under the caret. It never becomes key: typing stays in the editor,
/// which forwards the arrow, return, tab and escape keys here while the list is open.
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onAccept: ((CompletionItem) -> Void)?
    private let panel: NSPanel
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var items: [CompletionItem] = []
    private static let rowHeight: CGFloat = 24
    var isVisible: Bool { panel.isVisible }
    var selected: CompletionItem? { items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.becomesKeyOnlyIfNeeded = true; panel.isReleasedWhenClosed = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = Self.rowHeight; table.intercellSpacing = NSSize(width: 0, height: 0); table.style = .plain
        table.backgroundColor = .clear; table.refusesFirstResponder = true; table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(clicked)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = table
        let card = Chip(fill: Theme.card, radius: 9, border: Theme.line); card.pin(scroll, inset: 4)
        card.layer?.masksToBounds = true
        panel.contentView = card
    }
    /// `caret` is the rectangle of the text being completed, in screen coordinates.
    func show(_ items: [CompletionItem], at caret: NSRect, in parent: NSWindow) {
        self.items = items; table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false); table.scrollRowToVisible(0)
        let longest = items.prefix(40).map { $0.label.count + min($0.detail.count, 44) }.max() ?? 20
        let size = NSSize(width: min(520, max(240, CGFloat(longest) * 7.6 + 48)), height: CGFloat(min(items.count, 8)) * Self.rowHeight + 8)
        let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: caret.minX - 10, y: caret.minY - size.height - 4)
        if origin.y < screen.minY { origin.y = caret.maxY + 4 }   // no room below: open upwards
        origin.x = max(screen.minX + 4, min(origin.x, screen.maxX - size.width - 4))
        panel.appearance = parent.effectiveAppearance
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }
    func dismiss() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel); panel.orderOut(nil)
    }
    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let row = (table.selectedRow + delta + items.count) % items.count
        table.selectRowIndexes([row], byExtendingSelection: false); table.scrollRowToVisible(row)
    }
    @objc private func clicked() { if let selected { onAccept?(selected) } }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CompletionRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let label = Theme.label(item.label, size: 12.5); label.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular); label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(400), for: .horizontal)
        let detail = Theme.label(item.detail, size: 11.5, color: Theme.muted); detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.init(100), for: .horizontal); detail.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = NSStackView(views: [label, detail]); line.spacing = 10; line.alignment = .centerY
        let cell = CompletionCell(label: label, detail: detail); cell.pinRow(line, leading: 8, trailing: 8); return cell
    }
}
