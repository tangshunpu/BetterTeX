import XCTest
@testable import BetterTeXCore

final class LineCommentTests: XCTestCase {
    private func apply(_ text: String, _ selection: NSRange) -> (String, NSRange) {
        let edit = LineComment.toggle(in: text, selection: selection)
        return ((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
    }

    func testCommentsCaretLineAndKeepsCaretInPlace() {
        let (text, selection) = apply("a\nhello\nb", NSRange(location: 4, length: 0))
        XCTAssertEqual(text, "a\n% hello\nb")
        XCTAssertEqual(selection, NSRange(location: 6, length: 0))
    }

    func testUncommentsWhenAllLinesAreComments() {
        let (text, _) = apply("  % one\n  %two\n", NSRange(location: 0, length: 15))
        XCTAssertEqual(text, "  one\n  two\n")
    }

    func testMixedBlockIsCommentedAtSmallestIndentSkippingBlankLines() {
        let (text, selection) = apply("  x\n\n    % y\nz", NSRange(location: 0, length: 12))
        XCTAssertEqual(text, "  % x\n\n  %   % y\nz")
        XCTAssertEqual(selection, NSRange(location: 0, length: 16))
    }

    func testSelectionEndingAtLineStartExcludesThatLine() {
        let (text, _) = apply("a\nb\n", NSRange(location: 0, length: 2))
        XCTAssertEqual(text, "% a\nb\n")
    }

    func testRoundTripRestoresText() {
        let original = "\\section{A}\n  text \\% not a comment\n"
        let first = apply(original, NSRange(location: 0, length: (original as NSString).length))
        let second = apply(first.0, first.1)
        XCTAssertEqual(second.0, original)
    }

    func testEmptyLineGetsMarker() {
        let (text, selection) = apply("", NSRange(location: 0, length: 0))
        XCTAssertEqual(text, "% ")
        XCTAssertEqual(selection, NSRange(location: 2, length: 0))
    }
}
