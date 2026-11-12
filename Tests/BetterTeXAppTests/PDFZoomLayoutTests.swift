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
        let pane = PDFPane(frame: NSRect(x: 0, y: 0, width: 800, height: 900))
        let window = NSWindow(contentRect: pane.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = pane
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

    @MainActor func testCommandScrollZoomsAndPlainScrollDoesNot() throws {
        let (pane, window, directory) = try makePane()
        defer { window.orderOut(nil); try? FileManager.default.removeItem(at: directory) }
        func wheel(_ lines: Int32, command: Bool) -> NSEvent {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!
            event.location = CGPoint(x: 300, y: 300)
            if command { event.flags = .maskCommand }
            return NSEvent(cgEvent: event)!
        }
        let before = pane.pdfView.scaleFactor
        pane.pdfView.scrollWheel(with: wheel(-3, command: false))
        XCTAssertEqual(pane.pdfView.scaleFactor, before, accuracy: 0.0001)
        pane.pdfView.scrollWheel(with: wheel(-3, command: true))
        XCTAssertNotEqual(pane.pdfView.scaleFactor, before, accuracy: 0.01)
        XCTAssertEqual(pane.zoomMode, .manual)
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
