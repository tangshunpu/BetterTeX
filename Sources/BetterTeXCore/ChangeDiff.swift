import Foundation

/// A word-level comparison of two pieces of text that ignores how they are spaced or wrapped.
///
/// Text is cut into tokens — a TeX control word (`\cite`), a run of letters or digits, a single
/// CJK character, or a single symbol — and whitespace only separates tokens. Two texts that differ
/// only in spacing or line breaks therefore compare equal, and each change is as small as a token.
public enum WordDiff {
    public enum Kind: Equatable { case equal, inserted, deleted }
    public struct Segment: Equatable {
        public var kind: Kind
        /// The text as written, including the spacing inside the run (from the new text for
        /// `equal` and `inserted`, from the old text for `deleted`).
        public var text: String
        /// Set on changed segments that an agent is known to have made.
        public var author: AgentProvider?
        /// Whether whitespace came just before this run in its source text, so it can be shown
        /// apart from the previous run (or joined to it, as in `\\bm{s}` → `\\bm{y}`).
        public var spaceBefore: Bool
        public init(_ kind: Kind, _ text: String, author: AgentProvider? = nil, spaceBefore: Bool = false) { self.kind = kind; self.text = text; self.author = author; self.spaceBefore = spaceBefore }
    }

    struct Token { let text: Substring; let range: Range<String.Index> }

    static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var index = text.startIndex
        func isWord(_ c: Character) -> Bool { (c.isLetter || c.isNumber || c == "_") && !isCJK(c) }
        func isCJK(_ c: Character) -> Bool {
            guard let scalar = c.unicodeScalars.first else { return false }
            switch scalar.value {
            case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF: return true
            default: return false
            }
        }
        while index < text.endIndex {
            let c = text[index]
            if c.isWhitespace { index = text.index(after: index); continue }
            var end = text.index(after: index)
            if c == "\\" {
                // A control word, or a control symbol such as `\\` or `\%`.
                if end < text.endIndex, text[end].isLetter {
                    while end < text.endIndex, text[end].isLetter { end = text.index(after: end) }
                } else if end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            } else if isWord(c) {
                while end < text.endIndex, isWord(text[end]) { end = text.index(after: end) }
            }
            result.append(Token(text: text[index..<end], range: index..<end))
            index = end
        }
        return result
    }

    /// Compares `old` with `new`. Very large inputs fall back to one replacement.
    public static func diff(old: String, new: String) -> [Segment] {
        let a = tokens(old), b = tokens(new)
        // Trim the common head and tail so the quadratic part only sees the changed middle.
        var head = 0
        while head < a.count, head < b.count, a[head].text == b[head].text { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail].text == b[b.count - 1 - tail].text { tail += 1 }
        let midA = Array(a[head..<(a.count - tail)]), midB = Array(b[head..<(b.count - tail)])

        // Edit script: each step is an equal pair (i, j), a deletion of a[i] or an insertion of b[j].
        enum Op { case equal(Int, Int), deleted(Int), inserted(Int) }
        var ops: [Op] = (0..<head).map { .equal($0, $0) }
        if midA.count * midB.count > 4_000_000 {
            ops += midA.indices.map { .deleted(head + $0) } + midB.indices.map { .inserted(head + $0) }
        } else {
            let n = midA.count, m = midB.count
            var lcs = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
            if n > 0, m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        lcs[i][j] = midA[i].text == midB[j].text ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < n || j < m {
                if i < n, j < m, midA[i].text == midB[j].text { ops.append(.equal(head + i, head + j)); i += 1; j += 1 }
                else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] { ops.append(.inserted(head + j)); j += 1 }
                else { ops.append(.deleted(head + i)); i += 1 }
            }
        }
        ops += (0..<tail).map { .equal(a.count - tail + $0, b.count - tail + $0) }

        // A lone symbol kept between two edits ("x=y" → "u=v") is folded into them, so a
        // rewritten phrase reads as one change instead of confetti.
        func isEqual(_ op: Op) -> Bool { if case .equal = op { return true }; return false }
        var changed = ops.map { !isEqual($0) }
        for k in ops.indices.dropFirst().dropLast() where !changed[k] && changed[k - 1] && changed[k + 1] {
            if case .equal(let i, _) = ops[k], a[i].text.count == 1, let c = a[i].text.first, !c.isLetter, !c.isNumber { changed[k] = true }
        }

        // Each maximal run of changes becomes a deletion (cut from the old text) followed by an
        // insertion (cut from the new text); each run of matches is cut from the new text. Cutting
        // whole spans keeps the spacing as the author wrote it.
        var segments: [Segment] = []
        var k = 0
        while k < ops.count {
            var end = k
            while end + 1 < ops.count, changed[end + 1] == changed[k] { end += 1 }
            var oldSpan: (Int, Int)?, newSpan: (Int, Int)?
            for op in ops[k...end] {
                switch op {
                case .equal(let i, let j): oldSpan = (oldSpan?.0 ?? i, i); newSpan = (newSpan?.0 ?? j, j)
                case .deleted(let i): oldSpan = (oldSpan?.0 ?? i, i)
                case .inserted(let j): newSpan = (newSpan?.0 ?? j, j)
                }
            }
            func cut(_ kind: Kind, _ text: String, _ list: [Token], _ span: (Int, Int)) -> Segment {
                let start = list[span.0].range.lowerBound
                let space = start > text.startIndex && text[text.index(before: start)].isWhitespace
                return Segment(kind, String(text[start..<list[span.1].range.upperBound]), spaceBefore: space)
            }
            if changed[k] {
                if let oldSpan { segments.append(cut(.deleted, old, a, oldSpan)) }
                if let newSpan { segments.append(cut(.inserted, new, b, newSpan)) }
            } else if let newSpan { segments.append(cut(.equal, new, b, newSpan)) }
            k = end + 1
        }
        return segments
    }

    /// Collapses whitespace so texts that differ only in spacing compare equal.
    public static func normalized(_ text: String) -> String {
        tokens(text).map(\.text).joined(separator: " ")
    }
}

