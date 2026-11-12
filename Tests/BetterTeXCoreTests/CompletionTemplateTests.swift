import XCTest
@testable import BetterTeXCore

final class CompletionTemplateTests: XCTestCase {
    private func complete(_ source: String, _ label: String, index: ProjectIndex = ProjectIndex()) throws -> String {
        let cursor = try XCTUnwrap(source.range(of: "|")).lowerBound
        let location = cursor.utf16Offset(in: source)
        let text = source.replacingOccurrences(of: "|", with: "")
        let request = try XCTUnwrap(CompletionRequest.detect(in: text, cursor: location), source)
        let item = try XCTUnwrap(Completer.items(for: request, index: index).first { $0.label == label }, label)
        let edit = Completer.apply(item, to: request, in: text)
        let result = NSMutableString(string: (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement))
        XCTAssertLessThanOrEqual(edit.caret, result.length)
        result.insert("|", at: edit.caret)
        return result as String
    }

    private let figure = #"""
    \begin{figure}[htbp]
      \centering
      \includegraphics[width=\linewidth]{|}
      \caption{}
      % \label{fig:}
    \end{figure}
    """#

    func testFigureFromArgumentShorthandAndShortcut() throws {
        XCTAssertEqual(try complete(#"\begin{fig|"#, "figure"), figure)
        XCTAssertEqual(try complete(#"\begin{fig|}"#, "figure"), figure)
        XCTAssertEqual(try complete(#"\begin figure|"#, "figure"), figure)
        XCTAssertEqual(try complete(#"\fig|"#, #"\fig"#), figure)
        XCTAssertEqual(try complete(#"\begin{figure}|"#, "figure"), figure)
        XCTAssertEqual(try complete(#"\begin{fig|ure}"#, "figure"), figure)
        XCTAssertEqual(try complete(#"\begin{figure*|}"#, "figure*"), figure.replacingOccurrences(of: "{figure}", with: "{figure*}"))
    }

    func testListsAndLabeledItems() throws {
        for name in ["itemize", "enumerate"] {
            let expected = "\\begin{\(name)}\n  \\item |\n\\end{\(name)}"
            XCTAssertEqual(try complete("\\begin{\(name)|}", name), expected)
            XCTAssertEqual(try complete("\\\(name)|", "\\" + name), expected)
        }
        XCTAssertEqual(try complete(#"\begin{des|}"#, "description"), "\\begin{description}\n  \\item[|] \n\\end{description}")
        XCTAssertEqual(try complete(#"\ite|"#, #"\item"#), #"\item |"#)
        XCTAssertEqual(try complete(#"\item|"#, #"\item[]"#), #"\item[|] "#)
        XCTAssertEqual(try complete(#"\bibit|"#, #"\bibitem"#), #"\bibitem{|}"#)
    }

    func testTableAndRequiredArguments() throws {
        let table = try complete(#"\tbl|"#, #"\tbl"#)
        XCTAssertTrue(table.hasPrefix("\\begin{table}[htbp]\n  \\centering\n  \\caption{|}\n  % \\label{tab:}"), table)
        XCTAssertTrue(table.contains("\\begin{tabular}{ll}\n    \\hline\n     &  \\\\\n"), table)
        XCTAssertTrue(table.hasSuffix("  \\end{tabular}\n\\end{table}"), table)
        XCTAssertTrue(try complete(#"\begin{tabular|}"#, "tabular").hasPrefix(#"\begin{tabular}{|}"#))
        XCTAssertTrue(try complete(#"\begin{tabularx|}"#, "tabularx").hasPrefix(#"\begin{tabularx}{\linewidth}{|}"#))
        XCTAssertEqual(try complete(#"\begin{minip|}"#, "minipage"), "\\begin{minipage}{0.48\\textwidth}\n  |\n\\end{minipage}")
        XCTAssertEqual(try complete(#"\begin{frame|}"#, "frame"), "\\begin{frame}{|}\n  \n\\end{frame}")
    }

    func testPlacementOptionsAndExistingRequiredArguments() throws {
        XCTAssertEqual(try complete(#"\begin{fig|}[t]"#, "figure"), figure.replacingOccurrences(of: "[htbp]", with: "[t]"))
        let tabular = try complete(#"\begin{tabu|}{ll}"#, "tabular")
        XCTAssertTrue(tabular.hasPrefix("\\begin{tabular}{ll}\n  |"), tabular)
        XCTAssertFalse(tabular.contains("{ll}{"))
        XCTAssertEqual(try complete(#"\begin{minip|}[t]"#, "minipage"), "\\begin{minipage}[t]{0.48\\textwidth}\n  |\n\\end{minipage}")
        XCTAssertEqual(try complete(#"\begin{fig|} existing text"#, "figure"), #"\begin{figure}| existing text"#)
        XCTAssertEqual(try complete(#"\begin{fig|}[unfinished"#, "figure"), #"\begin{figure}|[unfinished"#)
    }

    func testExistingEndsAndNestedEnvironmentsArePreserved() throws {
        let existing = "\\begin{fig|}\n  existing image\n\\end{figure}"
        XCTAssertEqual(try complete(existing, "figure"), existing.replacingOccurrences(of: "fig|}", with: "figure}|"))
        let nested = "\\begin{item|}\n  \\begin{itemize}\n    \\item nested\n  \\end{itemize}\n\\end{itemize}"
        XCTAssertEqual(try complete(nested, "itemize"), nested.replacingOccurrences(of: "item|}", with: "itemize}|"))
        let sibling = "\\begin{fig|}\n\\begin{figure}\nother\n\\end{figure}"
        XCTAssertEqual(try complete(sibling, "figure"), figure + "\n\\begin{figure}\nother\n\\end{figure}")
        // An enclosing environment's end is a boundary, not a reason to reuse a later sibling's end.
        let boundary = "\\begin{fig|}\n\\end{document}\n\\end{figure}"
        XCTAssertEqual(try complete(boundary, "figure"), figure + "\n\\end{document}\n\\end{figure}")
        let completeHeader = "\\begin{figure}\nbody\n\\end{figure}"
        XCTAssertNil(CompletionRequest.detect(in: completeHeader, cursor: #"\begin{figure}"#.utf16.count))
    }

    func testCommentsEscapesAndVerbatimDoNotSupplyAnEnd() throws {
        let comment = "\n% \\end{figure}"
        XCTAssertEqual(try complete(#"\begin{fig|}"# + comment, "figure"), figure + comment)
        let escaped = "\n\\\\end{figure}"
        XCTAssertEqual(try complete(#"\begin{fig|}"# + escaped, "figure"), figure + escaped)
        let literal = "\n\\begin{verbatim}\n\\end{figure}\n\\end{verbatim}"
        XCTAssertEqual(try complete(#"\begin{fig|}"# + literal, "figure"), figure + literal)
        for source in [#"% \begin{fig"#, #"\\begin{fig"#, #"\\begin figure"#, #"\\% \fig"#] {
            XCTAssertNil(CompletionRequest.detect(in: source, cursor: source.utf16.count), source)
        }
        let escapedPercent = #"50\% \fig"#
        XCTAssertNotNil(CompletionRequest.detect(in: escapedPercent, cursor: escapedPercent.utf16.count))
    }

    func testIndentationLineEndingsAndUnicodeCaret() throws {
        let indented = figure.components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n")
        XCTAssertEqual(try complete("    \\begin{fig|}", "figure"), indented)
        XCTAssertEqual(try complete("\t\\begin{item|}", "itemize"), "\t\\begin{itemize}\n\t\t\\item |\n\t\\end{itemize}")
        XCTAssertEqual(try complete("中文 😀\r\n  \\begin{equation|}\r\nnext", "equation"), "中文 😀\r\n  \\begin{equation}\r\n    |\r\n  \\end{equation}\r\nnext")
    }

    func testCustomEnvironmentsAndCommandsKeepPriority() throws {
        var index = ProjectIndex(); index.environments = ["claim"]; index.commands = ["figure"]
        XCTAssertEqual(try complete(#"\begin{claim|}"#, "claim", index: index), "\\begin{claim}\n  |\n\\end{claim}")
        XCTAssertEqual(try complete(#"\fig|"#, #"\figure"#, index: index), #"\figure|"#)
        XCTAssertEqual(try complete(#"\end item|"#, "itemize"), #"\end{itemize}|"#)
        XCTAssertEqual(try complete(#"\end{fig|ure}"#, "figure"), #"\end{figure}|"#)
    }

    func testEnvironmentNamesExpandAsCommands() throws {
        var index = ProjectIndex(); index.environments = ["claim"]
        XCTAssertEqual(try complete(#"\figure|"#, #"\figure"#), figure)
        XCTAssertEqual(try complete(#"\fig|"#, #"\figure"#), figure)
        XCTAssertEqual(try complete(#"\clai|"#, #"\claim"#, index: index), "\\begin{claim}\n  |\n\\end{claim}")
        XCTAssertTrue(try complete(#"\figure|"#, #"\figure*"#).hasPrefix(#"\begin{figure*}"#))
        for name in ["table", "center", "quote", "equation", "align*"] {
            XCTAssertTrue(try complete("\\\(name.replacingOccurrences(of: "*", with: ""))|", "\\" + name).contains("\\end{\(name)}"), name)
        }
    }

    func testCommandLikeEnvironmentsStayCommands() throws {
        for name in ["frame", "matrix", "column", "cases"] {
            let source = "\\" + name
            let request = try XCTUnwrap(CompletionRequest.detect(in: source, cursor: source.utf16.count))
            XCTAssertFalse(Completer.items(for: request, index: ProjectIndex()).contains { $0.environment == name }, name)
            XCTAssertEqual(try complete("\\begin{\(name)|}", name).contains("\\end{\(name)}"), true)
        }
        var index = ProjectIndex(); index.commands = ["fig"]
        XCTAssertEqual(try complete(#"\fi|"#, #"\fig"#, index: index), #"\fig|"#)
    }

    func testRepeatedTemplatesDoNotDefinePlaceholderLabels() throws {
        let figures = try complete(#"\fig|"#, #"\fig"#) + "\n" + complete(#"\fig|"#, #"\fig"#)
        let tables = try complete(#"\tbl|"#, #"\tbl"#) + "\n" + complete(#"\tbl|"#, #"\tbl"#)
        XCTAssertTrue(ProjectIndex.labels(in: figures + tables, file: "main.tex").isEmpty)
        XCTAssertTrue(figures.contains(#"% \label{fig:}"#))
        XCTAssertTrue(tables.contains(#"% \label{tab:}"#))
        let labels = ProjectIndex.labels(in: #"""
        % \label{comment}
        \label{active} % \label{after-comment}
        50\% \label{after-escaped-percent}
        """#, file: "main.tex")
        XCTAssertEqual(labels.map(\.label), ["active", "after-escaped-percent"])
    }

    func testCommandsUseTheCorrectNumberOfArguments() throws {
        for name in ["textcolor", "captionof", "rule", "colorbox"] {
            XCTAssertEqual(try complete("\\\(name)|", "\\" + name), "\\\(name){|}{}")
        }
        for name in ["multicolumn", "multirow", "definecolor", "resizebox", "newenvironment"] {
            XCTAssertEqual(try complete("\\\(name)|", "\\" + name), "\\\(name){|}{}{}")
        }
    }
}
