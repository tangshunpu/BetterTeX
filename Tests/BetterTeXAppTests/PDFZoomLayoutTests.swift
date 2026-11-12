import AppKit
import PDFKit
import XCTest
import BetterTeXCore
@testable import BetterTeX

/// Zooming out goes from one page across to two, then to a grid; zooming in comes back the same way.
final class PDFZoomLayoutTests: XCTestCase {
    @MainActor private func makePane() throws -> (PDFPane, NSWindow, URL) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bettertex-zoom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pdf = directory.appendingPathComponent("pages.pdf")
        let document = PDFDocument()
        for index in 0..<9 {
            let image = NSImage(size: NSSize(width: 612, height: 792), flipped: false) { rect in
                NSColor.white.setFill(); rect.fill()
                ("Page \(index + 1)" as NSString).draw(at: NSPoint(x: 72, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 36)])
                return true
            }
            document.insert(PDFPage(image: image)!, at: index)
        }
        XCTAssertTrue(document.write(to: pdf))
        // Like the workspace's split view: the pane gets a fixed frame and must fit its content inside it.
        let pane = PDFPane(frame: NSRect(x: 0, y: 0, width: 800, height: 900))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        pane.translatesAutoresizingMaskIntoConstraints = true; pane.autoresizingMask = []
        window.contentView?.addSubview(pane)
        pane.load(pdf); pane.setZoomMode(.fitWidth); pane.layoutSubtreeIfNeeded(); pane.applyZoom()
        return (pane, window, directory)
    }

    @MainActor func testZoomingOutGoesFromOnePageToTwoToAGridAndBack() throws {
        let (pane, window, directory) = try makePane()
        defer { window.orderOut(nil); try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(pane.pdfView.displayMode, .singlePageContinuous)
        let fitted = pane.pdfView.scaleFactor

        pane.userZoom(0.45, anchor: nil)
        XCTAssertFalse(pane.gridVisible)
        XCTAssertEqual(pane.pdfView.displayMode, .twoUpContinuous)
        XCTAssertEqual(pane.zoomMode, .manual)

        pane.userZoom(0.5, anchor: nil)
        XCTAssertTrue(pane.gridVisible)
        XCTAssertTrue(pane.pdfView.isHidden)

        pane.userZoom(3.2, anchor: nil)
        XCTAssertFalse(pane.gridVisible)
        XCTAssertEqual(pane.pdfView.displayMode, .singlePageContinuous)
        XCTAssertLessThan(abs(pane.pdfView.scaleFactor - fitted * 0.45 * 0.5 * 3.2), 0.05)
    }

    @MainActor func testShowAllPagesAndOpenOne() throws {
        let (pane, window, directory) = try makePane()
        defer { window.orderOut(nil); try? FileManager.default.removeItem(at: directory) }
        pane.showAllPages(true)
        XCTAssertTrue(pane.gridVisible)
        // All nine pages fit: three columns of three rows in an 800 × 854 area.
        XCTAssertEqual(PDFPageGrid.columns(pageWidth: pane.grid.pageWidth, in: pane.grid.bounds.width), 3)
        pane.leaveGrid(at: 4)
        XCTAssertFalse(pane.gridVisible)
        XCTAssertEqual(pane.pdfView.currentPage.flatMap { pane.pdfView.document?.index(for: $0) }, 4)
        XCTAssertEqual(pane.zoomMode, .fitWidth)
    }

    /// Real scroll and pinch events are delivered to PDFKit's inner views, so the pane intercepts them by position.
    @MainActor func testCommandScrollOverThePagesZoomsAndPlainScrollDoesNot() throws {
        let (pane, window, directory) = try makePane()
        defer { window.orderOut(nil); try? FileManager.default.removeItem(at: directory) }
        func wheel(_ lines: Int32, command: Bool) -> NSEvent {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!
            if command { event.flags = .maskCommand }
            return NSEvent(cgEvent: event)!
        }
        let overPages = pane.pdfView.convert(NSPoint(x: pane.pdfView.bounds.midX, y: pane.pdfView.bounds.midY), to: nil)
        let overHeader = pane.header.convert(NSPoint(x: 10, y: 10), to: nil)
        let before = pane.pdfView.scaleFactor
        XCTAssertFalse(pane.handleZoomGesture(wheel(3, command: false), at: overPages))
        XCTAssertFalse(pane.handleZoomGesture(wheel(3, command: true), at: overHeader))
        XCTAssertEqual(pane.pdfView.scaleFactor, before, accuracy: 0.0001)
        XCTAssertTrue(pane.handleZoomGesture(wheel(3, command: true), at: overPages))
        XCTAssertNotEqual(pane.pdfView.scaleFactor, before, accuracy: 0.01)
        XCTAssertEqual(pane.zoomMode, .manual)
        // The fit-width button brings it back to exactly the pane's width.
        pane.setZoomMode(.fitWidth)
        XCTAssertEqual(pane.pdfView.scaleFactor, before, accuracy: 0.01)
    }

    /// A narrow pane drops header controls instead of being pushed wider than it is, so fit width fits what you see.
    @MainActor func testNarrowPaneKeepsThePagesInsideIt() throws {
        let (pane, window, directory) = try makePane()
        defer { window.orderOut(nil); try? FileManager.default.removeItem(at: directory) }
        for width in [520.0, 400, 300, 240] {
            pane.setFrameSize(NSSize(width: width, height: 900)); pane.layoutSubtreeIfNeeded(); pane.applyZoom()
            XCTAssertLessThanOrEqual(pane.pdfView.frame.maxX, pane.bounds.width + 0.5, "width \(width)")
            XCTAssertLessThanOrEqual(pane.header.row.fittingSize.width, width, "width \(width)")
            let page = try XCTUnwrap(pane.pdfView.document?.page(at: 0))
            let shown = page.bounds(for: .cropBox).width * pane.pdfView.scaleFactor
            XCTAssertLessThanOrEqual(shown, pane.pdfView.bounds.width, "width \(width)")
        }
    }

    /// Reading mode shows whole pages, two facing ones in a wide pane and one in a narrow one, turned like a book.
    @MainActor func testReadingModeFitsWholePagesAndPicksOneOrTwo() throws {
        let (pane, window, directory) = try makePane()
        defer { window.orderOut(nil); try? FileManager.default.removeItem(at: directory) }
        func pageHeightShown() throws -> CGFloat { try XCTUnwrap(pane.pdfView.document?.page(at: 0)).bounds(for: .cropBox).height * pane.pdfView.scaleFactor }

        pane.setFrameSize(NSSize(width: 1400, height: 900)); pane.layoutSubtreeIfNeeded()
        pane.setReadingMode(true)
        XCTAssertEqual(pane.pdfView.displayMode, .twoUp)
        XCTAssertEqual(pane.zoomMode, .fitPage)
        XCTAssertLessThanOrEqual(try pageHeightShown(), pane.pdfView.bounds.height)
        XCTAssertGreaterThan(try pageHeightShown(), pane.pdfView.bounds.height * 0.8)

        // Turning the window tall and narrow drops to one whole page.
        pane.setFrameSize(NSSize(width: 600, height: 900)); pane.layoutSubtreeIfNeeded(); pane.applyZoom()
        XCTAssertEqual(pane.pdfView.displayMode, .singlePage)
        XCTAssertLessThanOrEqual(try pageHeightShown(), pane.pdfView.bounds.height)

        // Zooming in and back with the fit button returns to whole pages.
        pane.userZoom(1.5, anchor: nil)
        XCTAssertEqual(pane.zoomMode, .manual)
        XCTAssertEqual(pane.pdfView.displayMode, .singlePage)
        pane.fitToPane()
        XCTAssertEqual(pane.zoomMode, .fitPage)
        XCTAssertLessThanOrEqual(try pageHeightShown(), pane.pdfView.bounds.height)

        pane.setReadingMode(false)
        XCTAssertEqual(pane.pdfView.displayMode, .singlePageContinuous)
        XCTAssertEqual(pane.zoomMode, .fitWidth)
    }

    func testGridColumnsAndShowAllSizing() {
        XCTAssertEqual(PDFPageGrid.columns(pageWidth: 200, in: 700), 3)
        XCTAssertEqual(PDFPageGrid.columns(pageWidth: 400, in: 700), 1)
        let width = PDFPageGrid.widthShowingAll(count: 16, aspect: 1.294, in: NSSize(width: 1200, height: 800))
        let columns = PDFPageGrid.columns(pageWidth: width, in: 1200)
        let rows = (16 + columns - 1) / columns
        XCTAssertLessThanOrEqual(CGFloat(rows) * (width * 1.294 + 20 + 20) - 20 + 48, 800 + 1)
    }
}
