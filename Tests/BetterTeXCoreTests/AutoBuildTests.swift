import XCTest
@testable import BetterTeXCore

final class AutoBuildTests: XCTestCase {
    func testBalanceTracksBracesAndEnvironments() {
        XCTAssertEqual(TeXSource.balance(of: "\\begin{document}\\textbf{x}\\end{document}"), TeXBalance())
        XCTAssertEqual(TeXSource.balance(of: "\\textbf{x").braces, 1)
        XCTAssertEqual(TeXSource.balance(of: "\\begin{itemize}\\item a").environments, ["itemize"])
        XCTAssertEqual(TeXSource.balance(of: "\\begin{ite").environments, ["?begin"])
        // Escaped braces, comments and verbatim text do not count.
        XCTAssertEqual(TeXSource.balance(of: "\\{ 50\\% % { \\begin{x}\n\\verb|{|"), TeXBalance())
        XCTAssertEqual(TeXSource.balance(of: "\\begin{verbatim}{ \\begin{x}\\end{verbatim}"), TeXBalance())
        // A preamble file opens the document without closing it; that is its settled state.
        XCTAssertEqual(TeXSource.balance(of: "\\documentclass{article}\n\\begin{document}").environments, ["document"])
    }
    func testNormalizedIgnoresCommentsAndSpacing() {
        let base = TeXSource.normalized("Hello world.\n\nNext")
        XCTAssertEqual(base, TeXSource.normalized("Hello world. % note\n\n\n\nNext   "))
        XCTAssertNotEqual(base, TeXSource.normalized("Hello world!\n\nNext"))
        // A comment swallows the line break, so it is not the same as no comment at all.
        XCTAssertNotEqual(TeXSource.normalized("a\nb"), TeXSource.normalized("a%\nb"))
        // Escaped percent signs, URLs and verbatim blocks are content.
        XCTAssertNotEqual(TeXSource.normalized("50\\% off"), TeXSource.normalized("50\\%"))
        XCTAssertNotEqual(TeXSource.normalized("\\url{a%20b}"), TeXSource.normalized("\\url{a%20c}"))
        XCTAssertNotEqual(TeXSource.normalized("\\begin{verbatim}\nx % 1\n\\end{verbatim}"), TeXSource.normalized("\\begin{verbatim}\nx % 2\n\\end{verbatim}"))
    }
    func testDelayIsShorterAfterFinishedText() {
        let mid = AutoBuildTiming.delay(previousCharacter: "a", lastBuildSeconds: nil)
        XCTAssertLessThan(AutoBuildTiming.delay(previousCharacter: "。", lastBuildSeconds: nil), mid)
        XCTAssertLessThan(AutoBuildTiming.delay(previousCharacter: "\n", lastBuildSeconds: nil), mid)
        XCTAssertGreaterThan(AutoBuildTiming.delay(previousCharacter: "a", lastBuildSeconds: 6), mid)
        XCTAssertLessThanOrEqual(AutoBuildTiming.delay(previousCharacter: "a", lastBuildSeconds: 600), 3.5)
    }
    func testSignatureSkipsCommentEditsAndBuildLeftovers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeX autobuild \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = directory.appendingPathComponent("main.tex"); try "Hello.\n".write(to: main, atomically: true, encoding: .utf8)
        let cache = BuildSignatureCache()
        let first = BuildSignature.compute(project: directory, root: main.path, engine: "Auto", cache: cache)
        try "Hello. % todo\n".write(to: main, atomically: true, encoding: .utf8)
        XCTAssertEqual(first, BuildSignature.compute(project: directory, root: main.path, engine: "Auto", cache: cache))
        try "x".write(to: directory.appendingPathComponent("main.aux"), atomically: true, encoding: .utf8)
        try "x".write(to: directory.appendingPathComponent("main.pdf"), atomically: true, encoding: .utf8)
        try "x".write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(first, BuildSignature.compute(project: directory, root: main.path, engine: "Auto", cache: cache))
        try "Hello!\n".write(to: main, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(first, BuildSignature.compute(project: directory, root: main.path, engine: "Auto", cache: cache))
        try Data([1, 2]).write(to: directory.appendingPathComponent("figure.png"))
        XCTAssertNotEqual(first, BuildSignature.compute(project: directory, root: main.path, engine: "Auto", cache: cache))
    }
}
