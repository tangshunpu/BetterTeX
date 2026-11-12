import AppKit
import PDFKit
import XCTest
import BetterTeXCore
@testable import BetterTeX

/// Compiles a real document, then edits the source above a paragraph without recompiling, and checks both
/// directions still land on the exact word.
final class PDFSyncTests: XCTestCase {
    @MainActor func testSyncLandsOnTheWordAfterEditsSinceTheBuild() throws {
        let discovered = Toolchain.discover()
        guard discovered["pdflatex"] != nil, discovered["synctex"] != nil else { throw XCTSkip("Requires a local TeX installation") }
        var paths = discovered.paths; paths.removeValue(forKey: "latexmk")
        let tools = Toolchain(environment: discovered.environment, paths: paths)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bettertex-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let filler = String(repeating: "Wireless channels change over time and different conditions call for different strategies. ", count: 12)
        let paragraph = "The layered codeword lets the transmitter stop at any boundary. A quintessential property of this design is that every prefix decodes on its own, and the marvellous part is that no side information is needed at all. The receiver simply waits for more layers."
        let original = "\\documentclass{article}\n\\begin{document}\n\(filler)\n\n\(paragraph)\n\n\(filler)\n\\end{document}\n"
        let main = directory.appendingPathComponent("main.tex")
        try original.write(to: main, atomically: true, encoding: .utf8)
        let snapshot = SourceSnapshot.capture(directory: directory)
        let build = try TeXCompiler().build(active: main, project: directory, selected: .pdfLaTeX, tools: tools)
        XCTAssertTrue(build.succeeded, build.log)

        // A figure is added above the paragraph after the build: every later line moves down by four.
        let edited = original.replacingOccurrences(of: "\n\n\(paragraph)", with: "\n\n\\begin{figure}[h]\n\\centering\\rule{2cm}{1cm}\n\\caption{Added later}\n\\end{figure}\n\(paragraph)")
        let pane = PDFPane(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        pane.load(build.pdf)

        // Source → PDF, caret on "quintessential".
        let caret = (edited as NSString).range(of: "quintessential").location
        let line = TextSync.line(of: caret, starts: TextSync.lineStarts(edited))
        let compiledLine = try XCTUnwrap(snapshot.lineMap(for: main, current: edited)).compiled(forCurrent: line)
        XCTAssertEqual(compiledLine, line - 4)
        let boxes = SyncTeX.boxes(file: main, line: compiledLine, pdf: build.pdf, tools: tools)
        XCTAssertFalse(boxes.isEmpty)
        let stream = TextSync.texStream(edited)
        let index = stream.index(atOrAfter: caret)
        let sentence = TextSync.sentenceRange(in: edited, at: caret)
        let first = stream.index(atOrAfter: sentence.location), last = stream.index(atOrAfter: NSMaxRange(sentence)) - 1
        XCTAssertNotNil(pane.reveal(source: stream, cursor: index, sentence: first...last, boxes: boxes))
        let mark = try XCTUnwrap(pane.lastMark)
        let pageText = try XCTUnwrap(mark.page.string) as NSString
        // The page may hyphenate the word across lines.
        let joined = { (text: String) in text.replacingOccurrences(of: "-\n", with: "").replacingOccurrences(of: "\n", with: " ") }
        XCTAssertTrue(joined(pageText.substring(from: mark.caret)).hasPrefix("quintessential"), pageText.substring(with: NSRange(location: mark.caret, length: 30)))
        let marked = joined(pageText.substring(with: mark.range))
        XCTAssertTrue(marked.hasPrefix("A quintessential property"), marked)
        XCTAssertTrue(marked.hasSuffix("needed at all."), marked)

        // PDF → source, a click on "marvellous".
        let document = try XCTUnwrap(pane.pdfView.document)
        var clicked: PDFClick?
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex), let text = page.string as NSString? else { continue }
            let location = text.range(of: "marvellous").location
            guard location != NSNotFound else { continue }
            let bounds = page.textBounds(at: location + 2)
            clicked = pane.textPosition(page: pageIndex, point: CGPoint(x: bounds.midX, y: bounds.midY))
        }
        let position = try XCTUnwrap(clicked)
        let match = try XCTUnwrap(TextSync.correspond(position.index, from: position.stream, to: stream))
        XCTAssertEqual(stream.offset(at: match.index), (edited as NSString).range(of: "marvellous").location + 2)
    }

    /// PDFKit's glyph indices drift from `PDFPage.string` further down a page; a click must still read the word under it.
    @MainActor func testAClickLowOnAPageReadsTheWordUnderIt() throws {
        let discovered = Toolchain.discover()
        guard discovered["pdflatex"] != nil else { throw XCTSkip("Requires a local TeX installation") }
        var paths = discovered.paths; paths.removeValue(forKey: "latexmk")
        let tools = Toolchain(environment: discovered.environment, paths: paths)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bettertex-click-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paragraphs = (1...14).map { "Paragraph \($0) explains how a receiver with $\\rho_{\($0)} = k/n$ decodes a prefix, and why the first layers matter most for quality." }.joined(separator: "\n\n")
        let source = "\\documentclass[twocolumn]{article}\n\\begin{document}\n\(paragraphs)\n\nNear the bottom a zygomorphic marker closes the text.\n\\end{document}\n"
        let main = directory.appendingPathComponent("main.tex")
        try source.write(to: main, atomically: true, encoding: .utf8)
        let build = try TeXCompiler().build(active: main, project: directory, selected: .pdfLaTeX, tools: tools)
        XCTAssertTrue(build.succeeded, build.log)
        let pane = PDFPane(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        pane.load(build.pdf)
        let page = try XCTUnwrap(pane.pdfView.document?.page(at: 0)), text = try XCTUnwrap(page.string) as NSString
        let location = text.range(of: "zygomorphic").location
        XCTAssertNotEqual(location, NSNotFound)
        let bounds = page.textBounds(at: location + 4)
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        XCTAssertEqual(page.textIndex(at: point), location + 4)
        let clicked = try XCTUnwrap(pane.textPosition(page: 0, point: point))
        XCTAssertEqual(clicked.word, "zygomorphic")
        let found = try XCTUnwrap(TextSync.locate(clicked: clicked, hint: nil, candidates: [(main, source)]))
        XCTAssertEqual(found.offset, (source as NSString).range(of: "zygomorphic").location + 4)
        // Blank paper has no text under it.
        XCTAssertNil(pane.textPosition(page: 0, point: CGPoint(x: 4, y: 4)))
    }

    func testWordRangeFindsTheWordUnderTheCaret() {
        let text = "The layered codeword lets the transmitter stop."
        let ns = text as NSString
        let at = ns.range(of: "codeword").location + 3
        XCTAssertEqual(TextSync.wordRange(in: text, at: at).map { ns.substring(with: $0) }, "codeword")
        XCTAssertEqual(TextSync.wordRange(in: text, at: 0).map { ns.substring(with: $0) }, "The")
        XCTAssertNil(TextSync.wordRange(in: text, at: ns.length))
    }
}
