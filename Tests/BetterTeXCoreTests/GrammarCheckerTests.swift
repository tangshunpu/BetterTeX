import XCTest
@testable import BetterTeXCore

final class GrammarCheckerTests: XCTestCase {
    private func checker() -> GrammarChecker {
        let checker = GrammarChecker(defaults: UserDefaults(suiteName: "BetterTeX.GrammarCheckerTests.\(UUID().uuidString)")!)
        checker.checksSpelling = false
        return checker
    }
    /// The flagged text and first suggestion of each issue.
    private func flagged(_ text: String, spelling: Bool = false) -> [String] {
        let checker = checker(); checker.checksSpelling = spelling
        return checker.check(text).map { "\((text as NSString).substring(with: $0.range))→\($0.suggestions.first ?? "")" }
    }

    func testCatchesWhatHarperCatches() {
        XCTAssertEqual(flagged("This is a test of the the grammar checker."), ["the the→the"])
        XCTAssertEqual(flagged("We has alot of things."), ["has→have", "alot→a lot"])
        XCTAssertEqual(flagged("It is an unique idea and a apple."), ["an→a", "a→an"])
        XCTAssertEqual(flagged("He go to school."), ["go→goes"])
        XCTAssertEqual(flagged("Their going to there own house."), ["Their→They're", "there→their"])
        XCTAssertEqual(flagged("Yesterday i think it was fine."), ["i→I"])
        XCTAssertEqual(flagged("It is better then that. We could of known."), ["then→than", "of→have"])
        XCTAssertEqual(flagged("Their is a problem. They was late."), ["Their→There", "was→were"])
        XCTAssertEqual(flagged("The dog barked. the cat ran."), ["the→The"])
        XCTAssertEqual(flagged("We await for results , and the bain of my existence."), ["await for→await", " ,→,", "bain of my existence→bane of my existence"])
    }

    func testLeavesCorrectProseAlone() {
        let text = """
        It is a unique idea and an hour later an MRI and a URL. Let it go; make him go. That he go is required.
        The values, e.g. the mean, are shown in Fig. 3. Tax. denotes taxonomy. Type I has errors. Its value is high. It's its own thing.
        There are many results in there. They're going home. I think we have results. She put it there.
        """
        XCTAssertEqual(flagged(text), [])
    }

    func testMasksLaTeXMarkupMathAndComments() {
        let text = #"""
        \documentclass{article}
        \usepackage{amsmath}
        \begin{document}
        \section{Intro}
        We show that $a a$ holds for an $n$-gon \cite{knuth, knuth} and \ref{the the}. % the the comment
        \begin{equation}
          a = b \quad \text{the the}
        \end{equation}
        This are \textbf{alot} better~\cite{x}.
        \begin{verbatim}
        the the
        \end{verbatim}
        \end{document}
        """#
        XCTAssertEqual(flagged(text), ["alot→a lot"])
        let prose = TeXProse(text)
        XCTAssertEqual(prose.plain.count, text.utf16.count)
        XCTAssertTrue(prose.string.contains("Intro"))
        XCTAssertFalse(prose.string.contains("usepackage"))
    }

    func testChineseAndArticlesBeforeMathAreSkipped() {
        XCTAssertEqual(flagged("中文段落不应该被标记。 It is a $\\alpha$-stable law and a $n$-gon."), [])
    }

    func testSpellingUsesTheSystemDictionary() {
        let issues = flagged("We found erors in the dataset of NASA and the mDNS logs.", spelling: true)
        XCTAssertTrue(issues.contains("erors→"), "\(issues)")
        XCTAssertEqual(flagged("A minimiser of its behaviour, the $n$th and $k$-th terms.", spelling: true), [])
        XCTAssertFalse(issues.contains { $0.hasPrefix("NASA") || $0.hasPrefix("mDNS") })
        let checker = checker(); checker.checksSpelling = true
        let text = "Some erors here."
        let issue = try! XCTUnwrap(checker.check(text).first)
        XCTAssertTrue(checker.suggestions(for: issue, in: text).contains("errors"))
    }

    func testIgnoredIssuesStayIgnored() {
        let name = "BetterTeX.GrammarCheckerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        let first = GrammarChecker(defaults: defaults); first.checksSpelling = false
        let text = "This is the the end."
        first.ignore(try! XCTUnwrap(first.check(text).first), in: text)
        let reopened = GrammarChecker(defaults: defaults); reopened.checksSpelling = false
        XCTAssertEqual(reopened.check("And the the start.").count, 0)
    }

    func testIssuesFollowEditsAndVanishWhenTouched() {
        let issues = [GrammarIssue(range: NSRange(location: 2, length: 3), message: "a", rule: "SpellCheck"),
                      GrammarIssue(range: NSRange(location: 10, length: 4), message: "b", rule: "AnA")]
        let typedBetween = GrammarIssue.shift(issues, editing: NSRange(location: 7, length: 0), replacementLength: 2)
        XCTAssertEqual(typedBetween.map(\.range), [NSRange(location: 2, length: 3), NSRange(location: 12, length: 4)])
        let editedFirst = GrammarIssue.shift(issues, editing: NSRange(location: 3, length: 1), replacementLength: 0)
        XCTAssertEqual(editedFirst.map(\.message), ["b"])
        XCTAssertEqual(editedFirst.first?.range.location, 9)
    }

    func testIndefiniteArticleSounds() {
        for (word, a) in [("unique", true), ("hour", false), ("user", true), ("umbrella", false), ("one", true), ("FBI", false), ("NASA", true),
                          ("MRI", false), ("European", true), ("honest", false), ("RFLink", false), ("mDNS", false), ("X-ray", false), ("herb", false), ("Rx", false), ("Tx", true)] {
            let sound = Article.initialSound(word)
            XCTAssertEqual(sound == .consonant, a, word)
        }
    }
}
