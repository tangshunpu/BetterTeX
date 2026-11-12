import AppKit
import PDFKit
import BetterTeXCore

final class SyncedPDFView: PDFView {
    var onInverse: ((Int, Double, Double) -> Void)?
    var onResize: (() -> Void)?
    var onCommandClick: (() -> Void)?
    var onEscape: (() -> Void)?
    /// A pinch or ⌘+ / ⌘− — the only scale changes that count as the user choosing a zoom.
    var onUserZoom: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize); if changed { onResize?() }
    }
    override func layout() {
        super.layout()
        // The inner scroll view settles during layout; fit again once it has, then once more after the pass.
        onResize?(); DispatchQueue.main.async { [weak self] in self?.onResize?() }
    }
    override func magnify(with event: NSEvent) { onUserZoom?(); super.magnify(with: event) }
    override func zoomIn(_ sender: Any?) { onUserZoom?(); super.zoomIn(sender) }
    override func zoomOut(_ sender: Any?) { onUserZoom?(); super.zoomOut(sender) }
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
    private var highlightAnnotation: PDFAnnotation?
    private var highlightPage: PDFPage?
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
        fitButton = ActionButton("", symbol: "arrow.left.and.right.square") { [weak self] in self?.setZoomMode(.fitWidth) }
        fitButton.toolTip = L10n.tr("适合宽度"); fitButton.setAccessibilityLabel(L10n.tr("适合宽度")); updateFitButton()
        for view in [stateChip, spacer, autoLabel, autoSwitch, Theme.divider(), reveal, readingButton!, fitButton!, zoom, export] { header.addControl(view) }
        header.menuActions = [
            (L10n.tr("在 PDF 中定位"), "scope", { [weak self] in self?.onReveal?() }),
            (L10n.tr("适合宽度"), "arrow.left.and.right", { [weak self] in self?.setZoomMode(.fitWidth) }),
            (L10n.tr("适合整页"), "arrow.up.left.and.arrow.down.right", { [weak self] in self?.setZoomMode(.fitPage) }),
            (L10n.tr("阅读模式"), "book", { [weak self] in guard let self else { return }; self.onReadingMode?(!self.readingMode) }),
            (L10n.tr("导出 PDF…"), "arrow.down.to.line", { [weak self] in self?.onExport?() })
        ]
        pdfView.onResize = { [weak self] in self?.applyZoom() }
        pdfView.onUserZoom = { [weak self] in guard let self, self.zoomMode != .manual else { return }; self.zoomMode = .manual; if !self.readingMode { UserDefaults.standard.set(ZoomMode.manual.rawValue, forKey: "pdf.zoomMode.v2") } }
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
        for view in [header, pdfView, empty, pageChip, progressBar] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1), header.heightAnchor.constraint(equalToConstant: 46),
            pdfView.topAnchor.constraint(equalTo: header.bottomAnchor), pdfView.leadingAnchor.constraint(equalTo: leadingAnchor), pdfView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1), pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        // Shed secondary header items as the pane narrows.
        autoLabel.isHidden = bounds.width < 430
        stateChip.isHidden = state == .none || bounds.width < 360
        autoSwitch.isHidden = bounds.width < 300
        revealButton.isHidden = bounds.width < 260
        readingButton.isHidden = bounds.width < 230
        fitButton.isHidden = bounds.width < 250
        zoomChip.isHidden = bounds.width < 200
        super.layout()
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
    /// Lit while the page follows the pane's width.
    private func updateFitButton() {
        guard let fitButton else { return }
        let on = zoomMode == .fitWidth
        fitButton.contentTintColor = on ? Theme.accent : Theme.muted
        fitButton.image = Theme.symbol(on ? "arrow.left.and.right.square.fill" : "arrow.left.and.right.square", size: 15, weight: .medium, description: L10n.tr("适合宽度"))
        fitButton.setAccessibilityValue(on)
    }
    func setZoomMode(_ mode: ZoomMode) {
        zoomMode = mode; UserDefaults.standard.set(mode.rawValue, forKey: "pdf.zoomMode.v2"); applyZoom()
    }
    private func zoom(by factor: CGFloat) { setManualScale(pdfView.scaleFactor * factor) }
    private func setManualScale(_ scale: CGFloat) {
        setZoomMode(.manual); pdfView.scaleFactor = max(pdfView.minScaleFactor, min(pdfView.maxScaleFactor, scale))
    }
    /// Scales the page to the pane's width (or whole page) for the fitting modes.
    func applyZoom() {
        guard zoomMode != .manual, let scale = fittingScale(), abs(scale - pdfView.scaleFactor) > 0.001 else { return }
        applyingZoom = true; pdfView.scaleFactor = scale; applyingZoom = false
    }
    private func fittingScale() -> CGFloat? {
        guard let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return nil }
        var box = page.bounds(for: pdfView.displayBox).size
        if page.rotation % 180 != 0 { box = NSSize(width: box.height, height: box.width) }
        guard box.width > 0, box.height > 0 else { return nil }
        // The view's own size, not its inner scroll view's, which may not have caught up with a resize yet.
        var viewport = pdfView.bounds.size
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
    func setReadingMode(_ on: Bool) {
        readingMode = on
        readingButton.image = Theme.symbol(on ? "book.fill" : "book", size: 15, weight: .medium, description: L10n.tr("阅读模式"))
        readingButton.contentTintColor = on ? Theme.accent : Theme.muted
        readingButton.toolTip = on ? L10n.tr("退出阅读模式  Esc") : L10n.tr("阅读模式  ⌥⌘R")
        let page = pdfView.currentPage
        pdfView.displayMode = on ? .twoUpContinuous : .singlePageContinuous
        pdfView.displaysAsBook = false
        if on { zoomMode = .fitWidth } else { zoomMode = ZoomMode(rawValue: UserDefaults.standard.string(forKey: "pdf.zoomMode.v2") ?? "") ?? .fitWidth }
        pdfView.layoutDocumentView(); applyZoom()
        if let page { pdfView.go(to: page) }
        if on { window?.makeFirstResponder(pdfView) }
    }
    @objc private func scaleChanged() {
        zoomLabel.stringValue = "\(Int((pdfView.scaleFactor * 100).rounded()))%"
    }
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
        highlightAnnotation = nil; highlightPage = nil
        if let page = document.page(at: min(oldPage, max(0, document.pageCount - 1))) {
            if let destination = oldDestination { pdfView.go(to: PDFDestination(page: page, at: destination.point)) }
            else { pdfView.go(to: page) }
        }
        if zoomMode == .manual { pdfView.scaleFactor = scale } else { applyZoom() }
        pageChanged(); scaleChanged()
    }
    func clear() { loadedData = nil; pdfView.document = nil; empty.isHidden = false; pageChip.isHidden = true; state = .none }
    @objc func pageChanged() {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return }
        pageLabel.stringValue = L10n.tr("第 \(doc.index(for: page) + 1) 页，共 \(doc.pageCount) 页"); pageChip.isHidden = false
    }
    // Swift 6.4's constant-propagation pass crashes on this PDFKit annotation bridge.
    // Limit the workaround to this infrequent UI action; keep the app optimized.
    @_optimize(none)
    func goTo(_ location: PDFLocation) {
        guard let page = pdfView.document?.page(at: location.page - 1) else { return }
        if let annotation = highlightAnnotation { highlightPage?.removeAnnotation(annotation) }
        let media = page.bounds(for: .mediaBox)
        let point = location.point(mediaHeight: media.height, originX: media.minX, originY: media.minY)
        pdfView.go(to: CGRect(x: max(media.minX, point.x - 15), y: point.y - 35, width: 240, height: 70), on: page)
        let annotation = PDFAnnotation(bounds: CGRect(x: media.minX + 24, y: point.y - 5, width: media.width - 48, height: 16), forType: .square, withProperties: nil)
        annotation.color = .clear; annotation.interiorColor = Theme.accent.withAlphaComponent(0.18)
        page.addAnnotation(annotation); highlightAnnotation = annotation; highlightPage = page
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak page, weak annotation] in if let annotation { page?.removeAnnotation(annotation) } }
    }
}
