import XCTest
import AppKit
import PDFKit
@testable import BetterTeX

@MainActor
final class PDFFindTests: XCTestCase {
    /// A one-page PDF with real text, drawn by AppKit so PDFKit can search it.
    private func pdf(_ text: String) -> Data {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        view.string = text; view.font = .systemFont(ofSize: 14)
        return view.dataWithPDF(inside: view.bounds)
    }

    func testFindHighlightsAllMatchesAndCycles() throws {
        let pane = PDFPane(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        pane.show(pdf("Alpha beta.\nalpha gamma.\nDelta ALPHA."), document: nil)
        pane.findBar.isHidden = false; pane.findBar.input.stringValue = "alpha"
        pane.runFind(scroll: true)
        XCTAssertEqual(pane.findMatches.count, 3)
        XCTAssertEqual(pane.pdfView.highlightedSelections?.count, 3)
        let first = try XCTUnwrap(pane.findIndex)
        pane.findNext(); XCTAssertEqual(pane.findIndex, (first + 1) % 3)
        pane.findPrevious(); pane.findPrevious(); XCTAssertEqual(pane.findIndex, (first + 2) % 3)
        // The current match is the one drawn last, in the stronger colour.
        XCTAssertTrue(pane.pdfView.highlightedSelections?.last === pane.findMatches[pane.findIndex!])
        XCTAssertEqual(pane.pdfView.highlightedSelections?.last?.color, PDFPane.findCurrentColor)

        pane.closeFind()
        XCTAssertFalse(pane.findVisible); XCTAssertTrue(pane.findMatches.isEmpty)
        XCTAssertTrue(pane.pdfView.highlightedSelections?.isEmpty ?? true)
    }

    func testRebuiltPDFKeepsSearchOpen() {
        let pane = PDFPane(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        pane.show(pdf("one needle here"), document: nil)
        pane.findBar.isHidden = false; pane.findBar.input.stringValue = "needle"; pane.runFind(scroll: true)
        XCTAssertEqual(pane.findMatches.count, 1)
        pane.show(pdf("needle and another needle"), document: nil)
        XCTAssertEqual(pane.findMatches.count, 2)
        XCTAssertNotNil(pane.findIndex)
    }

    func testNoMatches() {
        let pane = PDFPane(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        pane.show(pdf("nothing to see"), document: nil)
        pane.findBar.isHidden = false; pane.findBar.input.stringValue = "zebra"; pane.runFind(scroll: true)
        XCTAssertTrue(pane.findMatches.isEmpty); XCTAssertNil(pane.findIndex)
    }
}
