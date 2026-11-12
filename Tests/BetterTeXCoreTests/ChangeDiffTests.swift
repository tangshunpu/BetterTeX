import XCTest
@testable import BetterTeXCore

final class ChangeDiffTests: XCTestCase {
    private func describe(_ segments: [WordDiff.Segment]) -> String {
        segments.map { segment in
            switch segment.kind {
            case .equal: return segment.text
            case .inserted: return "{+\(segment.text)+}"
            case .deleted: return "[-\(segment.text)-]"
            }
        }.joined(separator: "|")
    }

    func testWhitespaceAndLineWrapAreIgnored() {
        XCTAssertEqual(WordDiff.diff(old: "a  quick\n  fox", new: "a quick fox").map(\.kind), [.equal])
    }

    func testReplacedWordIsDeletedThenInserted() {
        let segments = WordDiff.diff(old: "the quick brown fox", new: "the slow brown fox")
        XCTAssertEqual(describe(segments), "the|[-quick-]|{+slow+}|brown fox")
        XCTAssertEqual(segments.map(\.spaceBefore), [false, true, true, true])
    }

    func testTeXTokensAreFineGrainedAndKeepTheirJoins() {
        let segments = WordDiff.diff(old: "$\\bm{s}$ is", new: "$\\bm{y}$ is")
        XCTAssertEqual(describe(segments), "$\\bm{|[-s-]|{+y+}|}$ is")
        // `y` sat right after `{` in the source, so it is not set apart.
        XCTAssertFalse(segments[2].spaceBefore)
        XCTAssertEqual(describe(WordDiff.diff(old: "see \\cite{a}", new: "see \\ref{a}")), "see|[-\\cite-]|{+\\ref+}|{a}")
    }

    func testLoneSymbolBetweenEditsFoldsIntoOneChange() {
        XCTAssertEqual(describe(WordDiff.diff(old: "let x=y here", new: "let u=v here")), "let|[-x=y-]|{+u=v+}|here")
    }

    func testCJKIsComparedPerCharacter() {
        XCTAssertEqual(describe(WordDiff.diff(old: "我们提出方法", new: "我们设计方法")), "我们|[-提出-]|{+设计+}|方法")
    }

    func testPureInsertionAndDeletion() {
        XCTAssertEqual(describe(WordDiff.diff(old: "", new: "new line")), "{+new line+}")
        XCTAssertEqual(describe(WordDiff.diff(old: "gone text", new: "")), "[-gone text-]")
    }

    func testAgentEditsAreCreditedAndUserEditsAreNot() {
        let authorship = ChangeAuthorship()
        authorship.record(path: "/p/main.tex", old: "We use a model.", new: "We use a diffusion model with one step.", by: .claude)
        let head = "We use a model. Results are good."
        let now = "We use a diffusion model with one step. Results are great."
        let segments = authorship.attribute(WordDiff.diff(old: head, new: now), path: "/p/main.tex")
        let changed = segments.filter { $0.kind != .equal }
        XCTAssertEqual(changed.first { $0.text.contains("diffusion") }?.author, .claude)
        XCTAssertNil(changed.first { $0.text == "great" }?.author)
        XCTAssertNil(authorship.attribute(WordDiff.diff(old: head, new: now), path: "/p/other.tex").first { $0.author != nil })
    }

    func testHunkRangesAreKept() {
        let changes = LineChange.parse(diff: "@@ -3,2 +3,4 @@\n@@ -9 +11,0 @@")
        XCTAssertEqual(changes.map(\.kind), [.modified, .added, .deleted])
        XCTAssertEqual(changes[0].hunk, changes[1].hunk)
        XCTAssertEqual(changes[0].hunk, LineChange.Hunk(oldStart: 3, oldCount: 2, newStart: 3, newCount: 4))
        XCTAssertEqual(changes[2].hunk, LineChange.Hunk(oldStart: 9, oldCount: 1, newStart: 11, newCount: 0))
    }
}
