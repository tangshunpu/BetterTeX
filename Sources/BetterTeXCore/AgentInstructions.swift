import Foundation

/// What BetterTeX tells both agents about where they run, so their replies can point at places the
/// app knows how to open: a source line in the editor (and its spot in the PDF) or a PDF page.
public enum AgentInstructions {
    public static let text = """
    You are working inside BetterTeX, a native LaTeX editor. The working directory is the LaTeX project; \
    BetterTeX compiles it automatically after edits and shows the PDF beside the source.

    When you refer to a specific place in the source — something you changed, found or recommend changing — \
    cite it as a Markdown link whose target is the path relative to the project plus a line number, for example \
    [intro.tex:42](sections/intro.tex:42) or [main.tex:10-14](main.tex:10). Clicking it opens that line in the \
    editor and scrolls the PDF to the matching spot. To point at a page of the compiled PDF, link it as \
    [page 3](pdf:3). In a final summary, cite the location of each change.

    Do not edit or commit compiled output (.pdf, .aux, .log, .synctex.gz, .fdb_latexmk); BetterTeX regenerates it.
    """

    /// A TOML basic string, as `codex -c key=value` parses values.
    public static func toml(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F { result += String(format: "\\u%04X", scalar.value) } else { result.unicodeScalars.append(scalar) }
            }
        }
        return result + "\""
    }
}

/// A place an agent's reply links to.
public enum AgentLocation: Equatable {
    case source(URL, line: Int?)
    case pdfPage(Int)

    /// Reads a link target or a plain "file.tex:42" mention. Accepts paths relative to the project,
    /// absolute paths and file URLs, with ":line", ":line-end", ":line:column" or "#L42". Source
    /// targets must exist in the file system; web links and anything else return nil.
    public static func parse(_ target: String, project: URL?) -> AgentLocation? {
        var text = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if let page = match(text, "^pdf:(?://page/)?(\\d+)$").first.flatMap({ Int($0) }), page > 0 { return .pdfPage(page) }
        if text.hasPrefix("file://") { text = URL(string: text)?.path ?? String(text.dropFirst(7)) }
        else if text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil { return nil }
        text = text.removingPercentEncoding ?? text
        var line: Int?
        let suffix = match(text, "(?:#L(\\d+)(?:-L?\\d+)?|:(\\d+)(?:[-:]\\d+)?)$")
        if let range = text.range(of: "(?:#L\\d+(?:-L?\\d+)?|:\\d+(?:[-:]\\d+)?)$", options: .regularExpression) {
            line = suffix.compactMap { Int($0) }.first; text = String(text[..<range.lowerBound])
        }
        guard !text.isEmpty else { return nil }
        let url: URL
        if text.hasPrefix("/") { url = URL(fileURLWithPath: text) }
        else if text.hasPrefix("~/") { url = URL(fileURLWithPath: NSString(string: text).expandingTildeInPath) }
        else if let project { url = project.appendingPathComponent(text) }
        else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return .source(url.standardizedFileURL, line: line.map { max(1, $0) })
    }
    /// Plain mentions such as "sections/intro.tex:42" or "refs.bib" in reply text, as ranges.
    public static func mentions(in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\w/.~-])(?:~?/)?(?:[\\w.-]+/)*[\\w.-]+\\.(?:tex|bib|sty|cls|bst|ltx|bbx|cbx|cfg|def)(?::\\d+(?:-\\d+)?)?(?![\\w])") else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }
    private static func match(_ text: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern), let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (1..<result.numberOfRanges).compactMap { Range(result.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
