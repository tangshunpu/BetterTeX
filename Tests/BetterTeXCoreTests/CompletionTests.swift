import XCTest
@testable import BetterTeXCore

final class CompletionTests: XCTestCase {
    private func request(_ text: String) -> CompletionRequest? {
        // "|" marks the caret.
        let ns = text as NSString; let caret = ns.range(of: "|").location
        return CompletionRequest.detect(in: ns.replacingOccurrences(of: "|", with: ""), cursor: caret)
    }
    func testDetectsWhatIsBeingTyped() {
        XCTAssertEqual(request("see \\cite{tang|")?.kind, .citation)
        let list = request("x \\citep[p.~3]{a2020, tan|}"); XCTAssertEqual(list?.kind, .citation); XCTAssertEqual(list?.prefix, "tan"); XCTAssertEqual(list?.range, NSRange(location: 22, length: 3))
        XCTAssertEqual(request("Eq.~\\eqref{eq:|")?.prefix, "eq:"); XCTAssertEqual(request("\\cref{a,b|")?.kind, .reference)
        XCTAssertEqual(request("\\begin{ali|")?.kind, .environment); XCTAssertEqual(request("\\end{|}")?.command, "end")
        XCTAssertEqual(request("\\includegraphics[width=\\linewidth]{fig|")?.kind, .graphics)
        XCTAssertEqual(request("\\input{sec|")?.kind, .input); XCTAssertEqual(request("\\usepackage{ams|")?.kind, .package)
        let command = request("a \\alp|"); XCTAssertEqual(command?.kind, .command); XCTAssertEqual(command?.prefix, "alp"); XCTAssertEqual(command?.range, NSRange(location: 2, length: 4))
        XCTAssertEqual(request("\\textbf{\\al|")?.kind, .command)
        XCTAssertEqual(request("line one\nsecond \\ref{fi|")?.range, NSRange(location: 21, length: 2))
        // No completion: plain text, a bare backslash, a line break, comments, closed arguments, \href.
        XCTAssertNil(request("plain text|")); XCTAssertNil(request("\\|")); XCTAssertNil(request("a \\\\b|")); XCTAssertNil(request("% \\cite{a|"))
        XCTAssertNil(request("\\cite{a} and|")); XCTAssertNil(request("\\href{http|")); XCTAssertNil(request("\\textbf{bold|"))
        XCTAssertEqual(request("50\\% \\cite{a|")?.kind, .citation)
    }
    func testIndexScansLabelsCitationsMacrosAndPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeX completion \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ path: String, _ text: String) throws {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("main.tex", "\\newcommand{\\vect}[1]{\\mathbf{#1}}\\DeclareMathOperator*{\\argmax}{arg\\,max}\\def\\R{\\mathbb{R}}\\newtheorem{claim}{Claim}\\label{sec:intro}\\bibitem{manual1}")
        try write("sections/method.tex", "\\label{eq:loss} \\label{fig:arch}")
        try write("refs.bib", "@string{x = \"y\"}\n@article{tang2025osd,\n  title = {One-Step {Diffusion} for JSCC},\n  author = {Tang, Shunpu and Yang, Qianqian},\n  year = 2025\n}\n@inproceedings{ho2020,\n author=\"Jonathan Ho and Ajay Jain\", title=\"Denoising Diffusion\", year={2020}}\n")
        try write("figures/arch.pdf", "x"); try write(".bettertex/main.pdf", "x"); try write("build/skip.tex", "\\label{no}")
        let index = ProjectIndex.scan(project: directory, base: directory)
        XCTAssertEqual(Set(index.labels.map(\.label)), ["sec:intro", "eq:loss", "fig:arch"])
        XCTAssertEqual(index.labels.first { $0.label == "eq:loss" }?.detail, "method.tex")
        XCTAssertEqual(Set(index.citations.map(\.label)), ["tang2025osd", "ho2020", "manual1"])
        XCTAssertEqual(index.citations.first { $0.label == "tang2025osd" }?.detail, "Tang 2025 · One-Step Diffusion for JSCC")
        XCTAssertEqual(index.citations.first { $0.label == "ho2020" }?.detail, "Ho 2020 · Denoising Diffusion")
        XCTAssertEqual(index.commands, ["R", "argmax", "vect"]); XCTAssertEqual(index.environments, ["claim"])
        XCTAssertEqual(index.graphics, ["figures/arch.pdf"]); XCTAssertEqual(index.inputs, ["main", "sections/method"]); XCTAssertEqual(index.bibliographies, ["refs.bib"])
    }
    func testRankingAndFiltering() {
        var index = ProjectIndex()
        index.citations = [CompletionItem(label: "ho2020", detail: "Ho 2020 · Denoising Diffusion"), CompletionItem(label: "tang2025osd", detail: "Tang 2025 · One-Step Diffusion for JSCC"), CompletionItem(label: "xtang", detail: "")]
        index.labels = [CompletionItem(label: "fig:arch"), CompletionItem(label: "eq:loss")]; index.commands = ["vect"]; index.environments = ["claim"]
        func items(_ text: String) -> [String] { CompletionRequest.detect(in: text, cursor: (text as NSString).length).map { Completer.items(for: $0, index: index).map(\.label) } ?? [] }
        XCTAssertEqual(items("\\cite{tang"), ["tang2025osd", "xtang"])            // prefix first, then substring
        XCTAssertEqual(items("\\cite{denoising"), ["ho2020"])                      // matches the title
        XCTAssertEqual(items("\\cite{").count, 3); XCTAssertEqual(items("\\ref{fig"), ["fig:arch"])
        XCTAssertEqual(items("\\begin{cl"), ["claim"]); XCTAssertEqual(Array(items("\\begin{ali").prefix(3)), ["align", "align*", "aligned"])
        XCTAssertEqual(items("\\vec"), ["\\vec", "\\vect"]); XCTAssertEqual(items("\\in").first, "\\in")
        XCTAssertTrue(items("\\alpha").isEmpty, "a finished name with nothing to expand offers nothing")
        XCTAssertEqual(items("\\frac"), ["\\frac"], "a finished name that still expands is offered")
        XCTAssertTrue(items("\\zzzz").isEmpty); XCTAssertEqual(items("\\usepackage{amsm"), ["amsmath"])
    }
    func testApplyingCompletions() {
        func apply(_ text: String, _ label: String) -> String {
            let ns = text as NSString; let caret = ns.range(of: "|").location; let clean = ns.replacingOccurrences(of: "|", with: "")
            var index = ProjectIndex(); index.citations = [CompletionItem(label: "tang2025osd")]; index.labels = [CompletionItem(label: "fig:arch")]
            let request = CompletionRequest.detect(in: clean, cursor: caret)!
            let item = Completer.items(for: request, index: index).first { $0.label == label }!
            let edit = Completer.apply(item, to: request, in: clean)
            let result = NSMutableString(string: (clean as NSString).replacingCharacters(in: edit.range, with: edit.replacement)); result.insert("|", at: edit.caret)
            return result as String
        }
        XCTAssertEqual(apply("see \\cite{ta|", "tang2025osd"), "see \\cite{tang2025osd}|")
        XCTAssertEqual(apply("see \\cite{a, ta|} more", "tang2025osd"), "see \\cite{a, tang2025osd}| more")
        XCTAssertEqual(apply("\\ref{|}", "fig:arch"), "\\ref{fig:arch}|")
        XCTAssertEqual(apply("x \\fra|", "\\frac"), "x \\frac{|}{}"); XCTAssertEqual(apply("\\ci|", "\\cite"), "\\cite{|}")
        XCTAssertEqual(apply("\\alp|", "\\alpha"), "\\alpha|"); XCTAssertEqual(apply("\\ite|", "\\item"), "\\item |")
        XCTAssertEqual(apply("  \\begin{ali|", "align"), "  \\begin{align}\n    |\n  \\end{align}")
        XCTAssertEqual(apply("\\begin{item|}", "itemize"), "\\begin{itemize}\n  \\item |\n\\end{itemize}")
        XCTAssertEqual(apply("\\begin{ali|} x", "align"), "\\begin{align}| x", "an existing line is left alone")
        XCTAssertEqual(apply("\\end{ali|", "align"), "\\end{align}|")
    }
}
