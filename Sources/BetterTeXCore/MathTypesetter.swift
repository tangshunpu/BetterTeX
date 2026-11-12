import Foundation
import CoreGraphics

/// Finds TeX math in agent replies and typesets it with the local TeX installation.
public enum MathText {
    public struct Span: Equatable {
        public let range: NSRange
        public let tex: String
        public let display: Bool
    }
    private static let pattern = try! NSRegularExpression(pattern: [
        "(`+)[\\s\\S]*?\\1",                                    // inline code: left alone
        "\\$\\$([\\s\\S]+?)\\$\\$",                              // $$ display $$
        "\\\\\\[([\\s\\S]+?)\\\\\\]",                           // \[ display \]
        "\\\\\\(([\\s\\S]+?)\\\\\\)",                           // \( inline \)
        "(?<![\\\\$\\w])\\$(?![\\s$])((?:\\\\.|[^$\\n\\\\])+?)(?<![\\s\\\\])\\$(?![\\w$])" // $inline$
    ].joined(separator: "|"))

    /// Math spans in reading order; code spans and prices such as "$5 and $10" are skipped.
    public static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            for (group, display) in [(2, true), (3, true), (4, false), (5, false)] where match.range(at: group).location != NSNotFound {
                let tex = ns.substring(with: match.range(at: group)).trimmingCharacters(in: .whitespacesAndNewlines)
                return tex.isEmpty ? nil : Span(range: match.range, tex: tex, display: display)
            }
            return nil
        }
    }
}

/// Typesets formulas as one tight PDF page each. A formula TeX rejects comes back as nil.
public enum MathTypesetter {
    public struct Glyph: Equatable {
        /// Index of the page in `pdf` that holds this formula.
        public let page: Int
        /// Height above and depth below the baseline, in TeX points, not counting the border.
        public let height: Double
        public let depth: Double
    }
    /// Space left around each formula, in TeX points.
    public static let border = 1.0

    public static func document(_ formulas: [(tex: String, display: Bool)]) -> String {
        var body = ""
        for (index, formula) in formulas.enumerated() {
            let math = formula.display ? "$\\displaystyle \(formula.tex)$" : "$\(formula.tex)$"
            body += "\\typeout{BTXMATH:\(index):start}\\sbox\\btxbox{\(math)}"
            body += "\\typeout{BTXMATH:\(index):\\the\\ht\\btxbox:\\the\\dp\\btxbox}\\begin{preview}\\usebox\\btxbox\\end{preview}\n"
        }
        return """
        \\documentclass{article}
        \\usepackage{amsmath,amssymb,bm}
        \\usepackage[active,tightpage]{preview}
        \\setlength\\PreviewBorder{\(border)pt}
        \\newsavebox\\btxbox
        \\begin{document}
        \(body)\\end{document}
        """
    }

    /// Runs pdflatex once for all formulas. Returns the PDF and, per formula, its page or nil.
    public static func render(_ formulas: [(tex: String, display: Bool)], tools: Toolchain) throws -> [(pdf: Data, glyph: Glyph)?] {
        let batch = try compile(formulas, tools: tools)
        if pages(batch.pdf) == formulas.count { return batch.glyphs.map { glyph in glyph.map { (batch.pdf, $0) } } }
        // A formula that unbalances braces can swallow its neighbours; set each one alone instead.
        return formulas.map { formula in
            guard let single = try? compile([formula], tools: tools), pages(single.pdf) == 1, let glyph = single.glyphs[0] else { return nil }
            return (single.pdf, glyph)
        }
    }
    static func pages(_ pdf: Data) -> Int {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider) else { return 0 }
        return document.numberOfPages
    }
    static func compile(_ formulas: [(tex: String, display: Bool)], tools: Toolchain) throws -> (pdf: Data, glyphs: [Glyph?]) {
        guard let pdflatex = tools["pdflatex"] else { throw BetterTeXError.message(L10n.tr("未检测到 pdflatex。")) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bettertex-math-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try document(formulas).write(to: folder.appendingPathComponent("m.tex"), atomically: true, encoding: .utf8)
        // No shell escape; nonstop so one bad formula doesn't stop the others.
        _ = try ProcessRunner().run(pdflatex, ["-interaction=nonstopmode", "-no-shell-escape", "m.tex"],
                                    directory: folder, environment: tools.environment, timeout: 20)
        let log = (try? String(contentsOf: folder.appendingPathComponent("m.log"), encoding: .utf8)) ?? (try? String(contentsOf: folder.appendingPathComponent("m.log"), encoding: .isoLatin1)) ?? ""
        let pdf = try Data(contentsOf: folder.appendingPathComponent("m.pdf"))
        return (pdf, glyphs(log: log, count: formulas.count))
    }

    /// Reads each formula's size from the log; a formula with a TeX error between its markers is nil.
    /// Every formula still gets a page, so pages are numbered in formula order.
    public static func glyphs(log: String, count: Int) -> [Glyph?] {
        var result = [Glyph?](repeating: nil, count: count), current: Int?, failed = Set<Int>()
        // TeX wraps long log lines at 79 columns; join them back before reading markers.
        let lines = log.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("!"), let current { failed.insert(current) }
            guard line.hasPrefix("BTXMATH:") else { continue }
            let fields = line.dropFirst(8).components(separatedBy: ":")
            guard let index = Int(fields[0]), index < count else { continue }
            if fields.count >= 2, fields[1] == "start" { current = index; continue }
            guard fields.count >= 3, let height = points(fields[1]), let depth = points(fields[2]), !failed.contains(index) else { continue }
            result[index] = Glyph(page: index, height: height, depth: depth)
        }
        return result
    }
    private static func points(_ value: String) -> Double? { Double(value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "pt", with: "")) }
}
