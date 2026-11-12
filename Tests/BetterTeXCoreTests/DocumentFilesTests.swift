import XCTest
@testable import BetterTeXCore

final class DocumentFilesTests: XCTestCase {
    func testFollowsInputsAndBibliographiesButNotCommentsOrStrayFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bettertex-doc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ name: String, _ text: String) throws {
            let url = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("main.tex", "\\documentclass{article}\n\\begin{document}\n\\input{sections/intro}\n% \\input{sections/old}\n\\include{appendix.tex}\n\\bibliography{IEEEabrv,references}\n\\end{document}\n")
        try write("sections/intro.tex", "Intro \\input{sections/detail} 50\\% done\n")
        try write("sections/detail.tex", "Detail")
        try write("sections/old.tex", "Old")
        try write("appendix.tex", "Appendix")
        try write("references.bib", "@misc{a}")
        try write("IEEEabrv.bib", "@string{a}")
        try write("figures/fig2_math_source/formulas.tex", "\\documentclass{standalone}")
        let names = DocumentFiles.included(from: directory.appendingPathComponent("main.tex")).map { $0.path.replacingOccurrences(of: directory.standardizedFileURL.path + "/", with: "") }
        XCTAssertEqual(names, ["sections/intro.tex", "appendix.tex", "IEEEabrv.bib", "references.bib", "sections/detail.tex"])
    }
}
