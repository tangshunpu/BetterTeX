import XCTest
@testable import BetterTeXCore

final class TexStructureTests: XCTestCase {
    private let source = """
    \\documentclass{article}
    \\begin{document}
    \\section{Intro \\label{sec:intro}}
    Text.
    % \\section{Commented}
    \\begin{figure}[t]
      \\caption{A \\textbf{bold} plot}
    \\end{figure}
    \\subsection*{Aside}
    \\subsection{Data}
    \\begin{table*}
      \\caption{Results}
    \\end{table*}
    \\section{Method}
    \\begin{figure}
    \\end{figure}
    \\end{document}
    """

    func testFindsHeadingsWithNumbersAndSkipsComments() {
        let structure = TexStructure.scan(source)
        XCTAssertEqual(structure.headings.map(\.title), ["Intro", "Aside", "Data", "Method"])
        XCTAssertEqual(structure.headings.map(\.number), ["1", "", "1.1", "2"])
        XCTAssertEqual(structure.headings.map(\.kind), [.section, .subsection, .subsection, .section])
    }

    func testFloatsAreNumberedPerKindWithCaptions() {
        let structure = TexStructure.scan(source)
        XCTAssertEqual(structure.blocks.map(\.kind), [.figure, .table, .figure])
        XCTAssertEqual(structure.blocks.map(\.number), [1, 1, 2])
        XCTAssertEqual(structure.blocks.map(\.caption), ["A bold plot", "Results", nil])
        let ns = source as NSString
        XCTAssertTrue(ns.substring(with: structure.blocks[0].range).hasPrefix("\\begin{figure}"))
        XCTAssertTrue(ns.substring(with: structure.blocks[0].range).hasSuffix("\\end{figure}\n"))
    }

    func testScopesNestAndStopAtEndDocument() {
        let structure = TexStructure.scan(source)
        let ns = source as NSString
        let data = ns.range(of: "Results").location
        XCTAssertEqual(structure.path(at: data).map(\.title), ["Intro", "Data"])
        XCTAssertEqual(structure.block(at: data)?.kind, .table)
        let method = structure.headings[3]
        XCTAssertEqual(NSMaxRange(method.scope), ns.range(of: "\\end{document}").location)
        XCTAssertEqual(structure.path(at: ns.range(of: "\\documentclass").location).count, 0)
    }

    func testChaptersLeadTheNumbering() {
        let structure = TexStructure.scan("\\chapter{One}\n\\section{A}\n\\chapter{Two}\n\\section{B}\n")
        XCTAssertEqual(structure.headings.map(\.number), ["1", "1.1", "2", "2.1"])
    }
}
