import XCTest
@testable import BetterTeXCore

final class BuildStateTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BuildState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testRestorePutsBackGoodBuildFilesOnly() throws {
        let output = directory.appendingPathComponent(".bettertex", isDirectory: true)
        let chapters = output.appendingPathComponent("chapters", isDirectory: true)
        try FileManager.default.createDirectory(at: chapters, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output.appendingPathComponent("overleaf-base"), withIntermediateDirectories: true)
        func write(_ text: String, _ path: String) throws { try text.write(to: output.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        try write("good aux", "main.aux"); try write("good sub", "chapters/one.aux"); try write("good log", "main.log")
        try write("{}", "overleaf.json"); try write("base", "overleaf-base/main.tex.aux")
        let state = BuildState(output: output)
        state.keep()
        XCTAssertEqual(Set(state.files(in: state.saved)), ["main.aux", "chapters/one.aux"])
        // A failed pass truncates the aux files and writes its own log.
        try write("trunc", "main.aux"); try write("trunc", "chapters/one.aux"); try write("failed log", "main.log")
        state.restore()
        func read(_ path: String) throws -> String { try String(contentsOf: output.appendingPathComponent(path), encoding: .utf8) }
        XCTAssertEqual(try read("main.aux"), "good aux")
        XCTAssertEqual(try read("chapters/one.aux"), "good sub")
        XCTAssertEqual(try read("main.log"), "failed log", "the failed build's log stays for its diagnostics")
        XCTAssertEqual(try read("overleaf-base/main.tex.aux"), "base")
    }

    /// With latexmk installed: a failed build must not make the next one redo bibtex and every pass.
    func testBuildAfterFailureNeedsOnePass() throws {
        let tools = Toolchain.discover()
        guard tools["latexmk"] != nil, tools["pdflatex"] != nil, tools["bibtex"] != nil else { throw XCTSkip("latexmk, pdflatex and bibtex are needed.") }
        let main = directory.appendingPathComponent("main.tex")
        try "@article{a, author={A. Author}, title={T}, journal={J}, year={2020}}\n".write(to: directory.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)
        func build(_ body: String) throws -> (BuildResult, [BuildStage]) {
            try "\\documentclass{article}\n\\begin{document}\n\\section{A}\\label{s}\n\(body) \\ref{s} \\cite{a}.\n\\bibliographystyle{plain}\n\\bibliography{refs}\n\\end{document}\n"
                .write(to: main, atomically: true, encoding: .utf8)
            var stages: [BuildStage] = []
            let result = try TeXCompiler().build(active: main, project: directory, selected: .automatic, tools: tools, onStage: { stages.append($0) })
            return (result, stages)
        }
        XCTAssertTrue(try build("Hello").0.succeeded)
        XCTAssertFalse(try build("Hello \\undefinedmacro").0.succeeded)
        let (fixed, stages) = try build("Hello there")
        XCTAssertTrue(fixed.succeeded)
        XCTAssertEqual(stages.map(\.tool), ["pdflatex"])
    }
}
