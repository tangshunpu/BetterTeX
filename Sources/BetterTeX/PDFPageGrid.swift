import AppKit
import PDFKit

/// Pages side by side in rows, the way a word processor shows a document zoomed far out.
/// It takes over from the PDF view once three or more pages fit across, and for "show all pages".
final class PDFPageGrid: NSView {
    static let gap: CGFloat = 20
    static let padding: CGFloat = 24
    private static let labelHeight: CGFloat = 20

    /// How many pages of `pageWidth` fit across `width`; the PDF view uses the same rule to decide when to hand over.
    static func columns(pageWidth: CGFloat, in width: CGFloat) -> Int {
        guard pageWidth > 0 else { return 1 }
        return max(1, Int(floor((width - 2 * padding + gap) / (pageWidth + gap))))
    }
    /// The largest page width at which `count` pages of the given height/width ratio all fit in `size`.
    static func widthShowingAll(count: Int, aspect: CGFloat, in size: NSSize) -> CGFloat {
        guard count > 0, aspect > 0 else { return 160 }
        var best: CGFloat = 0
        for columns in 1...count {
            let rows = CGFloat((count + columns - 1) / columns)
            let byWidth = (size.width - 2 * padding - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let byHeight = ((size.height - 2 * padding - gap * (rows - 1)) / rows - labelHeight) / aspect
            best = max(best, min(byWidth, byHeight))
        }
        return max(60, best)
    }

    var onOpenPage: ((Int) -> Void)?
    var onEscape: (() -> Void)?
    var document: PDFDocument? { didSet { thumbnails = [:]; canvas.needsLayout = true; relayout() } }
    var pageWidth: CGFloat = 160 { didSet { if abs(pageWidth - oldValue) > 0.5 { relayout() } } }
    var currentPage = 0 { didSet { canvas.needsDisplay = true } }
    private let scroll = NSScrollView()
    private let canvas = Canvas()
    private var cells: [NSRect] = []
    private var thumbnails: [Int: (width: Int, image: NSImage)] = [:]
    private var hovered: Int? { didSet { if hovered != oldValue { canvas.needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = canvas; canvas.grid = self
        scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: topAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)])
        setAccessibilityRole(.list); setAccessibilityLabel("Pages")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); relayout() }
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    private func pageSize(_ index: Int) -> NSSize {
        guard let page = document?.page(at: index) else { return NSSize(width: 612, height: 792) }
        var size = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { size = NSSize(width: size.height, height: size.width) }
        return size.width > 0 && size.height > 0 ? size : NSSize(width: 612, height: 792)
    }

    /// Lays the pages out in rows, centred, each scaled to `pageWidth`.
    private func relayout() {
        let width = max(1, scroll.contentSize.width)
        let count = document?.pageCount ?? 0
        let columns = min(max(1, count), Self.columns(pageWidth: pageWidth, in: width))
        let rowWidth = CGFloat(columns) * pageWidth + CGFloat(columns - 1) * Self.gap
        let left = max(Self.padding, (width - rowWidth) / 2)
        var frames: [NSRect] = []; var y = Self.padding; var index = 0
        while index < count {
            let row = index..<min(count, index + columns)
            let heights = row.map { pageWidth * pageSize($0).height / pageSize($0).width }
            let rowHeight = heights.max() ?? 0
            for (column, page) in row.enumerated() {
                let height = heights[column]
                frames.append(NSRect(x: left + CGFloat(column) * (pageWidth + Self.gap), y: y + (rowHeight - height), width: pageWidth, height: height))
                _ = page
            }
            y += rowHeight + Self.labelHeight + Self.gap; index += columns
        }
        cells = frames
        canvas.setFrameSize(NSSize(width: width, height: max(scroll.contentSize.height, y - Self.gap + Self.padding)))
        canvas.needsDisplay = true
    }

    func scrollToPage(_ index: Int) {
        guard cells.indices.contains(index) else { return }
        layoutSubtreeIfNeeded()
        canvas.scrollToVisible(cells[index].insetBy(dx: 0, dy: -Self.padding))
    }
    /// The first page whose cell is at least partly visible.
    var firstVisiblePage: Int {
        let visible = scroll.documentVisibleRect
        return cells.firstIndex { $0.maxY > visible.minY + 1 } ?? 0
    }

    private func thumbnail(_ index: Int, for rect: NSRect) -> NSImage? {
        guard let page = document?.page(at: index) else { return nil }
        // Rendered at the screen's pixel density, in width steps so small zoom changes reuse the image.
        let scale = window?.backingScaleFactor ?? 2
        let width = Int((rect.width * scale / 64).rounded(.up) * 64)
        if let cached = thumbnails[index], cached.width >= width, cached.width <= width * 2 { return cached.image }
        let image = page.thumbnail(of: NSSize(width: CGFloat(width), height: CGFloat(width) * rect.height / rect.width), for: .cropBox)
        thumbnails[index] = (width, image); return image
    }

    fileprivate func drawCells(_ dirty: NSRect) {
        for (index, cell) in cells.enumerated() where cell.insetBy(dx: -4, dy: -4 - Self.labelHeight).intersects(dirty) {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.18); shadow.shadowBlurRadius = 6; shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.set()
            NSColor.white.setFill(); cell.fill()
            NSGraphicsContext.restoreGraphicsState()
            thumbnail(index, for: cell)?.draw(in: cell, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            let current = index == currentPage, hover = index == hovered
            if current || hover {
                let ring = NSBezierPath(roundedRect: cell.insetBy(dx: -3, dy: -3), xRadius: 4, yRadius: 4); ring.lineWidth = current ? 2.5 : 1.5
                (current ? Theme.accent : Theme.accent.withAlphaComponent(0.45)).setStroke(); ring.stroke()
            }
            let label = "\(index + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: current ? .semibold : .regular), .foregroundColor: current ? Theme.accent : Theme.muted]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: cell.midX - size.width / 2, y: cell.maxY + 5), withAttributes: attributes)
        }
    }
    fileprivate func page(at point: NSPoint) -> Int? { cells.firstIndex { $0.insetBy(dx: -4, dy: -4).contains(point) } }
    fileprivate func click(at point: NSPoint) { if let index = page(at: point) { onOpenPage?(index) } }
    fileprivate func hover(at point: NSPoint?) { hovered = point.flatMap(page(at:)) }


    private final class Canvas: NSView {
        weak var grid: PDFPageGrid?
        private var tracking: NSTrackingArea?
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { grid?.drawCells(dirtyRect) }
        override func mouseUp(with event: NSEvent) { grid?.click(at: convert(event.locationInWindow, from: nil)) }
        override func mouseMoved(with event: NSEvent) { grid?.hover(at: convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) { grid?.hover(at: nil) }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area); tracking = area
        }
    }
}
