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
}
