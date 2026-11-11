import AppKit

enum DockPosition: String, CaseIterable {
    case left, right, bottom
    var title: String { switch self { case .left: return "停靠在左侧"; case .right: return "停靠在右侧"; case .bottom: return "停靠在底部" } }
    var symbol: String { switch self { case .left: return "sidebar.left"; case .right: return "sidebar.right"; case .bottom: return "rectangle.bottomthird.inset.filled" } }
}

/// A single-row pane header: title (or a leading control) and trailing controls.
/// Dragging its empty area re-docks the pane; right-clicking it lists docking commands.
final class PanelHeader: Surface {
    let panelID: String
    let row = NSStackView()
    private let titleLabel: NSTextField
    var onMove: ((DockPosition) -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onDrop: ((NSPoint) -> Void)?
    var onHide: (() -> Void)?
    /// Extra commands listed above the docking choices in the "more" menu.
    var menuActions: [(title: String, symbol: String, action: () -> Void)] = []
    var position: DockPosition = .right
    private var dragOrigin: NSPoint?
    private var dragging = false
    init(_ panelID: String, title: String, fill: NSColor = Theme.base) {
        self.panelID = panelID; titleLabel = Theme.label(title, size: 13, weight: .semibold)
        super.init(frame: .zero); self.fill = fill; bottomLine = true
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        row.addArrangedSubview(titleLabel); pinRow(row, leading: 14, trailing: 10)
    }
    required init?(coder: NSCoder) { fatalError() }
    func addControl(_ control: NSView) { row.addArrangedSubview(control) }
    /// Replaces the title with a control such as a segmented switcher.
    func setLeading(_ control: NSView) { titleLabel.isHidden = true; row.insertArrangedSubview(control, at: 0) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit is NSTextField || hit === row || hit?.superview === row && !(hit is NSControl) { return self }
        return hit
    }
    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow; dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        if !dragging && hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) < 4 { return }
        if !dragging { dragging = true; NSCursor.closedHand.push() }
        onDrag?(event.locationInWindow)
    }
    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        guard dragging else { return }; dragging = false; NSCursor.pop()
        onDrop?(event.locationInWindow)
    }
    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, entry) in menuActions.enumerated() {
            let item = NSMenuItem(title: entry.title, action: #selector(extraSelected(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil); menu.addItem(item)
        }
        if !menuActions.isEmpty { menu.addItem(.separator()) }
        for value in DockPosition.allCases {
            let item = NSMenuItem(title: value.title, action: #selector(moveSelected(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value.rawValue; item.state = value == position ? .on : .off
            item.image = NSImage(systemSymbolName: value.symbol, accessibilityDescription: nil); menu.addItem(item)
        }
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏面板", action: #selector(hideSelected), keyEquivalent: ""); hide.target = self
        hide.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil); menu.addItem(hide)
        return menu
    }
    @objc private func moveSelected(_ sender: NSMenuItem) { if let value = sender.representedObject as? String, let position = DockPosition(rawValue: value) { onMove?(position) } }
    @objc private func extraSelected(_ sender: NSMenuItem) { if menuActions.indices.contains(sender.tag) { menuActions[sender.tag].action() } }
    @objc private func hideSelected() { onHide?() }
}

final class DockOverlay: NSView {
    var zone: NSRect = .zero { didSet { needsDisplay = true } }
    var title = "" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let rect = zone.insetBy(dx: 8, dy: 8)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        Theme.accent.withAlphaComponent(0.14).setFill(); path.fill()
        Theme.accent.withAlphaComponent(0.7).setStroke(); path.lineWidth = 1.5; path.stroke()
        let text = title as NSString; let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Theme.accent]
        let size = text.size(withAttributes: attrs); text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
    }
}
