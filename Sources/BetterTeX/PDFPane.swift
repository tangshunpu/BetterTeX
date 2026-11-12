import AppKit
import PDFKit
import BetterTeXCore

/// A jump mark on a PDF page: a rounded, low-saturation fill that can fade out.
final class SyncMarkAnnotation: PDFAnnotation {
    let strength: CGFloat
    var fade: CGFloat = 1
    init(bounds: CGRect, strength: CGFloat) {
        self.strength = strength
        super.init(bounds: bounds, forType: .square, withProperties: nil)
        color = .clear; border = nil
    }
    required init?(coder: NSCoder) { strength = Theme.syncSentenceAlpha; super.init(coder: coder) }
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let radius = min(bounds.height * 0.32, 4)
        context.saveGState()
        context.setFillColor(Theme.syncPaperTint.withAlphaComponent(strength * fade).cgColor)
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        context.restoreGState()
    }
}

/// Positions in `PDFPage.string`. `characterIndex(at:)` and `characterBounds(at:)` count glyphs instead, which runs
/// ahead of the string by the line breaks and spaces PDFKit adds to it, so a click low on a page would land lines
/// away. Selections are addressed in the string's own terms.
extension PDFPage {
    func textBounds(at index: Int) -> CGRect {
        guard index >= 0, index < (string as NSString?)?.length ?? 0 else { return .zero }
        return selection(for: NSRange(location: index, length: 1))?.bounds(for: self) ?? .zero
    }
    /// The character of `string` under a point, or nil where there is no text.
    func textIndex(at point: CGPoint) -> Int? {
        guard let text = string as NSString?, let word = selectionForWord(at: point), word.numberOfTextRanges(on: self) > 0 else { return nil }
        let range = word.range(at: 0, on: self)
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= text.length else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for index in range.location..<min(NSMaxRange(range), range.location + 120) {
            guard let scalar = UnicodeScalar(text.character(at: index)), !CharacterSet.whitespacesAndNewlines.contains(scalar) else { continue }
            let bounds = textBounds(at: index)
            guard !bounds.isEmpty else { if best == nil { best = (index, .greatestFiniteMagnitude) }; continue }
            let dx = point.x < bounds.minX ? bounds.minX - point.x : point.x > bounds.maxX ? point.x - bounds.maxX : 0
            let dy = point.y < bounds.minY ? bounds.minY - point.y : point.y > bounds.maxY ? point.y - bounds.maxY : 0
            if best == nil || dx + dy < best!.distance { best = (index, dx + dy) }
        }
        return best?.index
    }
}

final class SyncedPDFView: PDFView {
    var onInverse: ((Int, Double, Double) -> Void)?
    var onResize: (() -> Void)?
    var onCommandClick: (() -> Void)?
    var onEscape: (() -> Void)?
    /// ⌘+ / ⌘− from the keyboard. (⌘-scroll and pinch land on PDFKit's inner views, so the pane catches those itself.)
    var onZoom: ((CGFloat, NSPoint?) -> Void)?
    /// Scroll-wheel ticks and trackpad swipes as a zoom factor; moving away from you zooms in, as in Word.
    static func zoomFactor(for event: NSEvent) -> CGFloat {
        var delta = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { delta = -delta }
        let factor = exp(delta * (event.hasPreciseScrollingDeltas ? 0.006 : 0.08))
        return min(1.6, max(1 / 1.6, factor))
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize); if changed { onResize?() }
    }
    override func layout() {
        super.layout()
        // The inner scroll view settles during layout; fit again once it has, then once more after the pass.
        onResize?(); DispatchQueue.main.async { [weak self] in self?.onResize?() }
    }
    override func zoomIn(_ sender: Any?) { if let onZoom { onZoom(1.25, nil) } else { super.zoomIn(sender) } }
    override func zoomOut(_ sender: Any?) { if let onZoom { onZoom(1 / 1.25, nil) } else { super.zoomOut(sender) } }
    /// Sets the scale while the page point under `anchor` stays under it.
    func setScale(_ scale: CGFloat, keeping anchor: NSPoint?) {
        guard let anchor, let page = page(for: anchor, nearest: true), let clip = documentView?.enclosingScrollView?.contentView else { scaleFactor = scale; return }
        let pagePoint = convert(anchor, to: page)
        scaleFactor = scale; layoutDocumentView()
        let moved = convert(pagePoint, from: page)
        let before = clip.convert(anchor, from: self), after = clip.convert(moved, from: self)
        var origin = clip.bounds.origin; origin.x += after.x - before.x; origin.y += after.y - before.y
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        documentView?.enclosingScrollView?.reflectScrolledClipView(clip)
    }
    override func cancelOperation(_ sender: Any?) { if let onEscape { onEscape() } else { super.cancelOperation(sender) } }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let location = convert(event.locationInWindow, from: nil)
            guard let page = page(for: location, nearest: true), let document else { return }
            onCommandClick?()
            let point = convert(location, to: page); let media = page.bounds(for: .mediaBox)
            onInverse?(document.index(for: page) + 1, point.x - media.minX, media.maxY - point.y)
        } else { super.mouseDown(with: event) }
    }
}

