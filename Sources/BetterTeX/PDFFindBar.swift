import AppKit
import PDFKit
import BetterTeXCore

/// The floating find bar over the PDF: query, match counter, previous / next, case sensitivity and close.
final class PDFFindBar: Chip, NSTextFieldDelegate {
    let input = NSTextField()
    var onQuery: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    var onCaseSensitive: ((Bool) -> Void)?
    private(set) var caseSensitive = UserDefaults.standard.bool(forKey: "pdf.find.caseSensitive")
    private let countLabel = Theme.label("", size: 11.5, color: Theme.muted)
    private var caseButton: ActionButton!
    private var previousButton: ActionButton!
    private var nextButton: ActionButton!
    private var debounce: DispatchWorkItem?

    init() {
        super.init(fill: Theme.adaptive(0xFFFFFF, 0x2C2C2E, lightAlpha: 0.97, darkAlpha: 0.97), radius: 10, border: Theme.line)
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 10; layer?.shadowOffset = CGSize(width: 0, height: -3); layer?.masksToBounds = false
        let icon = NSImageView(image: Theme.symbol("magnifyingglass", size: 12, weight: .semibold)!); icon.contentTintColor = Theme.muted
        input.isBordered = false; input.drawsBackground = false; input.focusRingType = .none; input.font = .systemFont(ofSize: 13)
        input.textColor = Theme.text; input.placeholderString = L10n.tr("在 PDF 中查找"); input.delegate = self
        input.cell?.usesSingleLineMode = true; input.cell?.isScrollable = true; input.setAccessibilityLabel(L10n.tr("在 PDF 中查找"))
        input.setContentHuggingPriority(.init(1), for: .horizontal); input.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular); countLabel.alignment = .right
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal); countLabel.setContentHuggingPriority(.required, for: .horizontal)
        caseButton = ActionButton("", symbol: "textformat") { [weak self] in self?.toggleCase() }
        previousButton = ActionButton("", symbol: "chevron.up") { [weak self] in self?.onPrevious?() }
        previousButton.toolTip = L10n.tr("上一个  ⇧↩"); previousButton.setAccessibilityLabel(L10n.tr("上一个"))
        nextButton = ActionButton("", symbol: "chevron.down") { [weak self] in self?.onNext?() }
        nextButton.toolTip = L10n.tr("下一个  ↩"); nextButton.setAccessibilityLabel(L10n.tr("下一个"))
        let close = ActionButton("", symbol: "xmark") { [weak self] in self?.onClose?() }
        close.toolTip = L10n.tr("关闭  Esc"); close.setAccessibilityLabel(L10n.tr("关闭"))
        for button in [caseButton!, previousButton!, nextButton!, close] { button.size(26, 26) }
        let row = NSStackView(views: [icon, input, countLabel, Theme.divider(height: 16), caseButton, previousButton, nextButton, close])
        row.spacing = 4; row.alignment = .centerY; row.setCustomSpacing(8, after: icon); row.setCustomSpacing(8, after: countLabel)
        size(nil, 36); pinRow(row, leading: 10, trailing: 5)
        updateCaseButton(); setCount(current: nil, total: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    var query: String { input.stringValue }
    func focus(selectingAll: Bool = true) {
        window?.makeFirstResponder(input)
        if selectingAll { input.currentEditor()?.selectAll(nil) }
    }
    /// `nil` total: nothing searched yet. Zero: no matches.
    func setCount(current: Int?, total: Int?) {
        guard let total, !query.isEmpty else { countLabel.stringValue = ""; previousButton.isEnabled = false; nextButton.isEnabled = false; return }
        countLabel.stringValue = total == 0 ? L10n.tr("无结果") : "\((current ?? 0) + 1)/\(total)"
        countLabel.textColor = total == 0 ? Theme.red : Theme.muted
        previousButton.isEnabled = total > 1 || (total == 1 && current == nil); nextButton.isEnabled = previousButton.isEnabled
    }
    private func toggleCase() {
        caseSensitive.toggle(); UserDefaults.standard.set(caseSensitive, forKey: "pdf.find.caseSensitive")
        updateCaseButton(); onCaseSensitive?(caseSensitive)
    }
    private func updateCaseButton() {
        caseButton.contentTintColor = caseSensitive ? Theme.accent : Theme.muted
        let title = caseSensitive ? L10n.tr("区分大小写：开") : L10n.tr("区分大小写：关")
        caseButton.toolTip = title; caseButton.setAccessibilityLabel(L10n.tr("区分大小写")); caseButton.setAccessibilityValue(caseSensitive)
    }
    func controlTextDidChange(_ obj: Notification) {
        // Wait for a pause in typing; a long document is searched page by page on the main thread.
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in guard let self else { return }; self.onQuery?(self.query) }
        debounce = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    /// Runs a pending query now, so ↩ right after typing jumps to the first match of what was typed.
    @discardableResult func flush() -> Bool {
        guard let debounce, !debounce.isCancelled else { return false }
        debounce.cancel(); self.debounce = nil; onQuery?(query); return true
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            // A fresh query already lands on its first match; ↩ then moves on from there.
            if flush(), !backwards { return true }
            if backwards { onPrevious?() } else { onNext?() }
            return true
        case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            flush(); onPrevious?(); return true
        case #selector(NSResponder.moveUp(_:)): flush(); onPrevious?(); return true
        case #selector(NSResponder.moveDown(_:)): flush(); onNext?(); return true
        case #selector(NSResponder.cancelOperation(_:)): onClose?(); return true
        default: return false
        }
    }
}

