import XCTest
@testable import BetterTeXCore

final class MathTypesetterTests: XCTestCase {
    func testFindsInlineAndDisplayMathButNotCodeOrPrices() {
        let text = #"层应写成 \(\bm{s}_1,\ldots,\bm{s}_L\)，不是 $L_1$；见 `$not$` 和 $5 and $10。"# + "\n\\[\n\\hat{\\bm{x}}_j\n\\]\n$$a^2$$"
        let spans = MathText.spans(in: text)
        XCTAssertEqual(spans.map(\.tex), [#"\bm{s}_1,\ldots,\bm{s}_L"#, "L_1", #"\hat{\bm{x}}_j"#, "a^2"])
        XCTAssertEqual(spans.map(\.display), [false, false, true, true])
    }
    func testLogMarkersGiveSizesAndFlagRejectedFormulas() {
        let log = """
        BTXMATH:0:start
        BTXMATH:0:6.94444pt:1.94444pt
        BTXMATH:1:start
        ! Undefined control sequence.
        BTXMATH:1:5.0pt:0.0pt
        BTXMATH:2:start
        BTXMATH:2:4.30554pt:0.0pt
        """
        let glyphs = MathTypesetter.glyphs(log: log, count: 3)
        XCTAssertEqual(glyphs[0], .init(page: 0, height: 6.94444, depth: 1.94444))
        XCTAssertNil(glyphs[1]); XCTAssertEqual(glyphs[2]?.page, 2)
    }
    func testTypesetsWithLocalTeX() throws {
        let tools = Toolchain.discover()
        try XCTSkipIf(tools["pdflatex"] == nil, "pdflatex not installed")
        let results = try MathTypesetter.render([(#"\bm{s}_l \rightarrow \hat{\bm{s}}_l"#, false), (#"\undefinedmacro x"#, false), (#"\frac{a}{b}"#, true)], tools: tools)
        XCTAssertNotNil(results[0]); XCTAssertNil(results[1]); XCTAssertNotNil(results[2])
        XCTAssertGreaterThan(results[2]!.glyph.depth, 0)
    }
}
