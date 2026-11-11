import AppKit

/// Frame-based native split views avoid PDFKit's intrinsic sizing dominating editor width.
final class PaneItem {
    let viewController: NSViewController
    var minimumThickness: CGFloat = 0
    var maximumThickness: CGFloat = .greatestFiniteMagnitude
    var canCollapse = false
    weak var owner: PaneSplitController?
    var isCollapsed = false { didSet { owner?.resizePanes() } }
    init(viewController: NSViewController) { self.viewController = viewController }
}

final class WorkspaceSplitView: NSSplitView {
    var onDividerPosition: ((CGFloat) -> Void)?
    private var resizing = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var dividerColor: NSColor { Theme.line }
    /// A visible gutter with a grip, wide enough to be found and grabbed.
    override var dividerThickness: CGFloat { 7 }
    private var dividerRect: NSRect {
        guard subviews.count == 2, !subviews.contains(where: \.isHidden) else { return .zero }
        let first = subviews[0].frame
        return isVertical ? NSRect(x: first.maxX, y: 0, width: dividerThickness, height: bounds.height) : NSRect(x: 0, y: first.maxY, width: bounds.width, height: dividerThickness)
    }
    private var resizeHandle: NSRect { dividerRect.isEmpty ? .zero : dividerRect.insetBy(dx: isVertical ? -2 : 0, dy: isVertical ? 0 : -2) }
    override func drawDivider(in rect: NSRect) {
        let active = hovering || resizing
        (active ? Theme.accent.withAlphaComponent(0.16) : Theme.base).setFill(); rect.fill()
        Theme.line.setFill()
        if isVertical { NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill(); NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill() }
        else { NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill(); NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill() }
        let grip = isVertical ? NSRect(x: rect.midX - 1.5, y: rect.midY - 18, width: 3, height: 36) : NSRect(x: rect.midX - 18, y: rect.midY - 1.5, width: 36, height: 3)
        (active ? Theme.accent : Theme.faint).setFill(); NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if resizeHandle.contains(local) { return self }
        return super.hitTest(point)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if !resizeHandle.isEmpty { addCursorRect(resizeHandle, cursor: isVertical ? .resizeLeftRight : .resizeUpDown) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard !resizeHandle.isEmpty else { tracking = nil; hovering = false; return }
        let area = NSTrackingArea(rect: resizeHandle, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { resizing = resizeHandle.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) {
        guard resizing else { return }; let point = convert(event.locationInWindow, from: nil)
        onDividerPosition?((isVertical ? point.x : point.y) - dividerThickness / 2)
    }
    override func mouseUp(with event: NSEvent) { if resizing { mouseDragged(with: event) }; resizing = false }
}

final class PaneSplitController: NSViewController, NSSplitViewDelegate {
    enum Sizing { case fixedFirst, fixedLast, proportional }
    let splitView = WorkspaceSplitView()
    var items: [PaneItem] = []
    var sizing: Sizing = .proportional
    var persistenceKey: String?
    private var firstSize: CGFloat = 205
    private var lastSize: CGFloat = 220
    private var fraction: CGFloat = 0.52
    private var adjusting = false

    override func loadView() {
        view = splitView; splitView.delegate = self; splitView.dividerStyle = .thin
        splitView.onDividerPosition = { [weak self] position in
            guard let self else { return }
            let available = (self.splitView.isVertical ? self.splitView.bounds.width : self.splitView.bounds.height) - self.splitView.dividerThickness
            self.firstSize = position; self.lastSize = available - position; self.fraction = available > 0 ? position / available : 0.5
            self.resizePanes(); self.recordSizes()
        }
    }
    func resetPreferredSizes(first: CGFloat = 205, last: CGFloat = 220, ratio: CGFloat = 0.52) {
        firstSize = first; lastSize = last; fraction = ratio
        if let key = persistenceKey, let saved = UserDefaults.standard.array(forKey: key) as? [Double], saved.count == 3 {
            firstSize = saved[0]; lastSize = saved[1]; fraction = saved[2]
        }
        resizePanes()
    }
    func replaceItems(_ replacements: [PaneItem]) {
        adjusting = true
        for item in items { item.viewController.view.removeFromSuperview(); item.viewController.removeFromParent(); item.owner = nil }
        items.removeAll()
        for item in replacements { addSplitViewItem(item) }
        adjusting = false
    }
    func addSplitViewItem(_ item: PaneItem) {
        _ = view
        items.append(item); item.owner = self; addChild(item.viewController)
        let pane = item.viewController.view
        pane.translatesAutoresizingMaskIntoConstraints = true; pane.autoresizingMask = []
        splitView.addSubview(pane)
    }
    func resizePanes() {
        guard items.count == 2 else { return }
        adjusting = true; defer { adjusting = false }
        let bounds = splitView.bounds; let vertical = splitView.isVertical
        let first = items[0].viewController.view; let last = items[1].viewController.view
        first.isHidden = items[0].isCollapsed; last.isHidden = items[1].isCollapsed
        if items[0].isCollapsed { first.frame = .zero; last.frame = bounds; return }
        if items[1].isCollapsed { first.frame = bounds; last.frame = .zero; return }
        let available = max(0, (vertical ? bounds.width : bounds.height) - splitView.dividerThickness)
        let wanted: CGFloat
        switch sizing { case .fixedFirst: wanted = firstSize; case .fixedLast: wanted = available - lastSize; case .proportional: wanted = available * fraction }
        let lower = max(0, items[0].minimumThickness, available - items[1].maximumThickness)
        let upper = min(available, items[0].maximumThickness, available - items[1].minimumThickness)
        let firstLength = max(0, min(available, max(lower, min(upper, wanted))))
        let remaining = max(0, available - firstLength)
        if vertical {
            first.frame = NSRect(x: 0, y: 0, width: firstLength, height: bounds.height)
            last.frame = NSRect(x: firstLength + splitView.dividerThickness, y: 0, width: remaining, height: bounds.height)
        } else {
            first.frame = NSRect(x: 0, y: 0, width: bounds.width, height: firstLength)
            last.frame = NSRect(x: 0, y: firstLength + splitView.dividerThickness, width: bounds.width, height: remaining)
        }
        splitView.needsDisplay = true
        splitView.window?.invalidateCursorRects(for: splitView); splitView.updateTrackingAreas()
    }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { resizePanes() }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        recordSizes()
    }
    private func recordSizes() {
        guard !adjusting, items.count == 2, !items.contains(where: \.isCollapsed) else { return }
        let first = items[0].viewController.view.frame; let last = items[1].viewController.view.frame
        guard first.width > 0, last.width > 0, first.height > 0, last.height > 0 else { return }
        firstSize = splitView.isVertical ? first.width : first.height
        lastSize = splitView.isVertical ? last.width : last.height
        if firstSize + lastSize > 0 { fraction = firstSize / (firstSize + lastSize) }
        if let key = persistenceKey { UserDefaults.standard.set([Double(firstSize), Double(lastSize), Double(fraction)], forKey: key) }
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        items.first?.minimumThickness ?? 0
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let total = (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - splitView.dividerThickness
        return min(items[0].maximumThickness, total - items[1].minimumThickness)
    }
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { items.contains(where: \.isCollapsed) }
}