/// Find in the PDF: every match tinted, the current one stronger, and the view following it.
extension PDFPane {
    static let findAllColor = NSColor.systemYellow.withAlphaComponent(0.42)
    static let findCurrentColor = NSColor.systemOrange.withAlphaComponent(0.72)
    /// More highlighted selections than this make every redraw slow; the counter still counts them all.
    static let findHighlightLimit = 3000

    var findVisible: Bool { !findBar.isHidden }
    /// Whether ⌘F belongs to the PDF: the pointer is over it, or focus is already inside it.
    func ownsFind(pointer screenPoint: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard let window, pdfView.document != nil, !isHiddenOrHasHiddenAncestor, bounds.width > 1, bounds.height > 1 else { return false }
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) { return true }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return bounds.contains(point)
    }
    /// Opens the find bar, seeded with a short selection in the PDF if there is one.
    func showFind() {
        guard pdfView.document != nil else { return }
        if let selected = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty, selected.count <= 120, !selected.contains("\n"), selected != findBar.query {
            findBar.input.stringValue = selected; findBar.isHidden = false; runFind(scroll: true)
        } else if findBar.isHidden {
            findBar.isHidden = false
            if !findBar.query.isEmpty { runFind(scroll: true) }
        }
        findBar.isHidden = false; findBar.focus()
    }
    func closeFind() {
        guard findVisible else { return }
        let hadFocus = (window?.firstResponder as? NSView).map { $0.isDescendant(of: findBar) } ?? false
        findBar.isHidden = true; findMatches = []; findIndex = nil
        pdfView.highlightedSelections = nil
        if hadFocus { window?.makeFirstResponder(gridVisible ? grid : pdfView) }
    }
    func findNext() { stepFind(1) }
    func findPrevious() { stepFind(-1) }

    /// Searches the document again. With `scroll` it jumps to the first match from the current page on;
    /// without (a rebuilt PDF), it keeps the view where it is and stays near the previous match.
    func runFind(scroll: Bool) {
        guard let document = pdfView.document else { return }
        let query = findBar.query
        guard !query.isEmpty else {
            findMatches = []; findIndex = nil; pdfView.highlightedSelections = nil; findBar.setCount(current: nil, total: nil); return
        }
        let previous = findIndex.flatMap { findMatches.indices.contains($0) ? findMatches[$0] : nil }.flatMap(Self.findPosition)
        var options: NSString.CompareOptions = [.diacriticInsensitive, .widthInsensitive]
        if !findBar.caseSensitive { options.insert(.caseInsensitive) }
        findMatches = document.findString(query, withOptions: options)
        guard !findMatches.isEmpty else {
            findIndex = nil; pdfView.highlightedSelections = nil; findBar.setCount(current: nil, total: 0); return
        }
        // Start from the match nearest where the reader is (or was), not from page one.
        let anchor = previous ?? visibleFindAnchor()
        findIndex = findMatches.firstIndex { Self.findPosition($0).map { !Self.precedes($0, anchor) } ?? false } ?? (scroll ? 0 : findMatches.count - 1)
        applyFindHighlights(); if scroll { revealCurrentMatch() }
    }
    private func stepFind(_ step: Int) {
        if findBar.isHidden { showFind(); return }
        if findBar.flush(), step > 0 { return }
        guard !findMatches.isEmpty else { if !findBar.query.isEmpty { NSSound.beep() }; return }
        let count = findMatches.count
        findIndex = ((findIndex ?? (step > 0 ? -1 : 0)) + step + count) % count
        applyFindHighlights(); revealCurrentMatch()
    }
    private func applyFindHighlights() {
        let current = findIndex
        var shown: [PDFSelection] = []
        // Near the current match first, so a capped list still tints what the reader is looking at.
        let order = findMatches.indices.sorted { abs($0 - (current ?? 0)) < abs($1 - (current ?? 0)) }.prefix(Self.findHighlightLimit)
        for index in order {
            let selection = findMatches[index]
            selection.color = index == current ? Self.findCurrentColor : Self.findAllColor
            shown.append(selection)
        }
        // The current match last, so it is drawn over any neighbour that overlaps it.
        if let current, let at = shown.firstIndex(where: { $0 === findMatches[current] }) { shown.append(shown.remove(at: at)) }
        pdfView.highlightedSelections = shown
        findBar.setCount(current: current, total: findMatches.count)
    }
    private func revealCurrentMatch() {
        guard let index = findIndex, findMatches.indices.contains(index), let document = pdfView.document else { return }
        let selection = findMatches[index]
        guard let page = selection.pages.first else { return }
        if gridVisible { leaveGrid(at: document.index(for: page)); applyFindHighlights() }
        let bounds = selection.bounds(for: page)
        // Only scroll when the match is not already comfortably in view.
        let visible = pdfView.convert(bounds, from: page)
        let viewport = pdfView.bounds.insetBy(dx: 0, dy: 40)
        if pdfView.currentPage == nil || !viewport.contains(visible) || visible.isEmpty {
            pdfView.go(to: bounds.insetBy(dx: -40, dy: -max(80, pdfView.bounds.height / max(pdfView.scaleFactor, 0.1) * 0.3)), on: page)
        }
        pdfView.setNeedsDisplay(pdfView.bounds)
    }
    /// Page index and top-left of a match, in reading order.
    private static func findPosition(_ selection: PDFSelection) -> (page: Int, y: CGFloat, x: CGFloat)? {
        guard let page = selection.pages.first, let document = page.document else { return nil }
        let bounds = selection.bounds(for: page)
        return (document.index(for: page), bounds.maxY, bounds.minX)
    }
    private static func precedes(_ a: (page: Int, y: CGFloat, x: CGFloat), _ b: (page: Int, y: CGFloat, x: CGFloat)) -> Bool {
        if a.page != b.page { return a.page < b.page }
        // PDF space grows upwards: higher on the page comes first. Lines within 2 pt count as one.
        if abs(a.y - b.y) > 2 { return a.y > b.y }
        return a.x < b.x
    }
    /// The top-left of what the reader sees.
    private func visibleFindAnchor() -> (page: Int, y: CGFloat, x: CGFloat) {
        let corner = NSPoint(x: pdfView.bounds.minX + 1, y: pdfView.isFlipped ? pdfView.bounds.minY + 1 : pdfView.bounds.maxY - 1)
        guard let document = pdfView.document, let page = gridVisible ? document.page(at: grid.currentPage) : (pdfView.page(for: corner, nearest: true) ?? pdfView.currentPage) else {
            return (0, .greatestFiniteMagnitude, 0)
        }
        if gridVisible { return (document.index(for: page), .greatestFiniteMagnitude, 0) }
        let point = pdfView.convert(corner, to: page)
        return (document.index(for: page), point.y, -.greatestFiniteMagnitude)
    }
}
