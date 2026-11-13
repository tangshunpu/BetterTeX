import Foundation

/// Toggles LaTeX `%` line comments over the lines a selection touches.
public enum LineComment {
    public struct Edit: Equatable {
        /// The range of whole lines to replace, in UTF-16 units of the original text.
        public let range: NSRange
        public let replacement: String
        /// The selection to apply after the replacement.
        public let selection: NSRange
    }

    /// Comments every touched line, or uncomments them when all non-blank lines are already comments.
    /// Comment markers are inserted at the smallest indentation so the block stays aligned.
    public static func toggle(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        var end = NSMaxRange(selection)
        // A selection that ends at the very start of a line does not include that line.
        if selection.length > 0, end > selection.location, end <= ns.length, ns.character(at: end - 1) == 0x0A { end -= 1 }
        let block = ns.lineRange(for: NSRange(location: selection.location, length: max(0, end - selection.location)))
        let original = ns.substring(with: block)
        var lines = original.components(separatedBy: "\n")
        let trailingNewline = original.hasSuffix("\n")
        if trailingNewline { lines.removeLast() }

        func indent(_ line: String) -> Int { line.utf16.prefix { $0 == 0x20 || $0 == 0x09 }.count }
        func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }
        let content = lines.filter { !isBlank($0) }
        let uncomment = !content.isEmpty && content.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("%") }
        let column = content.map(indent).min() ?? 0

        // Each line edit is (offset in original text, removed length, inserted length).
        var edits: [(Int, Int, Int)] = []
        var offset = block.location
        let rewritten = lines.map { line -> String in
            defer { offset += (line as NSString).length + 1 }
            let utf16 = Array(line.utf16)
            if uncomment {
                let start = indent(line)
                guard start < utf16.count, utf16[start] == 0x25 else { return line }
                let removed = start + 1 < utf16.count && utf16[start + 1] == 0x20 ? 2 : 1
                edits.append((offset + start, removed, 0))
                return String(utf16CodeUnits: utf16, count: start) + String(utf16CodeUnits: Array(utf16[(start + removed)...]), count: utf16.count - start - removed)
            }
            guard !isBlank(line) || content.isEmpty else { return line }
            let at = min(column, utf16.count)
            edits.append((offset + at, 0, 2))
            return String(utf16CodeUnits: utf16, count: at) + "% " + String(utf16CodeUnits: Array(utf16[at...]), count: utf16.count - at)
        }
        let replacement = rewritten.joined(separator: "\n") + (trailingNewline ? "\n" : "")

        /// `stayBefore` keeps an index sitting exactly at an insertion point in front of the inserted marker.
        func map(_ index: Int, stayBefore: Bool = false) -> Int {
            var shift = 0
            for (position, removed, inserted) in edits {
                if stayBefore, removed == 0, index == position { break }
                if index >= position + removed { shift += inserted - removed }
                else if index > position { shift += position - index; break }
                else { break }
            }
            return index + shift
        }
        let location = map(selection.location, stayBefore: selection.length > 0)
        let newSelection = selection.length == 0
            ? NSRange(location: location, length: 0)
            : NSRange(location: location, length: max(0, map(NSMaxRange(selection)) - location))
        return Edit(range: block, replacement: replacement, selection: newSelection)
    }
}
