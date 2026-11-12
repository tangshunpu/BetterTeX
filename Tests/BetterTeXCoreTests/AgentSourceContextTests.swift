import XCTest
@testable import BetterTeXCore

final class AgentSourceContextTests: XCTestCase {
    func testSnapshotPreservesUnicodeLatexAndLineEndings() throws {
        for newline in ["\n", "\r\n", "\r"] {
            let selected = "中文 📝 \\cite{key}" + newline + "An equation $x^2$." + newline
            var source = "Header" + newline + selected + "Outside the selection."
            let context = try XCTUnwrap(AgentSourceContext(file: "sections/中文.tex", source: source, range: (source as NSString).range(of: selected)))
            source = "changed"
            XCTAssertEqual(context.selection, selected)
            XCTAssertEqual(context.lines, 2...3)
            XCTAssertEqual(context.reference, "@sections/中文.tex:2-3")
            XCTAssertTrue(context.proofreadingPrompt.contains(selected))
            XCTAssertFalse(context.proofreadingPrompt.contains("Outside the selection."))
            XCTAssertFalse(context.proofreadingPrompt.contains(source))
        }
    }

    func testFileOnlyBlankAndInvalidRanges() throws {
        let context = try XCTUnwrap(AgentSourceContext(file: "main.tex", source: "Hello", range: NSRange(location: 5, length: 0)))
        XCTAssertEqual(context.excerpt, "@main.tex")
        XCTAssertNil(context.lines); XCTAssertNil(context.selection); XCTAssertFalse(context.canProofread)
        XCTAssertFalse(try XCTUnwrap(AgentSourceContext(file: "main.tex", source: " \n", range: NSRange(location: 0, length: 2))).canProofread)
        for range in [NSRange(location: NSNotFound, length: 0), NSRange(location: 7, length: 0), NSRange(location: 4, length: 2), NSRange(location: 0, length: Int.max)] {
            XCTAssertNil(AgentSourceContext(file: "main.tex", source: "Hello", range: range))
        }
    }

    func testSelectionContainingCodeFenceRemainsAnExcerpt() throws {
        let source = "```tex\n\\textbf{word}\n```"
        let context = try XCTUnwrap(AgentSourceContext(file: "notes.tex", source: source, range: NSRange(location: 0, length: (source as NSString).length)))
        XCTAssertEqual(context.excerpt, "@notes.tex:1-3\n````tex\n" + source + "\n````")
        XCTAssertEqual(AgentSourceContext(file: "main.tex", source: "one\ntwo\n", range: NSRange(location: 4, length: 3))?.lines, 2...2)
    }
}