/// Remembers which pieces of a file each agent wrote or removed, so a later comparison with the
/// last commit can say who made a change. Pieces are matched by text, ignoring spacing.
public final class ChangeAuthorship {
    struct Edit { let author: AgentProvider; let inserted: [String]; let deleted: [String] }
    private var edits: [String: [Edit]] = [:]
    public init() {}

    /// Notes the difference between two versions of `path` as `author`'s work.
    public func record(path: String, old: String, new: String, by author: AgentProvider) {
        let segments = WordDiff.diff(old: old, new: new)
        let inserted = segments.filter { $0.kind == .inserted }.map { WordDiff.normalized($0.text) }.filter { !$0.isEmpty }
        let deleted = segments.filter { $0.kind == .deleted }.map { WordDiff.normalized($0.text) }.filter { !$0.isEmpty }
        guard !inserted.isEmpty || !deleted.isEmpty else { return }
        edits[path, default: []].append(Edit(author: author, inserted: inserted, deleted: deleted))
        if edits[path]!.count > 200 { edits[path]!.removeFirst(edits[path]!.count - 200) }
    }

    public func forget(path: String) { edits[path] = nil }

    /// Fills in `author` on each changed segment that matches what an agent wrote (or removed).
    /// The newest matching edit wins.
    public func attribute(_ segments: [WordDiff.Segment], path: String) -> [WordDiff.Segment] {
        guard let history = edits[path], !history.isEmpty else { return segments }
        return segments.map { segment in
            guard segment.kind != .equal else { return segment }
            let text = WordDiff.normalized(segment.text)
            guard !text.isEmpty else { return segment }
            var copy = segment
            for edit in history.reversed() {
                let pieces = segment.kind == .inserted ? edit.inserted : edit.deleted
                if pieces.contains(where: { Self.matches(text, $0) }) { copy.author = edit.author; break }
            }
            return copy
        }
    }

    /// A segment matches a recorded piece when one contains the other and the shorter is not a
    /// trivial fragment of the longer (a lone "the" inside a rewritten paragraph does not count).
    static func matches(_ text: String, _ piece: String) -> Bool {
        if text == piece { return true }
        let (short, long) = text.count <= piece.count ? (text, piece) : (piece, text)
        guard long.contains(short) else { return false }
        return short == text ? true : short.count * 2 >= long.count
    }
}
