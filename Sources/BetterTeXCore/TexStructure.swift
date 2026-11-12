import Foundation

/// The document skeleton the editor draws: sectioning commands and float environments,
/// located by UTF-16 ranges so the view can paint rules, bands and scope bars.
public struct TexStructure: Equatable {
    public enum HeadingKind: String, CaseIterable {
        case part, chapter, section, subsection, subsubsection, paragraph
        /// 0 is the outermost level; a heading's scope ends at the next heading of the same or lower depth.
        public var depth: Int { Self.allCases.firstIndex(of: self)! }
    }
    public enum BlockKind: String {
        case figure, table, algorithm
        /// `figure*`, `subfigure`, `wraptable`, `sidewaysfigure` … map onto their base kind.
        static func of(_ environment: String) -> BlockKind? {
            let name = environment.lowercased().replacingOccurrences(of: "*", with: "")
            if name.hasPrefix("sub") { return nil }
            if name.hasSuffix("figure") { return .figure }
            if name.hasSuffix("table") { return .table }
            if name == "algorithm" || name == "algorithm2e" { return .algorithm }
            return nil
        }
    }
    public struct Heading: Equatable {
        public let kind: HeadingKind
        /// The whole line holding the command (including its line break).
        public let line: NSRange
        /// The text inside the braces, and where it sits in the source.
        public let title: String
        public let titleRange: NSRange
        /// "2.1"-style number, empty for starred headings and parts.
        public let number: String
        /// From the heading's line to the start of the next heading at the same or an outer level.
        public internal(set) var scope: NSRange
    }
    public struct Block: Equatable {
        public let kind: BlockKind
        /// From the start of the `\begin` line to the end of the matching `\end` line.
        public let range: NSRange
        /// The `\begin` line alone.
        public let header: NSRange
        /// 1-based count per kind, as LaTeX numbers them in order of appearance.
        public let number: Int
        public let caption: String?
    }
    public var headings: [Heading] = []
    public var blocks: [Block] = []

    public init() {}

    private static let pattern = try! NSRegularExpression(
        pattern: "\\\\(part|chapter|section|subsection|subsubsection|paragraph)(\\*?)[ \\t]*(?:\\[[^\\]\\n]*\\])?[ \\t]*\\{|\\\\(begin|end)[ \\t]*\\{([a-zA-Z0-9]+\\*?)\\}|\\\\caption\\*?[ \\t]*(?:\\[[^\\]\\n]*\\])?[ \\t]*\\{")

    public static func scan(_ text: String) -> TexStructure {
        let ns = text as NSString
        var result = TexStructure()
        var counters = [Int](repeating: 0, count: HeadingKind.allCases.count)
        var floatCounts: [BlockKind: Int] = [:]
        // Open float environments: kind, begin line, environment name, caption found so far.
        var open: [(kind: BlockKind, start: NSRange, name: String, caption: String?)] = []
        let usesChapters = text.contains("\\chapter")
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let lineRange = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
            if isCommented(ns, at: match.range.location, lineStart: lineRange.location) { continue }
            if match.range(at: 1).location != NSNotFound {
                guard let kind = HeadingKind(rawValue: ns.substring(with: match.range(at: 1))) else { continue }
                let starred = match.range(at: 2).length > 0
                let titleRange = braced(ns, from: NSMaxRange(match.range))
                var number = ""
                if !starred && kind != .part && kind != .paragraph {
                    counters[kind.depth] += 1
                    for deeper in (kind.depth + 1)..<counters.count { counters[deeper] = 0 }
                    let first = usesChapters ? HeadingKind.chapter.depth : HeadingKind.section.depth
                    if kind.depth >= first { number = counters[first...kind.depth].map(String.init).joined(separator: ".") }
                }
                result.headings.append(Heading(kind: kind, line: lineRange, title: clean(ns.substring(with: titleRange)), titleRange: titleRange, number: number, scope: lineRange))
            } else if match.range(at: 3).location != NSNotFound {
                let name = ns.substring(with: match.range(at: 4))
                guard let kind = BlockKind.of(name) else { continue }
                if ns.substring(with: match.range(at: 3)) == "begin" {
                    open.append((kind, lineRange, name, nil))
                } else if let index = open.lastIndex(where: { $0.name == name }) {
                    let begin = open.remove(at: index)
                    floatCounts[kind, default: 0] += 1
                    let range = NSRange(location: begin.start.location, length: NSMaxRange(lineRange) - begin.start.location)
                    result.blocks.append(Block(kind: kind, range: range, header: begin.start, number: floatCounts[kind]!, caption: begin.caption))
                }
            } else if !open.isEmpty, open[open.count - 1].caption == nil {
                open[open.count - 1].caption = clean(ns.substring(with: braced(ns, from: NSMaxRange(match.range))))
            }
        }
        // Floats finish at their \end, so restore source order for drawing and numbering by position.
        result.blocks.sort { $0.range.location < $1.range.location }
        var renumber: [BlockKind: Int] = [:]
        result.blocks = result.blocks.map { block in
            renumber[block.kind, default: 0] += 1
            return Block(kind: block.kind, range: block.range, header: block.header, number: renumber[block.kind]!, caption: block.caption)
        }
        let end = endOfBody(ns)
        for index in result.headings.indices {
            let heading = result.headings[index]
            let next = result.headings[(index + 1)...].first { $0.kind.depth <= heading.kind.depth }?.line.location ?? max(end, NSMaxRange(heading.line))
            result.headings[index].scope = NSRange(location: heading.line.location, length: max(next, NSMaxRange(heading.line)) - heading.line.location)
        }
        return result
    }

    /// Headings whose scope holds `offset`, outermost first: the "where am I" path.
    public func path(at offset: Int) -> [Heading] {
        headings.filter { heading in
            let end = NSMaxRange(heading.scope)
            // A caret at the very end of a scope (e.g. end of file) still belongs to it, unless the next heading starts there.
            return offset >= heading.scope.location && (offset < end || offset == end && !headings.contains { $0.line.location == end })
        }
    }
    /// The float environment holding `offset`, if any.
    public func block(at offset: Int) -> Block? {
        blocks.last { offset >= $0.range.location && offset < NSMaxRange($0.range) }
    }

    private static func isCommented(_ ns: NSString, at location: Int, lineStart: Int) -> Bool {
        var index = lineStart
        while index < location {
            let c = ns.character(at: index)
            if c == 92 { index += 2; continue }  // backslash escapes the next char
            if c == 37 { return true }           // %
            index += 1
        }
        return false
    }
    /// The balanced-brace argument starting just after an opening `{`.
    private static func braced(_ ns: NSString, from start: Int) -> NSRange {
        var depth = 1, index = start
        while index < ns.length {
            let c = ns.character(at: index)
            if c == 92 { index += 2; continue }
            if c == 123 { depth += 1 } else if c == 125 { depth -= 1; if depth == 0 { break } }
            index += 1
        }
        return NSRange(location: start, length: min(index, ns.length) - start)
    }
    private static func clean(_ title: String) -> String {
        title.replacingOccurrences(of: "\\\\(label|cite|ref|footnote)\\{[^}]*\\}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\\\[a-zA-Z]+\\*?\\s*|[{}]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
    /// The last section runs to \end{document}, or to the end of the file when there is none.
    private static func endOfBody(_ ns: NSString) -> Int {
        let found = ns.range(of: "\\end{document}")
        return found.location == NSNotFound ? ns.length : found.location
    }
}