/// A thin indeterminate bar under the PDF header while a build is running.
final class BuildProgressBar: NSView {
    private let runner = CALayer()
    var animating = false { didSet { if animating != oldValue { update() } } }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = true; layer?.addSublayer(runner); isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); update() }
    private func update() {
        isHidden = !animating; runner.removeAllAnimations()
        guard animating, bounds.width > 0 else { return }
        runner.backgroundColor = Theme.accent.cgColor
        // With Reduce Motion on, a steady tinted line stands in for the moving one.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { runner.frame = bounds; runner.opacity = 0.6; return }
        let width = max(80, bounds.width * 0.3)
        runner.opacity = 1; runner.frame = NSRect(x: -width, y: 0, width: width, height: bounds.height)
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -width / 2; move.toValue = bounds.width + width / 2
        move.duration = 1.2; move.repeatCount = .infinity; move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        runner.add(move, forKey: "run")
    }
}

final class PDFPane: Surface {
    enum SyncState { case none, synced, building, failed }
    /// Fit width and fit page follow the pane as it resizes; manual keeps the user's zoom.
    enum ZoomMode: String { case fitWidth, fitPage, manual }
    let pdfView = SyncedPDFView()
    let header = PanelHeader("pdf", title: L10n.tr("PDF 预览"))
    let empty = NSStackView()
    let autoSwitch = NSSwitch()
    var onExport: (() -> Void)?
    var onReveal: (() -> Void)?
    var onAuto: ((Bool) -> Void)?
    var onReadingMode: ((Bool) -> Void)?
    private(set) var zoomMode = ZoomMode(rawValue: UserDefaults.standard.string(forKey: "pdf.zoomMode.v2") ?? "") ?? .fitWidth { didSet { updateFitButton() } }
    private var fitButton: ActionButton!
    /// Pages in rows: shown when zoomed out past two pages across, or for "show all pages".
    let grid = PDFPageGrid()
    private(set) var gridVisible = false
    private var gestureMonitor: Any?
    private var gridButton: ActionButton!
    private var applyingZoom = false
    private(set) var readingMode = false
    private var readingButton: ActionButton!
    private var revealButton: ActionButton!
    private var zoomChip: NSView!
    private let stateChip = Chip(fill: nil, radius: -1)
    private let stateIcon = NSImageView()
    private let stateSpinner = NSProgressIndicator()
    private let progressBar = BuildProgressBar()
    private var loadedData: Data?
    /// The step a running build is on, shown in the state chip.
    var stage: String? { didSet { if stage != oldValue { let current = state; state = current } } }
    private let stateLabel = Theme.label("", size: 11.5, weight: .semibold)
    private let autoLabel = Theme.label(L10n.tr("自动预览"), size: 12, color: Theme.muted)
    private let zoomLabel = Theme.label("100%", size: 12, weight: .medium)
    private let pageChip = Chip(fill: Theme.adaptive(0xFFFFFF, 0x3A3A3C, lightAlpha: 0.9, darkAlpha: 0.88), radius: -1, border: Theme.line)
    private let pageLabel = Theme.label("", size: 12, color: Theme.soft)
    private var highlights: [(annotation: PDFAnnotation, page: PDFPage)] = []
    /// Comparable text of each page of the loaded document, built on first use.
    private var pageStreams: [Int: TextStream] = [:]
    /// The text most recently marked by `reveal`, kept for tests and accessibility.
    private(set) var lastMark: (page: PDFPage, range: NSRange, caret: Int)?
    var state: SyncState = .none {
        didSet {
            let (color, symbol, text): (NSColor, String, String) = state == .building ? (Theme.orange, "arrow.triangle.2.circlepath", stage ?? L10n.tr("编译中")) : state == .failed ? (Theme.red, "exclamationmark", L10n.tr("编译失败")) : (Theme.green, "checkmark", L10n.tr("已同步"))
            stateChip.isHidden = state == .none; stateChip.fill = color.withAlphaComponent(0.16)
            stateIcon.image = Theme.symbol(symbol, size: 9, weight: .bold); stateIcon.contentTintColor = color
            stateLabel.stringValue = text; stateLabel.textColor = color
            let building = state == .building
            stateIcon.isHidden = building; stateSpinner.isHidden = !building; progressBar.animating = building
            if building { stateSpinner.startAnimation(nil) } else { stateSpinner.stopAnimation(nil) }
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame); fill = Theme.pdfBack; lineColor = Theme.line; trailingLine = true
        stateSpinner.style = .spinning; stateSpinner.controlSize = .mini; stateSpinner.isDisplayedWhenStopped = false; stateSpinner.size(12, 12)
        let stateRow = NSStackView(views: [stateIcon, stateSpinner, stateLabel]); stateRow.spacing = 4; stateRow.alignment = .centerY
        stateChip.size(nil, 22); stateChip.pinRow(stateRow, leading: 8, trailing: 8)
        stateChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        autoSwitch.controlSize = .mini; autoSwitch.state = .on; autoSwitch.target = self; autoSwitch.action = #selector(autoChanged)
        autoSwitch.toolTip = L10n.tr("停止输入后自动保存并编译"); autoSwitch.setAccessibilityLabel(L10n.tr("自动预览"))
        let zoomOut = ActionButton("", symbol: "minus") { [weak self] in self?.zoom(by: 1 / 1.2) }; zoomOut.toolTip = L10n.tr("缩小")
        let zoomIn = ActionButton("", symbol: "plus") { [weak self] in self?.zoom(by: 1.2) }; zoomIn.toolTip = L10n.tr("放大")
        zoomOut.contentTintColor = Theme.text; zoomIn.contentTintColor = Theme.text
        zoomLabel.alignment = .center; zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium); zoomLabel.size(44, nil)
        zoomLabel.toolTip = L10n.tr("缩放选项")
        zoomLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(showZoomMenu)))
        let zoomRow = NSStackView(views: [zoomOut, Theme.divider(height: 16), zoomLabel, Theme.divider(height: 16), zoomIn]); zoomRow.spacing = 0; zoomRow.alignment = .centerY
        let zoom = Chip(fill: Theme.fill, radius: 8); zoom.size(nil, 30); zoom.pin(zoomRow); zoomChip = zoom
        let export = ActionButton("", symbol: "arrow.down.to.line", style: .accentIcon) { [weak self] in self?.onExport?() }; export.toolTip = L10n.tr("导出 PDF…")
        let reveal = ActionButton("", symbol: "scope") { [weak self] in self?.onReveal?() }; reveal.toolTip = L10n.tr("在 PDF 中定位  ⇧⌘J")
        reveal.setAccessibilityLabel(L10n.tr("在 PDF 中定位")); revealButton = reveal
        readingButton = ActionButton("", symbol: "book") { [weak self] in guard let self else { return }; self.onReadingMode?(!self.readingMode) }
        readingButton.toolTip = L10n.tr("阅读模式  ⌥⌘R"); readingButton.setAccessibilityLabel(L10n.tr("阅读模式"))
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        fitButton = ActionButton("", symbol: "arrow.left.and.right.square") { [weak self] in self?.fitToPane() }
        fitButton.toolTip = L10n.tr("适合宽度"); fitButton.setAccessibilityLabel(L10n.tr("适合宽度")); updateFitButton()
        gridButton = ActionButton("", symbol: "square.grid.2x2") { [weak self] in guard let self else { return }; self.showAllPages(!self.gridVisible) }
        gridButton.setAccessibilityLabel(L10n.tr("显示所有页面")); updateGridButton()
        for view in [stateChip, spacer, autoLabel, autoSwitch, Theme.divider(), reveal, readingButton!, gridButton!, fitButton!, zoom, export] { header.addControl(view) }
        header.menuActions = [
            (L10n.tr("在 PDF 中定位"), "scope", { [weak self] in self?.onReveal?() }),
            (L10n.tr("适合宽度"), "arrow.left.and.right", { [weak self] in self?.setZoomMode(.fitWidth) }),
            (L10n.tr("适合整页"), "arrow.up.left.and.arrow.down.right", { [weak self] in self?.setZoomMode(.fitPage) }),
            (L10n.tr("阅读模式"), "book", { [weak self] in guard let self else { return }; self.onReadingMode?(!self.readingMode) }),
            (L10n.tr("显示所有页面"), "square.grid.2x2", { [weak self] in guard let self else { return }; self.showAllPages(!self.gridVisible) }),
            (L10n.tr("导出 PDF…"), "arrow.down.to.line", { [weak self] in self?.onExport?() })
        ]
        pdfView.onResize = { [weak self] in self?.applyZoom() }
        pdfView.onZoom = { [weak self] factor, anchor in self?.userZoom(factor, anchor: anchor) }
        grid.onOpenPage = { [weak self] in self?.leaveGrid(at: $0) }
        grid.onEscape = { [weak self] in guard let self else { return }; self.leaveGrid(at: self.grid.currentPage) }
        // Jumping to the source needs the editor, so it ends reading mode.
        pdfView.onCommandClick = { [weak self] in guard let self, self.readingMode else { return }; self.onReadingMode?(false) }
        pdfView.onEscape = { [weak self] in guard let self, self.readingMode else { return }; self.onReadingMode?(false) }
        state = .none

        pdfView.autoScales = false; pdfView.displayMode = .singlePageContinuous; pdfView.displaysPageBreaks = true; pdfView.pageBreakMargins = NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)
        pdfView.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        pdfView.setContentCompressionResistancePriority(.init(1), for: .vertical)
        empty.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        pdfView.backgroundColor = Theme.pdfBack; pdfView.minScaleFactor = 0.2; pdfView.maxScaleFactor = 5
        // Page drop shadows are blurred by the window server on every scrolled frame; a flat page keeps scrolling smooth.
        pdfView.pageShadowsEnabled = false
        let tile = Chip(fill: Theme.fill, radius: 16); tile.size(56, 56)
        let icon = NSImageView(image: Theme.symbol("doc.richtext", size: 24, weight: .regular)!); icon.contentTintColor = Theme.muted
        icon.translatesAutoresizingMaskIntoConstraints = false; tile.addSubview(icon)
        NSLayoutConstraint.activate([icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor), icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor)])
        empty.orientation = .vertical; empty.spacing = 6; empty.alignment = .centerX
        empty.addArrangedSubview(tile); empty.setCustomSpacing(14, after: tile)
        empty.addArrangedSubview(Theme.label(L10n.tr("尚无 PDF"), size: 20, weight: .bold))
        empty.addArrangedSubview(Theme.label(L10n.tr("编译后，PDF 会在这里实时呈现"), size: 13, color: Theme.muted))
        let shortcuts = Theme.label(L10n.tr("⌘↩ 编译  ·  ⌘ 点击双向定位"), size: 11.5, color: Theme.muted)
        empty.setCustomSpacing(12, after: empty.arrangedSubviews.last!); empty.addArrangedSubview(shortcuts)
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        pageChip.size(nil, 26); pageChip.pinRow(pageLabel, leading: 12, trailing: 12); pageChip.isHidden = true
        grid.isHidden = true
        for view in [header, pdfView, grid, empty, pageChip, progressBar] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1), header.heightAnchor.constraint(equalToConstant: 46),
            pdfView.topAnchor.constraint(equalTo: header.bottomAnchor), pdfView.leadingAnchor.constraint(equalTo: leadingAnchor), pdfView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1), pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.topAnchor.constraint(equalTo: header.bottomAnchor), grid.leadingAnchor.constraint(equalTo: leadingAnchor), grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1), grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor), empty.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 23),
            progressBar.topAnchor.constraint(equalTo: header.bottomAnchor), progressBar.leadingAnchor.constraint(equalTo: leadingAnchor), progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1), progressBar.heightAnchor.constraint(equalToConstant: 2),
            pageChip.centerXAnchor.constraint(equalTo: centerXAnchor), pageChip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: pdfView)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); pdfView.backgroundColor = Theme.pdfBack }
    override func layout() {
        fitHeader()
        super.layout()
    }
    /// Drops secondary header controls, least important first, until the row fits. A row wider than the pane
    /// would stretch the pane's content past its edge, and the PDF would then fit a width nobody sees.
    private func fitHeader() {
        let optional: [NSView] = [autoLabel, stateChip, autoSwitch, revealButton, readingButton, gridButton, fitButton, zoomChip]
        for view in optional { view.isHidden = view === stateChip && state == .none }
        let available = bounds.width - 1 - 24
        var index = 0
        while index < optional.count, header.row.fittingSize.width > available {
            optional[index].isHidden = true; index += 1
        }
    }
    @objc private func autoChanged() { onAuto?(autoSwitch.state == .on) }
    @objc private func showZoomMenu() {
        let menu = NSMenu()
        for (title, mode) in [(L10n.tr("适合宽度"), ZoomMode.fitWidth), (L10n.tr("适合整页"), .fitPage)] {
            let item = ClosureMenuItem(title, symbol: mode == .fitWidth ? "arrow.left.and.right" : "arrow.up.left.and.arrow.down.right") { [weak self] in self?.setZoomMode(mode) }
            item.state = zoomMode == mode ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator())
        for percent in [50, 75, 100, 125, 150, 200] {
            menu.addItem(ClosureMenuItem("\(percent)%", symbol: nil) { [weak self] in self?.setManualScale(CGFloat(percent) / 100) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: zoomLabel.bounds.height + 6), in: zoomLabel)
    }
    /// Lit while the pages follow the pane: its width normally, whole pages in reading mode.
    private func updateFitButton() {
        guard let fitButton else { return }
        let on = readingMode ? zoomMode == .fitPage : zoomMode == .fitWidth
        let symbol = readingMode ? "arrow.up.left.and.arrow.down.right.square" : "arrow.left.and.right.square"
        let title = readingMode ? L10n.tr("适合整页") : L10n.tr("适合宽度")
        fitButton.contentTintColor = on ? Theme.accent : Theme.muted
        fitButton.image = Theme.symbol(on ? symbol + ".fill" : symbol, size: 15, weight: .medium, description: title)
        fitButton.toolTip = title; fitButton.setAccessibilityLabel(title); fitButton.setAccessibilityValue(on)
    }
    /// The fit button: whole pages in reading mode, the pane's width otherwise.
    func fitToPane() {
        if gridVisible { leaveGrid(at: grid.currentPage); return }
        if readingMode { zoomMode = .fitPage; applyZoom() } else { setZoomMode(.fitWidth) }
    }
    func setZoomMode(_ mode: ZoomMode) {
        // Reading mode keeps its own fit; only the normal view's choice is remembered.
        zoomMode = mode; if !readingMode { UserDefaults.standard.set(mode.rawValue, forKey: "pdf.zoomMode.v2") }; applyZoom()
    }
    private func zoom(by factor: CGFloat) { userZoom(factor, anchor: nil) }
    private func setManualScale(_ scale: CGFloat) {
        if gridVisible { leaveGrid(at: grid.currentPage) }
        applyUserScale(scale, anchor: nil)
    }

    // MARK: Zoom and page layout

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let gestureMonitor { NSEvent.removeMonitor(gestureMonitor); self.gestureMonitor = nil }
        guard window != nil else { return }
        // Scroll and pinch events go to PDFKit's page and scroll views, which use them up; catch them first.
        gestureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleZoomGesture(event, at: event.locationInWindow) ? nil : event
        }
    }
    deinit { if let gestureMonitor { NSEvent.removeMonitor(gestureMonitor) } }
    /// ⌘-scroll or a pinch over the pages zooms; returns whether the event was used.
    func handleZoomGesture(_ event: NSEvent, at windowPoint: NSPoint) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, pdfView.document != nil else { return false }
        let target: NSView = gridVisible ? grid : pdfView
        guard target.bounds.contains(target.convert(windowPoint, from: nil)) else { return false }
        let anchor = gridVisible ? nil : pdfView.convert(windowPoint, from: nil)
        switch event.type {
        case .scrollWheel:
            guard event.modifierFlags.contains(.command) else { return false }
            userZoom(SyncedPDFView.zoomFactor(for: event), anchor: anchor)
        case .magnify:
            userZoom(1 + event.magnification, anchor: anchor)
        default: return false
        }
        return true
    }

    /// Width of the first page at 100 %, the yardstick for how many pages fit across.
    private var basePageWidth: CGFloat {
        guard let page = pdfView.document?.page(at: 0) else { return 612 }
        let size = page.bounds(for: .cropBox).size
        return max(1, page.rotation % 180 != 0 ? size.height : size.width)
    }
    private var viewportWidth: CGFloat { gridVisible ? grid.bounds.width : pdfView.bounds.width }
    private var currentPageIndex: Int { pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) } ?? 0 }
    private func markManual() {
        zoomMode = .manual
        if !readingMode { UserDefaults.standard.set(ZoomMode.manual.rawValue, forKey: "pdf.zoomMode.v2") }
    }
    /// ⌘-scroll, pinch, ⌘+ / ⌘− and the zoom buttons all come here.
    func userZoom(_ factor: CGFloat, anchor: NSPoint?) {
        guard pdfView.document != nil, factor.isFinite, factor > 0 else { return }
        if gridVisible { setGridPageWidth(grid.pageWidth * factor); return }
        applyUserScale(pdfView.scaleFactor * factor, anchor: anchor)
    }
    /// Like a word processor: one page across while it fills the width, two side by side once both fit,
    /// and a grid of pages once three or more fit.
    private func applyUserScale(_ requested: CGFloat, anchor: NSPoint?) {
        guard pdfView.document != nil else { return }
        let scale = max(0.05, min(pdfView.maxScaleFactor, requested))
        markManual()
        let columns = PDFPageGrid.columns(pageWidth: basePageWidth * scale, in: viewportWidth)
        if columns >= 3 { showGrid(pageWidth: basePageWidth * scale, focus: currentPageIndex); return }
        // Reading mode turns pages like a book; elsewhere pages scroll as one strip.
        let mode: PDFDisplayMode = columns == 2 ? (readingMode ? .twoUp : .twoUpContinuous) : (readingMode ? .singlePage : .singlePageContinuous)
        let shown = max(pdfView.minScaleFactor, scale)
        if pdfView.displayMode != mode {
            let page = pdfView.currentPage
            pdfView.displayMode = mode; pdfView.layoutDocumentView(); pdfView.scaleFactor = shown
            if let page { pdfView.go(to: page) }
        } else {
            pdfView.setScale(shown, keeping: anchor)
        }
    }
    private func setGridPageWidth(_ requested: CGFloat) {
        let width = max(60, min(2000, requested))
        if PDFPageGrid.columns(pageWidth: width, in: viewportWidth) <= 2 {
            // Zoomed back in far enough: hand over to the PDF view at the same size, on the same page.
            let page = grid.firstVisiblePage
            hideGrid()
            if let target = pdfView.document?.page(at: page) { pdfView.go(to: target) }
            applyUserScale(width / basePageWidth, anchor: nil)
            return
        }
        grid.pageWidth = width; updateZoomLabel()
    }
    private func showGrid(pageWidth: CGFloat, focus: Int) {
        if grid.document !== pdfView.document { grid.document = pdfView.document }
        grid.pageWidth = pageWidth; grid.currentPage = focus
        if !gridVisible {
            gridVisible = true; grid.isHidden = false; pdfView.isHidden = true; pageChip.isHidden = true
            grid.scrollToPage(focus); window?.makeFirstResponder(grid)
        }
        updateGridButton(); updateZoomLabel()
    }
    private func hideGrid() {
        guard gridVisible else { return }
        gridVisible = false; grid.isHidden = true; pdfView.isHidden = false; pageChip.isHidden = pdfView.document == nil; updateGridButton()
    }
    /// Every page at once, as large as still fits the pane.
    func showAllPages(_ on: Bool) {
        guard let document = pdfView.document, document.pageCount > 0 else { return }
        guard on else { leaveGrid(at: grid.currentPage); return }
        let first = document.page(at: 0)!.bounds(for: .cropBox).size
        let aspect = first.width > 0 ? first.height / first.width : 1.294
        let size = gridVisible ? grid.bounds.size : pdfView.bounds.size
        markManual()
        showGrid(pageWidth: PDFPageGrid.widthShowingAll(count: document.pageCount, aspect: aspect, in: size), focus: currentPageIndex)
    }
    /// Leaves the grid onto `index`, fitted to the width (facing pages in reading mode).
    func leaveGrid(at index: Int) {
        hideGrid()
        if readingMode { zoomMode = .fitPage } else { pdfView.displayMode = .singlePageContinuous; setZoomMode(.fitWidth) }
        pdfView.layoutDocumentView(); applyZoom()
        if let page = pdfView.document?.page(at: index) { pdfView.go(to: page) }
        window?.makeFirstResponder(pdfView); pageChanged(); updateZoomLabel()
    }
    private func updateGridButton() {
        guard let gridButton else { return }
        gridButton.contentTintColor = gridVisible ? Theme.accent : Theme.muted
        gridButton.image = Theme.symbol(gridVisible ? "square.grid.2x2.fill" : "square.grid.2x2", size: 15, weight: .medium, description: L10n.tr("显示所有页面"))
        gridButton.toolTip = gridVisible ? L10n.tr("返回单页  Esc") : L10n.tr("显示所有页面")
        gridButton.setAccessibilityValue(gridVisible)
    }
    private func updateZoomLabel() {
        let scale = gridVisible ? grid.pageWidth / basePageWidth : pdfView.scaleFactor
        zoomLabel.stringValue = "\(Int((scale * 100).rounded()))%"
    }
    /// Scales the page to the pane's width (or whole page) for the fitting modes.
    func applyZoom() {
        guard !gridVisible, zoomMode != .manual else { return }
        if readingMode, zoomMode == .fitPage {
            let mode = readingDisplayMode()
            if pdfView.displayMode != mode {
                let page = pdfView.currentPage
                pdfView.displayMode = mode; pdfView.layoutDocumentView()
                if let page { pdfView.go(to: page) }
            }
        }
        guard let scale = fittingScale(), abs(scale - pdfView.scaleFactor) > 0.001 else { return }
        applyingZoom = true; pdfView.scaleFactor = scale; applyingZoom = false
    }
    private func fittingScale() -> CGFloat? {
        guard let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return nil }
        var box = page.bounds(for: pdfView.displayBox).size
        if page.rotation % 180 != 0 { box = NSSize(width: box.height, height: box.width) }
        guard box.width > 0, box.height > 0 else { return nil }
        // The view's own size, not its inner scroll view's, which may not have caught up with a resize yet.
        var viewport = pdfView.bounds.size
        viewport.height -= readingInsets.top + readingInsets.bottom
        if NSScroller.preferredScrollerStyle == .legacy { viewport.width -= NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) }
        guard viewport.width > 20, viewport.height > 20 else { return nil }
        // Page-break margins grow with the zoom, so they count as part of the page.
        let margins = pdfView.pageBreakMargins
        let columns: CGFloat = pdfView.displayMode == .twoUp || pdfView.displayMode == .twoUpContinuous ? 2 : 1
        let width = (viewport.width - 2) / ((box.width + margins.left + margins.right) * columns)
        let height = viewport.height / (box.height + margins.top + margins.bottom)
        let scale = zoomMode == .fitPage ? min(width, height) : width
        guard scale.isFinite, scale > 0 else { return nil }
        return max(pdfView.minScaleFactor, min(pdfView.maxScaleFactor, scale))
    }
    /// Reading mode shows facing pages fitted to the width; the workspace hides the other panes.
    /// Facing pages when two whole pages fit side by side at nearly the size a single one would get
    /// (a wide window); one whole page otherwise (a tall or narrow one).
    private func readingDisplayMode() -> PDFDisplayMode {
        guard let document = pdfView.document, let page = document.page(at: 0) else { return .singlePage }
        var size = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { size = NSSize(width: size.height, height: size.width) }
        let margins = pdfView.pageBreakMargins
        let viewport = NSSize(width: pdfView.bounds.width, height: pdfView.bounds.height - readingInsets.top - readingInsets.bottom)
        guard size.width > 0, size.height > 0, viewport.width > 0, viewport.height > 0 else { return .singlePage }
        let height = viewport.height / (size.height + margins.top + margins.bottom)
        let one = min(viewport.width / (size.width + margins.left + margins.right), height)
        let two = min(viewport.width / (2 * (size.width + margins.left + margins.right)), height)
        return document.pageCount > 1 && two >= one * 0.8 ? .twoUp : .singlePage
    }
    /// Room above the pages and below them (for the page counter) while reading.
    private var readingInsets: NSEdgeInsets { readingMode ? NSEdgeInsets(top: 22, left: 0, bottom: 52, right: 0) : NSEdgeInsets() }
    func setReadingMode(_ on: Bool) {
        hideGrid()
        readingMode = on
        if let scroll = pdfView.documentView?.enclosingScrollView {
            scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = readingInsets
        }
        readingButton.image = Theme.symbol(on ? "book.fill" : "book", size: 15, weight: .medium, description: L10n.tr("阅读模式"))
        readingButton.contentTintColor = on ? Theme.accent : Theme.muted
        readingButton.toolTip = on ? L10n.tr("退出阅读模式  Esc") : L10n.tr("阅读模式  ⌥⌘R")
        let page = pdfView.currentPage
        // Whole pages turned like a book, with a shadow to lift them off the background. Leaving restores
        // the scrolling strip and the zoom the user had.
        pdfView.displaysAsBook = false; pdfView.pageShadowsEnabled = on
        pdfView.displayMode = on ? readingDisplayMode() : .singlePageContinuous
        if on { zoomMode = .fitPage } else { zoomMode = ZoomMode(rawValue: UserDefaults.standard.string(forKey: "pdf.zoomMode.v2") ?? "") ?? .fitWidth }
        pdfView.layoutDocumentView(); applyZoom()
        if let page { pdfView.go(to: page) }
        if on { window?.makeFirstResponder(pdfView) }
    }
    @objc private func scaleChanged() { if !gridVisible { updateZoomLabel() } }
    func load(_ url: URL) {
        // Read bytes so PDFKit cannot keep a mapped file alive while TeX rewrites it.
        guard let data = try? Data(contentsOf: url) else { return }
        // An unchanged PDF keeps its rendered pages; replacing the document would only make it blink.
        if data == loadedData, pdfView.document != nil { return }
        guard let document = PDFDocument(data: data) else { return }
        loadedData = data
        let oldPage = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) } ?? 0
        let oldDestination = pdfView.currentDestination
        let scale = pdfView.scaleFactor
        applyingZoom = true; pdfView.document = document; applyingZoom = false; empty.isHidden = true
        highlights = []; pageStreams = [:]
        if let page = document.page(at: min(oldPage, max(0, document.pageCount - 1))) {
            if let destination = oldDestination { pdfView.go(to: PDFDestination(page: page, at: destination.point)) }
            else { pdfView.go(to: page) }
        }
        if zoomMode == .manual { pdfView.scaleFactor = scale } else { applyZoom() }
        if gridVisible { grid.document = document; grid.currentPage = min(grid.currentPage, max(0, document.pageCount - 1)) }
        pageChanged(); scaleChanged()
    }
    func clear() { hideGrid(); grid.document = nil; pageStreams = [:]; highlights = []; loadedData = nil; pdfView.document = nil; empty.isHidden = false; pageChip.isHidden = true; state = .none }
    @objc func pageChanged() {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return }
        pageLabel.stringValue = L10n.tr("第 \(doc.index(for: page) + 1) 页，共 \(doc.pageCount) 页"); pageChip.isHidden = gridVisible
        if !gridVisible { grid.currentPage = doc.index(for: page) }
    }
    // MARK: Source ↔ PDF

    func pageStream(_ index: Int) -> TextStream? {
        if let stream = pageStreams[index] { return stream }
        guard let text = pdfView.document?.page(at: index)?.string else { return nil }
        let stream = TextSync.pdfStream(text); pageStreams[index] = stream; return stream
    }

    /// Finds the source position `cursor` (an index into `source`) on the page and marks the sentence
    /// `sentence` around it. SyncTeX boxes for the source line say where to look first.
    /// Returns the 1-based page, or nil when the text could not be found.
    func reveal(source: TextStream, cursor: Int, sentence: ClosedRange<Int>?, boxes: [SyncBox]) -> Int? {
        // A jump needs the page itself, not the grid.
        if gridVisible { leaveGrid(at: grid.currentPage) }
        guard let document = pdfView.document, document.pageCount > 0 else { return nil }
        let hintPages = Array(Set(boxes.map { $0.page - 1 })).filter { $0 >= 0 && $0 < document.pageCount }.sorted()
        func penalty(page index: Int) -> (Int) -> Double {
            guard let page = document.page(at: index), let stream = pageStream(index) else { return { _ in 100 } }
            let onPage = boxes.filter { $0.page - 1 == index }
            guard !onPage.isEmpty else {
                // No box here: prefer pages close to the ones SyncTeX named.
                let distance = hintPages.map { abs($0 - index) }.min() ?? 0
                return { _ in hintPages.isEmpty ? 0 : 2 + Double(distance) }
            }
            let media = page.bounds(for: .mediaBox)
            return { target in
                let rect = page.textBounds(at: stream.offset(at: target))
                let gaps = onPage.map { box -> Double in
                    let bottom = Double(media.maxY) - box.v - 3, top = Double(media.maxY) - box.v + max(box.height, 8)
                    let y = Double(rect.midY)
                    return y < bottom ? bottom - y : y > top ? y - top : 0
                }
                return (gaps.min() ?? 0) / 120
            }
        }
        func search(_ pages: [Int]) -> (page: Int, match: TextMatch, score: Double)? {
            var best: (page: Int, match: TextMatch, score: Double)?
            for index in pages {
                guard let stream = pageStream(index) else { continue }
                let rank = penalty(page: index)
                guard let match = TextSync.correspond(cursor, from: source, to: stream, penalty: rank) else { continue }
                let score = match.score(penalty: rank(match.index))
                if best == nil || score > best!.score { best = (index, match, score) }
            }
            return best
        }
        guard let found = search(hintPages) ?? search(Array(0..<document.pageCount)),
              let page = document.page(at: found.page), let stream = pageStream(found.page) else { return nil }
        let caret = stream.offset(at: found.match.index)
        var range = NSRange(location: caret, length: 1)
        if let sentence {
            // Each end is placed on its own, close to where the cursor landed.
            let near: (Int) -> Double = { Double(abs($0 - found.match.index)) / 80 }
            let first = TextSync.correspond(sentence.lowerBound, from: source, to: stream, penalty: near)?.index
            let last = TextSync.correspond(sentence.upperBound, from: source, to: stream, penalty: near)?.index
            if let first, let last, first <= found.match.index, last >= found.match.index, last - first < 1500 {
                let start = stream.offset(at: first); var end = stream.offset(at: last) + 1
                // Take in the closing punctuation, which the comparable text leaves out.
                if let text = page.string as NSString? {
                    while end < text.length, let scalar = UnicodeScalar(text.character(at: end)), ".?!。？！；)\"”’".unicodeScalars.contains(scalar) { end += 1 }
                }
                range = NSRange(location: start, length: end - start)
            }
        }
        mark(page: page, range: range, caret: caret)
        return found.page + 1
    }

    /// The text position under a point of a page, as an index into that page's stream.
    func textPosition(page index: Int, point: CGPoint) -> (stream: TextStream, index: Int, word: String)? {
        guard let page = pdfView.document?.page(at: index), let stream = pageStream(index), stream.count > 0 else { return nil }
        var hit = page.textIndex(at: point)
        if hit == nil {
            // A click between words or lines: take the nearest character within a few points.
            search: for radius in [3.0, 6.0, 10.0, 15.0] {
                for (dx, dy) in [(radius, 0.0), (-radius, 0), (0, radius), (0, -radius), (radius, radius), (-radius, radius), (radius, -radius), (-radius, -radius)] {
                    hit = page.textIndex(at: CGPoint(x: point.x + dx, y: point.y + dy))
                    if hit != nil { break search }
                }
            }
        }
        guard let character = hit else { return nil }
        let text = page.string ?? ""
        let word = TextSync.wordRange(in: text, at: character).map { (text as NSString).substring(with: $0) } ?? ""
        return (stream, min(stream.index(atOrAfter: character), stream.count - 1), word)
    }

    private func clearHighlights() {
        for (annotation, page) in highlights { page.removeAnnotation(annotation) }
        highlights = []
    }
    /// Shows the marks, holds them, then fades them out.
    @_optimize(none)
    private func flash(_ annotations: [(SyncMarkAnnotation, PDFPage)], for seconds: Double) {
        for (annotation, page) in annotations { page.addAnnotation(annotation) }
        highlights = annotations.map { (annotation: $0.0, page: $0.1) }
        let ids = annotations.map { ObjectIdentifier($0.0) }
        let pages = Array(Set(annotations.map { ObjectIdentifier($0.1) })).compactMap { id in annotations.first { ObjectIdentifier($0.1) == id }?.1 }
        let steps = 12
        for step in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + Double(step) * 0.03) { [weak self] in
                guard let self, self.highlights.contains(where: { ids.contains(ObjectIdentifier($0.annotation)) }) else { return }
                if step == steps {
                    for (annotation, page) in annotations { page.removeAnnotation(annotation) }
                    self.highlights.removeAll { ids.contains(ObjectIdentifier($0.annotation)) }
                } else {
                    let fade = 1 - CGFloat(step) / CGFloat(steps)
                    for (annotation, _) in annotations { annotation.fade = fade * fade }
                    for page in pages { self.pdfView.annotationsChanged(on: page) }
                }
            }
        }
    }

    /// One rounded mark per text line of `range`.
    @_optimize(none)
    private func marks(on page: PDFPage, range: NSRange, strength: CGFloat, inset: CGSize) -> [(SyncMarkAnnotation, PDFPage)] {
        guard let selection = page.selection(for: range) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            let bounds = line.bounds(for: page).insetBy(dx: inset.width, dy: inset.height)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            return (SyncMarkAnnotation(bounds: bounds, strength: strength), page)
        }
    }

    // Swift 6.4's constant-propagation pass crashes on this PDFKit annotation bridge.
    // Limit the workaround to these infrequent UI actions; keep the app optimized.
    @_optimize(none)
    private func mark(page: PDFPage, range: NSRange, caret: Int) {
        clearHighlights()
        lastMark = (page, range, caret)
        var annotations = marks(on: page, range: range, strength: Theme.syncSentenceAlpha, inset: CGSize(width: -2, height: -1))
        // The word under the caret gets its own, firmer pill inside the sentence.
        let word = TextSync.wordRange(in: page.string ?? "", at: caret) ?? NSRange(location: caret, length: 1)
        let wordMarks = marks(on: page, range: word, strength: Theme.syncWordAlpha, inset: CGSize(width: -1.5, height: -1))
        annotations += wordMarks
        flash(annotations, for: 2.4)
        let focus = wordMarks.first?.0.bounds ?? annotations.first?.0.bounds ?? page.textBounds(at: caret)
        pdfView.go(to: focus.insetBy(dx: -60, dy: -90), on: page)
    }

    /// Marks the boxes SyncTeX gives for a line, so a fallback jump still shows the column and horizontal
    /// extent of the line instead of a bar across the whole page.
    @_optimize(none)
    func goTo(boxes: [SyncBox]) {
        guard let first = boxes.first else { return }
        if gridVisible { leaveGrid(at: first.page - 1) }
        guard let page = pdfView.document?.page(at: first.page - 1) else { return }
        let media = page.bounds(for: .mediaBox)
        let rects = boxes.filter { $0.page == first.page && $0.width > 1 }.map { box in
            CGRect(x: media.minX + box.h - 2, y: media.maxY - box.v - 3, width: box.width + 4, height: max(box.height, 8) + 4)
        }.filter { media.intersects($0) }
        guard let lead = rects.first else { goTo(first.location); return }
        clearHighlights()
        flash(rects.map { (SyncMarkAnnotation(bounds: $0, strength: Theme.syncSentenceAlpha * 1.4), page) }, for: 1.8)
        pdfView.go(to: CGRect(x: lead.minX, y: lead.minY, width: min(lead.width, 240), height: lead.height).insetBy(dx: -40, dy: -60), on: page)
    }

    @_optimize(none)
    func goTo(_ location: PDFLocation) {
        if gridVisible { leaveGrid(at: location.page - 1) }
        guard let page = pdfView.document?.page(at: location.page - 1) else { return }
        clearHighlights()
        let media = page.bounds(for: .mediaBox)
        let point = location.point(mediaHeight: media.height, originX: media.minX, originY: media.minY)
        pdfView.go(to: CGRect(x: max(media.minX, point.x - 15), y: point.y - 35, width: 240, height: 70), on: page)
        flash([(SyncMarkAnnotation(bounds: CGRect(x: media.minX + 24, y: point.y - 5, width: media.width - 48, height: 16), strength: Theme.syncSentenceAlpha * 1.4), page)], for: 1.8)
    }
}
