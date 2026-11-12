import AppKit
import PDFKit
import BetterTeXCore

final class SyncedPDFView: PDFView {
    var onInverse: ((Int, Double, Double) -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let location = convert(event.locationInWindow, from: nil)
            guard let page = page(for: location, nearest: true), let document else { return }
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
    let pdfView = SyncedPDFView()
    let header = PanelHeader("pdf", title: L10n.tr("PDF 预览"))
    let empty = NSStackView()
    let autoSwitch = NSSwitch()
    var onExport: (() -> Void)?
    var onReveal: (() -> Void)?
    var onAuto: ((Bool) -> Void)?
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
        let zoomOut = ActionButton("", symbol: "minus") { [weak self] in self?.pdfView.zoomOut(nil) }; zoomOut.toolTip = L10n.tr("缩小")
        let zoomIn = ActionButton("", symbol: "plus") { [weak self] in self?.pdfView.zoomIn(nil) }; zoomIn.toolTip = L10n.tr("放大")
        zoomOut.contentTintColor = Theme.text; zoomIn.contentTintColor = Theme.text
        zoomLabel.alignment = .center; zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium); zoomLabel.size(44, nil)
        zoomLabel.toolTip = L10n.tr("点按以适合窗口")
        zoomLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(fitWindow)))
        let zoomRow = NSStackView(views: [zoomOut, Theme.divider(height: 16), zoomLabel, Theme.divider(height: 16), zoomIn]); zoomRow.spacing = 0; zoomRow.alignment = .centerY
        let zoom = Chip(fill: Theme.fill, radius: 8); zoom.size(nil, 30); zoom.pin(zoomRow)
        let export = ActionButton("", symbol: "arrow.down.to.line", style: .accentIcon) { [weak self] in self?.onExport?() }; export.toolTip = L10n.tr("导出 PDF…")
        let reveal = ActionButton("", symbol: "scope") { [weak self] in self?.onReveal?() }; reveal.toolTip = L10n.tr("在 PDF 中定位  ⇧⌘J")
        reveal.setAccessibilityLabel(L10n.tr("在 PDF 中定位"))
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        for view in [stateChip, spacer, autoLabel, autoSwitch, Theme.divider(), reveal, zoom, export] { header.addControl(view) }
        header.menuActions = [
            (L10n.tr("在 PDF 中定位"), "scope", { [weak self] in self?.onReveal?() }),
            (L10n.tr("适合窗口"), "arrow.up.left.and.arrow.down.right", { [weak self] in self?.pdfView.autoScales = true }),
            (L10n.tr("导出 PDF…"), "arrow.down.to.line", { [weak self] in self?.onExport?() })
        ]
        state = .none

        pdfView.autoScales = true; pdfView.displayMode = .singlePageContinuous; pdfView.displaysPageBreaks = true; pdfView.pageBreakMargins = NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)
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
        super.layout()
    }
    @objc private func autoChanged() { onAuto?(autoSwitch.state == .on) }
    @objc private func fitWindow() { pdfView.autoScales = true }
    @objc private func scaleChanged() { zoomLabel.stringValue = "\(Int((pdfView.scaleFactor * 100).rounded()))%" }
    func load(_ url: URL) {
        // Read bytes so PDFKit cannot keep a mapped file alive while TeX rewrites it.
        guard let data = try? Data(contentsOf: url) else { return }
        // An unchanged PDF keeps its rendered pages; replacing the document would only make it blink.
        if data == loadedData, pdfView.document != nil { return }
        guard let document = PDFDocument(data: data) else { return }
        loadedData = data
        let oldPage = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) } ?? 0
        let oldDestination = pdfView.currentDestination
        let wasAuto = pdfView.autoScales; let scale = pdfView.scaleFactor
        pdfView.document = document; empty.isHidden = true
        highlightAnnotation = nil; highlightPage = nil
        if let page = document.page(at: min(oldPage, max(0, document.pageCount - 1))) {
            if let destination = oldDestination { pdfView.go(to: PDFDestination(page: page, at: destination.point)) }
            else { pdfView.go(to: page) }
        }
        pdfView.autoScales = wasAuto; if !wasAuto { pdfView.scaleFactor = scale }
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
