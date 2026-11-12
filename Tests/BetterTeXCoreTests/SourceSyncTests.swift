import XCTest
@testable import BetterTeXCore

final class SourceSyncTests: XCTestCase {
    private func plain(_ stream: TextStream) -> String { String(stream.characters) }

    func testTeXStreamKeepsPrintedWordsOnly() {
        let source = #"""
        As shown in \autoref{fig:arch}, the \textbf{JSCC} encoder~\cite{liu2022} maps $\bm{S}_j$ to $\gamma$. % a note
        \begin{equation}
        x = \frac{a}{b} \label{eq:x}
        \end{equation}
        \section{Results}
        """#
        XCTAssertEqual(plain(TextSync.texStream(source)), "asshowninthejsccencodermapssjtoγresults")
    }

    func testPDFStreamJoinsHyphenatedWordsAndFoldsLigatures() {
        XCTAssertEqual(plain(TextSync.pdfStream("guid-\nance from the ﬁrst Café [12]")), "guidancefromthefirstcafe12")
    }

    func testStreamOffsetsPointBackIntoTheOriginal() {
        let source = #"Hello \emph{world}"#
        let stream = TextSync.texStream(source)
        let w = (source as NSString).range(of: "world").location
        XCTAssertEqual(stream.offset(at: stream.index(atOrAfter: w)), w)
    }

    /// The caret inside a long one-line paragraph lands on the same word on the page, despite citation numbers,
    /// a reference spelled as a command, and line-break hyphens the source does not have.
    func testCorrespondLandsOnTheSameWordAcrossLaTeXAndPDF() throws {
        let source = #"""
        The rate embedding proves consistently beneficial in \autoref{sec:ablation}. The rate embedding is given by a two-layer MLP~\cite{mlp} with a zero-initialized output layer, and every AdaGN block of the decoder is then conditioned on the sum of both embeddings.
        """#
        let page = """
        The rate embedding proves consistently beneficial in Section VI-C. The rate embed-
        ding is given by a two-layer MLP [31] with a zero-initialized output layer, and every
        AdaGN block of the decoder is then conditioned on the sum of both embeddings.
        """
        let tex = TextSync.texStream(source), pdf = TextSync.pdfStream(page)
        let caret = (source as NSString).range(of: "zero-initialized").location
        let match = try XCTUnwrap(TextSync.correspond(tex.index(atOrAfter: caret), from: tex, to: pdf))
        XCTAssertEqual(pdf.offset(at: match.index), (page as NSString).range(of: "zero-initialized").location)

        // And back: a click on "AdaGN" in the PDF finds it in the source.
        let click = (page as NSString).range(of: "AdaGN").location
        let back = try XCTUnwrap(TextSync.correspond(pdf.index(atOrAfter: click), from: pdf, to: tex))
        XCTAssertEqual(tex.offset(at: back.index), (source as NSString).range(of: "AdaGN").location)
    }

    /// The same phrase twice: the hint decides which copy is meant.
    func testPenaltyPicksTheRepeatedPhraseNearTheHint() throws {
        let sentence = "the transmission can stop at any layer boundary without signaling. "
        let page = sentence + String(repeating: "filler words that do not matter here. ", count: 20) + sentence
        let pdf = TextSync.pdfStream(page), tex = TextSync.texStream(sentence)
        let target = tex.index(atOrAfter: (sentence as NSString).range(of: "layer").location)
        let second = (page as NSString).range(of: "layer", options: .backwards).location
        let match = try XCTUnwrap(TextSync.correspond(target, from: tex, to: pdf) { Double(abs(pdf.offset(at: $0) - second)) / 50 })
        XCTAssertEqual(pdf.offset(at: match.index), second)
    }

    func testCorrespondGivesUpWhenTheTextIsAbsent() {
        let tex = TextSync.texStream("completely different words about rabbits and carrots")
        let pdf = TextSync.pdfStream("a page that talks only about wireless channels and noise")
        XCTAssertNil(TextSync.correspond(10, from: tex, to: pdf))
    }

    func testSentenceRangeStopsAtSentenceEndsButNotAbbreviations() {
        let text = "First one ends here. As shown in Fig. 3, the second sentence, e.g. this, runs on. Third."
        let caret = (text as NSString).range(of: "second").location
        let range = TextSync.sentenceRange(in: text, at: caret)
        XCTAssertEqual((text as NSString).substring(with: range), "As shown in Fig. 3, the second sentence, e.g. this, runs on.")
    }

    func testSentenceRangeStopsAtBlankLinesAndHandlesChinese() {
        let text = "标题\n\n第一句话。第二句话在这里。第三句。"
        let caret = (text as NSString).range(of: "在这里").location
        XCTAssertEqual((text as NSString).substring(with: TextSync.sentenceRange(in: text, at: caret)), "第二句话在这里。")
    }

    /// A figure added above a paragraph shifts its lines; the map carries old SyncTeX lines to where the text is now.
    func testLineMapFollowsInsertedAndDeletedLines() {
        let compiled = "a\nb\nc\nd\ne"
        let current = "a\n\\begin{figure}\n\\includegraphics{x}\n\\end{figure}\nb\nc\ne"
        let map = LineMap(compiled: compiled, current: current)
        XCTAssertEqual(map.current(forCompiled: 1), 1)
        XCTAssertEqual(map.current(forCompiled: 2), 5)
        XCTAssertEqual(map.current(forCompiled: 3), 6)
        XCTAssertEqual(map.current(forCompiled: 5), 7)
        XCTAssertEqual(map.compiled(forCurrent: 6), 3)
        XCTAssertEqual(map.compiled(forCurrent: 7), 5)
        // A line typed since the build maps to the compiled line before it.
        XCTAssertEqual(map.compiled(forCurrent: 3), 2)
    }

    func testParseBoxesReadsEveryRecord() {
        let output = """
        SyncTeX result begin
        Output:/tmp/a.pdf
        Page:2
        x:100.5
        y:200.25
        h:72.0
        v:202.0
        W:451.0
        H:7.5
        Output:/tmp/a.pdf
        Page:2
        x:100.5
        y:212.0
        h:72.0
        v:214.0
        W:451.0
        H:7.5
        SyncTeX result end
        """
        let boxes = SyncTeX.parseBoxes(output)
        XCTAssertEqual(boxes.count, 2)
        XCTAssertEqual(boxes[1], SyncBox(page: 2, x: 100.5, y: 212, h: 72, v: 214, width: 451, height: 7.5))
    }

    // MARK: PDF → source

    private func click(_ word: String, in pdf: String, occurrence: Int = 0) -> PDFClick {
        let ns = pdf as NSString; var range = ns.range(of: word)
        for _ in 0..<occurrence { range = ns.range(of: word, range: NSRange(location: NSMaxRange(range), length: ns.length - NSMaxRange(range))) }
        return PDFClick(stream: TextSync.pdfStream(pdf), pageText: pdf, character: range.location + word.count / 2)
    }
    private let body = (1...30).map { "Paragraph \($0) discusses a distinct aspect of the layered design in its own words, number \($0 * 7)." }.joined(separator: "\n")

    func testLocateIgnoresAFootnoteThatFollowsTheColumnEnd() throws {
        let file = URL(fileURLWithPath: "/tmp/main.tex")
        let tex = "\\author{Ann Author\\thanks{This work was supported by an example grant from the laboratory.}}\n\(body)\nSection five concludes the paper with a short outlook on future directions.\n"
        // On the page the column ends with the paragraph and the footnote sits right under it.
        let pdf = "Ann Author\n\(body)\nSection five concludes the paper with a short outlook on future directions.\nThis work was supported by an example grant from the laboratory.\n"
        // SyncTeX names the footnote's line.
        let found = try XCTUnwrap(TextSync.locate(clicked: click("directions", in: pdf), hint: (file, 1, tex), candidates: [(file, tex)]))
        let offset = try XCTUnwrap(found.offset)
        XCTAssertTrue(NSLocationInRange(offset, (tex as NSString).range(of: "directions")), "line \(found.line)")
    }

    func testLocateSearchesOtherFilesWhenSyncTeXNamesTheWrongOne() throws {
        let main = URL(fileURLWithPath: "/tmp/main.tex"), method = URL(fileURLWithPath: "/tmp/sections/method.tex")
        let mainText = "\(body)\nThe transmit power is normalized so that the average constraint holds everywhere.\n\\input{sections/method}\n"
        let methodText = "\\section{Proposed Method}\nThis section describes the encoder, the truncation rule and the training objective.\n"
        let pdf = "\(body)\nThe transmit power is normalized so that the average constraint holds everywhere.\nIII. PROPOSED METHOD\nThis section describes the encoder, the truncation rule and the training objective.\n"
        let found = try XCTUnwrap(TextSync.locate(clicked: click("normalized", in: pdf), hint: (method, 1, methodText), candidates: [(method, methodText), (main, mainText)]))
        XCTAssertEqual(found.file, main)
        XCTAssertTrue(NSLocationInRange(try XCTUnwrap(found.offset), (mainText as NSString).range(of: "normalized")))
    }

    func testLocatePutsAMacroAndAnEquationWhereTheSourceSpellsThem() throws {
        let file = URL(fileURLWithPath: "/tmp/main.tex")
        let tex = "\(body)\nWe propose \\name, a rateless scheme that adapts to the channel without feedback. The quality is defined as\n\\begin{align}\n  Q &= 10\\log_{10}\\frac{255^{2}}{\\mathrm{MSE}},\n\\end{align}\nwhere the error is averaged over all pixels of the reconstructed image.\n"
        let pdf = "\(body)\nWe propose LayerCast, a rateless scheme that adapts to the channel without feedback. The quality is defined as\nQ = 10 log10\n2552\nMSE , (1)\nwhere the error is averaged over all pixels of the reconstructed image.\n"
        let ns = tex as NSString
        let macro = try XCTUnwrap(TextSync.locate(clicked: click("LayerCast", in: pdf), hint: (file, 31, tex), candidates: [(file, tex)]))
        XCTAssertEqual(macro.offset, ns.range(of: "\\name").location)
        let equation = try XCTUnwrap(TextSync.locate(clicked: click("MSE", in: pdf), hint: (file, 34, tex), candidates: [(file, tex)]))
        XCTAssertEqual(equation.offset, ns.range(of: "MSE").location + 1)
        XCTAssertEqual(equation.line, 33)
    }

    func testLocateFindsATableCellByTheWordsAroundIt() throws {
        let file = URL(fileURLWithPath: "/tmp/main.tex")
        let tex = "\(body)\nOur model reaches a higher PSNR than every baseline at low rates.\n\\begin{table}\n\\caption{Quality on Kodak}\n\\begin{tabular}{lcc}\nMethod & PSNR$\\uparrow$ & LPIPS$\\downarrow$ \\\\\nDeepJSCC & 24.83 & 0.412 \\\\\n\\end{tabular}\n\\end{table}\n"
        // The float is printed at the top of the page, far from the paragraph, and SyncTeX names its last line.
        let pdf = "TABLE I\nQuality on Kodak\nMethod PSNR↑ LPIPS↓\nDeepJSCC 24.83 0.412\n\(body)\nOur model reaches a higher PSNR than every baseline at low rates.\n"
        let found = try XCTUnwrap(TextSync.locate(clicked: click("PSNR", in: pdf), hint: (file, 39, tex), candidates: [(file, tex)]))
        XCTAssertEqual(found.line, 35)
        XCTAssertEqual(found.offset, (tex as NSString).range(of: "PSNR$").location + 2)
    }

    func testLocateJoinsAWordHyphenatedAcrossLines() throws {
        let file = URL(fileURLWithPath: "/tmp/main.tex")
        let tex = "\(body)\nWe then describe a progressive extension of the scheme for unknown channels.\n"
        let pdf = "\(body)\nWe then describe a pro-\ngressive extension of the scheme for unknown channels.\n"
        let found = try XCTUnwrap(TextSync.locate(clicked: click("gressive", in: pdf), hint: (file, 31, tex), candidates: [(file, tex)]))
        XCTAssertEqual(found.offset, (tex as NSString).range(of: "progressive").location + 3 + 4)
    }

    func testLocateKeepsToTheSyncTeXLineForTextTheSourceDoesNotSpell() throws {
        let file = URL(fileURLWithPath: "/tmp/main.tex")
        let tex = "\(body)\n\\begin{figure}\n\\includegraphics{figures/pipeline.pdf}\n\\caption{Overview of the pipeline.}\n\\end{figure}\nThe decoder refines the image step by step.\n"
        // "Decoder" is a label drawn inside the included figure.
        let pdf = "Encoder Channel Decoder Softmax\nFig. 1. Overview of the pipeline.\n\(body)\nThe decoder refines the image step by step.\n"
        let found = try XCTUnwrap(TextSync.locate(clicked: click("Decoder", in: pdf), hint: (file, 32, tex), candidates: [(file, tex)]))
        // Not the "decoder" of the paragraph three lines on.
        XCTAssertEqual(found.line, 32)
    }

    func testAReferenceLeadsToItsBibEntry() throws {
        let bbl = "\\begin{thebibliography}{10}\n\n\\bibitem{shannon1948}\nC.~E. Shannon, ``A mathematical theory of communication,''\n  \\emph{Bell Syst. Tech. J.}, 1948.\n\n\\bibitem[Xu et~al.(2021)]{xu2021}\nJ.~Xu, ``Wireless image transmission,'' 2021.\n"
        XCTAssertEqual(TextSync.citationKey(inBBL: bbl, line: 5), "shannon1948")
        XCTAssertEqual(TextSync.citationKey(inBBL: bbl, line: 8), "xu2021")
        XCTAssertNil(TextSync.citationKey(inBBL: bbl, line: 1))
        let bib = "@article{xu2021,\n  title = {Wireless image transmission},\n}\n\n@article{shannon1948,\n  author = {Shannon, C. E.},\n  title = {A mathematical theory of communication},\n}\n"
        let entry = try XCTUnwrap(TextSync.bibEntry(key: "shannon1948", in: bib))
        XCTAssertEqual(entry.location, (bib as NSString).range(of: "@article{shannon1948").location)
        let pdf = "[1] C. E. Shannon, “A mathematical theory of communication,” Bell Syst. Tech. J., 1948.\n"
        XCTAssertEqual(TextSync.locate(clicked: click("mathematical", in: pdf), inEntry: entry, of: bib), (bib as NSString).range(of: "mathematical").location + 6)
        XCTAssertEqual(TextSync.locate(clicked: click("Bell", in: pdf), inEntry: entry, of: bib), entry.location)
    }
}
