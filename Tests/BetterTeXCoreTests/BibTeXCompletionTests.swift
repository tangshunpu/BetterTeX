import XCTest
@testable import BetterTeXCore

final class BibTeXCompletionTests: XCTestCase {
    private func request(_ text: String) -> CompletionRequest? {
        let cursor = (text as NSString).range(of: "|").location
        return CompletionRequest.detect(inBib: text.replacingOccurrences(of: "|", with: ""), cursor: cursor)
    }

    func testDetectsEntryTypeOnlyAtLineStart() {
        XCTAssertEqual(request("@|")?.kind, .bibEntry)
        XCTAssertEqual(request("}\n\n  @inpro|")?.prefix, "inpro")
        XCTAssertEqual(request("@art|")?.range, NSRange(location: 0, length: 4))
        XCTAssertNil(request("  author = {a@b|"))
        XCTAssertNil(request("@article{|"))
    }

    func testCommonTypesComeFirst() {
        let items = Completer.items(for: request("@in|")!, index: ProjectIndex())
        XCTAssertEqual(items.first?.label, "@inproceedings")
        XCTAssertEqual(Completer.items(for: request("@|")!, index: ProjectIndex()).prefix(2).map(\.label), ["@article", "@inproceedings"])
    }

    func testAcceptInsertsSkeletonWithCaretOnKey() {
        let text = "@art"
        let req = CompletionRequest.detect(inBib: text, cursor: 4)!
        let item = Completer.items(for: req, index: ProjectIndex()).first!
        let edit = Completer.apply(item, to: req, in: text)
        XCTAssertEqual(edit.range, NSRange(location: 0, length: 4))
        XCTAssertTrue(edit.replacement.hasPrefix("@article{,\n  author = {},\n  title = {},\n  journal = {},"))
        XCTAssertTrue(edit.replacement.hasSuffix("\n}"))
        XCTAssertEqual(edit.caret, 9)
    }

    func testAcceptOnlyRenamesTypeOfExistingEntry() {
        let text = "@art{smith2020,\n}"
        let req = CompletionRequest.detect(inBib: text, cursor: 2)!
        let item = CompletionItem(label: "@misc")
        let edit = Completer.apply(item, to: req, in: text)
        XCTAssertEqual(edit.range, NSRange(location: 0, length: 4))
        XCTAssertEqual(edit.replacement, "@misc")
    }

    func testFamilies() {
        XCTAssertEqual(BibEntryType.family(of: "Article"), .journal)
        XCTAssertEqual(BibEntryType.family(of: "inproceedings"), .conference)
        XCTAssertEqual(BibEntryType.family(of: "phdthesis"), .thesis)
    }
}
