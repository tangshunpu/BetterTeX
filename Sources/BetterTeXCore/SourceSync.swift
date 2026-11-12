import Foundation

/// Comparable text (letters and digits, case and accents folded) with the UTF-16 offset each character came from.
/// LaTeX source and PDF page text are both reduced to this form so the same sentence can be found in either.
public struct TextStream {
    public private(set) var characters: [Character] = []
    public private(set) var offsets: [Int] = []
    public init() {}
    public var count: Int { characters.count }
    mutating func append(_ character: Character, at offset: Int) { characters.append(character); offsets.append(offset) }
    /// The first character at or after a UTF-16 offset of the original text.
    public func index(atOrAfter offset: Int) -> Int {
        var low = 0, high = offsets.count
        while low < high { let mid = (low + high) / 2; if offsets[mid] < offset { low = mid + 1 } else { high = mid } }
        return low
    }
    public func offset(at index: Int) -> Int {
        if offsets.isEmpty { return 0 }
        return index < offsets.count ? offsets[max(0, index)] : offsets[offsets.count - 1] + 1
    }
}

/// Where a position in one text lands in another, and how strongly the surrounding text agrees.
public struct TextMatch: Equatable {
    public let index: Int
    public let weight: Double
    /// The two texts agree character for character at the position itself, not only around it.
    public let exact: Bool
    public init(index: Int, weight: Double, exact: Bool = false) { self.index = index; self.weight = weight; self.exact = exact }
    /// Ranks matches: one that only lines up with nearby text (the position itself is spelled differently, or
    /// belongs to a neighbouring column, float or footnote) counts for far less than one that agrees on the spot.
    public func score(penalty: Double = 0) -> Double { weight * (exact ? 1 : 0.1) / (1 + penalty) }
}

public enum TextSync {
    // MARK: Building streams

    /// Page text as PDFKit reports it. Hyphens and line breaks drop out, so a word split across lines joins up again.
    public static func pdfStream(_ text: String) -> TextStream {
        var stream = TextStream(); var offset = 0
        for character in text { appendFolded(character, at: offset, to: &stream); offset += character.utf16.count }
        return stream
    }

    /// The words a LaTeX source puts on the page: commands, comments, references and display maths are left out,
    /// command arguments that are printed (\textbf{…}, \section{…}, \caption{…}) are kept.
    public static func texStream(_ text: String) -> TextStream {
        let characters = Array(text)
        var offsets = [Int](); offsets.reserveCapacity(characters.count + 1)
        var running = 0
        for character in characters { offsets.append(running); running += character.utf16.count }
        offsets.append(running)
        let count = characters.count
        var stream = TextStream(); var index = 0

        func skipSpaces(from start: Int) -> Int {
            var position = start
            while position < count, characters[position] == " " || characters[position] == "\t" { position += 1 }
            return position
        }
        /// Skips one bracketed group right after `index`, if there is one.
        func skipGroup(_ open: Character, _ close: Character) -> Bool {
            var position = skipSpaces(from: index)
            guard position < count, characters[position] == open else { return false }
            var depth = 0
            while position < count {
                let character = characters[position]
                if character == "\\" { position += 2; continue }
                if character == open { depth += 1 } else if character == close { depth -= 1; if depth == 0 { position += 1; break } }
                position += 1
            }
            index = min(position, count); return true
        }
        func readName() -> String {
            var position = skipSpaces(from: index)
            guard position < count, characters[position] == "{" else { return "" }
            position += 1; var name = ""
            while position < count, characters[position] != "}" { name.append(characters[position]); position += 1 }
            index = min(position + 1, count); return name
        }
        /// Moves past the next occurrence of `marker`, or to the end.
        func skip(past marker: String) {
            let pattern = Array(marker)
            var position = index
            while position + pattern.count <= count {
                if characters[position] == pattern[0], Array(characters[position..<(position + pattern.count)]) == pattern { index = position + pattern.count; return }
                position += 1
            }
            index = count
        }

        while index < count {
            let character = characters[index]
            if character == "%" { while index < count, characters[index] != "\n" { index += 1 }; continue }
            if character == "$" {
                if index + 1 < count, characters[index + 1] == "$" { index += 2; skip(past: "$$"); continue }
                index += 1; continue
            }
            if character == "\\" {
                index += 1
                guard index < count else { break }
                let next = characters[index]
                guard next.isASCII, next.isLetter else {
                    if next == "[" { index += 1; skip(past: "\\]"); continue }
                    index += 1; continue
                }
                let start = index - 1
                var name = ""
                while index < count, characters[index].isASCII, characters[index].isLetter { name.append(characters[index]); index += 1 }
                if index < count, characters[index] == "*" { index += 1 }
                switch name {
                case "begin":
                    let environment = readName()
                    let bare = environment.hasSuffix("*") ? String(environment.dropLast()) : environment
                    if displayEnvironments.contains(bare) { skip(past: "\\end{\(environment)}"); continue }
                    while skipGroup("[", "]") {}
                    if layoutEnvironments.contains(bare) { _ = skipGroup("{", "}") }
                case "end": _ = readName()
                case "href": _ = skipGroup("{", "}")
                default:
                    if droppedCommands.contains(name) { while skipGroup("[", "]") || skipGroup("{", "}") {} }
                    else if let letter = greekLetters[name] { appendFolded(letter, at: offsets[start], to: &stream) }
                }
                continue
            }
            appendFolded(character, at: offsets[index], to: &stream)
            index += 1
        }
        return stream
    }

    private static func appendFolded(_ character: Character, at offset: Int, to stream: inout TextStream) {
        if character.isASCII {
            if character.isLetter { stream.append(Character(character.lowercased()), at: offset) }
            else if character.isNumber { stream.append(character, at: offset) }
            return
        }
        // Ligatures (ﬁ), full-width forms and accents fold to their plain letters.
        let folded = String(character).precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        for piece in folded where piece.isLetter || piece.isNumber { stream.append(piece, at: offset) }
    }

    private static let displayEnvironments: Set<String> = ["equation", "align", "alignat", "gather", "multline", "flalign", "eqnarray", "displaymath", "tikzpicture", "comment"]
    private static let layoutEnvironments: Set<String> = ["tabular", "tabularx", "tabulary", "array", "minipage", "wrapfigure", "subfigure", "longtable", "multicols"]
    private static let droppedCommands: Set<String> = [
        "cite", "citep", "citet", "citealp", "citealt", "citeauthor", "citeyear", "nocite", "parencite", "textcite", "autocite",
        "ref", "eqref", "autoref", "cref", "Cref", "pageref", "nameref", "label",
        "includegraphics", "input", "include", "bibliography", "bibliographystyle", "addbibresource", "usepackage", "documentclass",
        "newcommand", "renewcommand", "providecommand", "newenvironment", "renewenvironment", "def", "let", "DeclareMathOperator",
        "vspace", "hspace", "setlength", "addtolength", "setcounter", "addtocounter", "hypersetup", "graphicspath",
        "pagestyle", "thispagestyle", "pagenumbering", "color", "definecolor", "linespread", "resizebox", "scalebox"
    ]
    private static let greekLetters: [String: Character] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω"
    ]

    // MARK: Matching

    private struct Pair: Hashable { let first: Character; let second: Character }

    /// Finds where `index` of `source` lands in `target`.
    ///
    /// Short runs of characters around the position are looked up in the target and each hit votes for an
    /// alignment shift. Text the two sides do not share (citation numbers on the page, a reference word the source
    /// spells as a command) only costs the runs that overlap it, and repeated phrases are told apart by the runs
    /// further out. `penalty` ranks otherwise equal alignments, for example by distance from a SyncTeX hint.
    public static func correspond(_ index: Int, from source: TextStream, to target: TextStream, penalty: ((Int) -> Double)? = nil) -> TextMatch? {
        guard source.count >= 4, target.count >= 4 else { return nil }
        let position = min(max(0, index), source.count - 1)
        var table: [Pair: [Int]] = [:]
        for start in 0..<(target.count - 1) { table[Pair(first: target.characters[start], second: target.characters[start + 1]), default: []].append(start) }

        /// How many characters agree in a row through `position` when the texts are shifted by `delta`.
        func agreement(_ delta: Int) -> Int {
            let landing = position + delta
            guard landing >= 0, landing < target.count, source.characters[position] == target.characters[landing] else { return 0 }
            var right = 1, left = 0
            while right < 12, position + right < source.count, landing + right < target.count, source.characters[position + right] == target.characters[landing + right] { right += 1 }
            while left < 12, position - left - 1 >= 0, landing - left - 1 >= 0, source.characters[position - left - 1] == target.characters[landing - left - 1] { left += 1 }
            return left + right
        }
        var fallback: TextMatch?
        for (length, minimum) in [(10, 1.0), (7, 1.2), (5, 2.0)] {
            var votes: [(delta: Int, weight: Double, reach: Int)] = []
            for shift in stride(from: -60, through: 60, by: 3) {
                let start = position + shift
                guard start >= 0, start + length <= source.count else { continue }
                let gram = source.characters[start..<(start + length)]
                guard let hits = table[Pair(first: gram[start], second: gram[start + 1])], hits.count <= 400 else { continue }
                let weight = 1 / (1 + Double(abs(shift)) / 15)
                for hit in hits where hit + length <= target.count && target.characters[hit..<(hit + length)].elementsEqual(gram) {
                    votes.append((hit - start, weight, abs(shift)))
                }
            }
            guard !votes.isEmpty else { continue }
            votes.sort { $0.delta < $1.delta }
            var clusters: [[(delta: Int, weight: Double, reach: Int)]] = [[votes[0]]]
            for vote in votes.dropFirst() {
                if vote.delta - clusters[clusters.count - 1].last!.delta <= 6 { clusters[clusters.count - 1].append(vote) } else { clusters.append([vote]) }
            }
            var best: (score: Double, match: TextMatch)?
            for cluster in clusters {
                let weight = cluster.reduce(0) { $0 + $1.weight }
                guard weight >= minimum else { continue }
                // An alignment that agrees through the position itself fixes the exact character.
                var agreed: (delta: Int, run: Int)?; var tried = Set<Int>()
                for vote in cluster.sorted(by: { $0.reach < $1.reach }) where tried.insert(vote.delta).inserted {
                    let run = agreement(vote.delta)
                    if run > (agreed?.run ?? 0) { agreed = (vote.delta, run) }
                    if tried.count >= 8 { break }
                }
                let match: TextMatch
                if let agreed, agreed.run >= 4 {
                    match = TextMatch(index: position + agreed.delta, weight: weight, exact: true)
                } else {
                    // Otherwise the run closest to the position places it as well as the shared text allows.
                    let anchor = cluster.min { $0.reach < $1.reach }!
                    match = TextMatch(index: min(max(0, position + anchor.delta), target.count - 1), weight: weight)
                }
                let score = match.score(penalty: penalty?(match.index) ?? 0)
                if best == nil || score > best!.score { best = (score, match) }
            }
            guard let best else { continue }
            if best.match.exact { return best.match }
            if fallback == nil { fallback = best.match }
        }
        return fallback
    }

    // MARK: PDF → source

    private static func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    /// Where a click in the PDF lands in the sources. `hint` is the file and (current) line SyncTeX named.
    /// SyncTeX is often a paragraph off and at times names a neighbouring file, so the clicked words are looked
    /// for in every candidate and the hint only ranks the places found. `offset` is nil when only a line is known.
    public static func locate(clicked: (stream: TextStream, index: Int, word: String)?, hint: (file: URL, line: Int, text: String)?,
                              candidates: [(file: URL, text: String)]) -> (file: URL, offset: Int?, line: Int, text: String)? {
        let fallback: (file: URL, offset: Int?, line: Int, text: String)? = hint.map { ($0.file, nil, $0.line, $0.text) }
        guard let clicked else { return fallback }
        var files: [(file: URL, text: String, hint: Int?)] = hint.map { [($0.file, $0.text, $0.line)] } ?? []
        let hinted = hint.map { canonical($0.file) }
        var seen: Set<String> = hinted.map { [$0] } ?? []
        for candidate in candidates where seen.insert(canonical(candidate.file)).inserted { files.append((candidate.file, candidate.text, nil)) }

        var best: (file: URL, text: String, stream: TextStream, starts: [Int], hint: Int?, match: TextMatch, score: Double)?
        for (file, source, line) in files where !source.isEmpty {
            let stream = texStream(source); let starts = lineStarts(source)
            let penalty: (Int) -> Double
            if let line { penalty = { min(3, Double(abs(TextSync.line(of: stream.offset(at: $0), starts: starts) - line)) / 12) } }
            else { penalty = { _ in hint == nil ? 0 : 1 } }
            guard let match = correspond(clicked.index, from: clicked.stream, to: stream, penalty: penalty) else { continue }
            let score = match.score(penalty: penalty(match.index))
            if best == nil || score > best!.score { best = (file, source, stream, starts, line, match, score) }
            // A firm hit on the clicked word in the file SyncTeX named settles it.
            if line != nil, match.exact, match.weight >= 3 { break }
        }
        guard let best else { return fallback }
        let offset = best.match.exact ? best.stream.offset(at: best.match.index)
            : settle(clicked: clicked, landing: best.match.index, in: best.stream, text: best.text, starts: best.starts, hint: best.hint)
        return (best.file, offset, line(of: offset, starts: best.starts), best.text)
    }

    /// Places a click on something the source spells differently (a macro, an equation, a generated heading or
    /// number). The shared text on either side bounds a stretch of source; inside it the clicked word is looked
    /// for literally, then the SyncTeX line is taken if it falls there, then the nearer end.
    private static func settle(clicked: (stream: TextStream, index: Int, word: String), landing: Int, in target: TextStream,
                               text: String, starts: [Int], hint: Int?) -> Int {
        let source = clicked.stream, position = min(max(0, clicked.index), source.count - 1), base = landing - position
        let ns = text as NSString, gram = 6
        func agrees(_ start: Int, _ delta: Int) -> Bool {
            guard start >= 0, start + gram <= source.count, start + delta >= 0, start + delta + gram <= target.count else { return false }
            for step in 0..<gram where source.characters[start + step] != target.characters[start + delta + step] { return false }
            return true
        }
        func delta(at start: Int) -> Int? {
            if agrees(start, base) { return base }
            for spread in 1...30 { if agrees(start, base - spread) { return base - spread }; if agrees(start, base + spread) { return base + spread } }
            return nil
        }
        // The last shared character before the click and the first one after it, as indices of `target`.
        var left: (reach: Int, index: Int)?, right: (reach: Int, index: Int)?
        for end in stride(from: position - 1, through: max(gram - 1, position - 90), by: -1) {
            if let shift = delta(at: end - gram + 1) { left = (position - end, end + shift); break }
        }
        if position + 1 < source.count {
            for start in (position + 1)...min(source.count - 1, position + 90) {
                if let shift = delta(at: start) { right = (start - position, start + shift); break }
            }
        }
        // Sides that cross belong to different places (a column end next to a footnote): keep the nearer one.
        if let l = left, let r = right, l.index >= r.index { if l.reach <= r.reach { right = nil } else { left = nil } }
        guard left != nil || right != nil else { return target.offset(at: landing) }
        var low = left.map { min(ns.length, target.offset(at: $0.index) + 1) } ?? 0
        var high = right.map { target.offset(at: $0.index) } ?? ns.length
        if left == nil { low = max(0, high - 400) }; if right == nil { high = min(ns.length, low + 400) }
        guard low < high else { return min(low, ns.length) }
        let span = NSRange(location: low, length: high - low)

        // The word itself, or its longest run of letters or digits (“log10” is \log_{10} in the source).
        var needles = clicked.word.count >= 2 ? [clicked.word] : []
        var pieces: [String] = [], piece = ""
        for character in clicked.word + " " {
            if let last = piece.last, character.isLetter && last.isLetter || character.isNumber && last.isNumber { piece.append(character); continue }
            if piece.count >= 3 { pieces.append(piece) }
            piece = character.isLetter || character.isNumber ? String(character) : ""
        }
        needles += pieces.filter { $0 != clicked.word }.sorted { $0.count > $1.count }
        for needle in needles {
            var found: Int?; var search = span; var rounds = 0
            while search.length > 0, rounds < 60 {
                let hit = ns.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                guard hit.location != NSNotFound else { break }
                if let hint, let current = found {
                    if abs(line(of: hit.location, starts: starts) - hint) < abs(line(of: current, starts: starts) - hint) { found = hit.location }
                } else if found == nil { found = hit.location }
                if hint == nil { break }
                search = NSRange(location: NSMaxRange(hit), length: NSMaxRange(span) - NSMaxRange(hit)); rounds += 1
            }
            if let found { return found }
        }
        func skippingBlanks(from start: Int, to limit: Int) -> Int {
            var at = start
            while at < limit, let scalar = UnicodeScalar(ns.character(at: at)), CharacterSet.whitespacesAndNewlines.contains(scalar) { at += 1 }
            return at
        }
        if let hint, hint >= line(of: low, starts: starts), hint <= line(of: high, starts: starts), hint - 1 < starts.count {
            let lineEnd = hint < starts.count ? starts[hint] : ns.length
            return skippingBlanks(from: max(low, starts[hint - 1]), to: min(high, lineEnd))
        }
        if let l = left, right == nil || l.reach <= right!.reach { return skippingBlanks(from: low, to: high) }
        return high
    }

    // MARK: Sentences and lines

    private static let terminators: Set<Character> = [".", "?", "!", "。", "？", "！", "；"]
    private static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "fig", "figs", "eq", "eqs", "sec", "ref", "refs", "al", "vs", "cf", "no", "approx", "resp", "dr", "mr", "ms", "prof"]

    /// The word (or, in CJK text, the segmented word) of `text` that contains `offset`.
    public static func wordRange(in text: String, at offset: Int) -> NSRange? {
        let ns = text as NSString
        guard offset >= 0, offset < ns.length else { return nil }
        let start = max(0, offset - 80), window = NSRange(location: start, length: min(ns.length, offset + 80) - start)
        var found: NSRange?
        ns.enumerateSubstrings(in: window, options: [.byWords, .substringNotRequired]) { _, range, _, stop in
            if NSLocationInRange(offset, range) { found = range; stop.pointee = true }
            else if range.location > offset { stop.pointee = true }
        }
        return found
    }

    /// The sentence around a UTF-16 offset of LaTeX source. A blank line ends a sentence; a single line break does not.
    public static func sentenceRange(in text: String, at offset: Int) -> NSRange {
        let ns = text as NSString
        let location = min(max(0, offset), ns.length)
        func character(_ at: Int) -> Character { Character(UnicodeScalar(ns.character(at: at)) ?? " ") }
        func endsSentence(_ at: Int) -> Bool {
            let mark = character(at)
            guard terminators.contains(mark) else { return false }
            if "。？！；".contains(mark) { return true }
            if at + 1 < ns.length, !character(at + 1).isWhitespace, character(at + 1) != "~" { return false }
            var word = ""; var back = at - 1
            while back >= 0, character(back).isLetter || character(back) == "." { word.insert(character(back), at: word.startIndex); back -= 1 }
            if word.count == 1, word.first?.isUppercase == true { return false }
            return !abbreviations.contains(word.lowercased())
        }
        func blankLine(before at: Int) -> Bool {
            var back = at; var newlines = 0
            while back >= 0, character(back).isWhitespace { if character(back) == "\n" { newlines += 1 }; back -= 1 }
            return newlines >= 2
        }
        var start = location
        while start > 0 {
            if endsSentence(start - 1) || character(start - 1) == "\n" && blankLine(before: start - 1) { break }
            if location - start > 1200 { break }
            start -= 1
        }
        while start < location, character(start).isWhitespace { start += 1 }
        var end = location
        while end < ns.length {
            if endsSentence(end) { end += 1; break }
            if character(end) == "\n", end + 1 < ns.length, blankLine(before: end + 1) || character(end + 1) == "\n" { break }
            if end - location > 1200 { break }
            end += 1
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// UTF-16 offsets where each line starts.
    public static func lineStarts(_ text: String) -> [Int] {
        var starts = [0]; var offset = 0
        for unit in text.utf16 { offset += 1; if unit == 10 { starts.append(offset) } }
        return starts
    }
    /// 1-based line of a UTF-16 offset, given `lineStarts`.
    public static func line(of offset: Int, starts: [Int]) -> Int {
        var low = 0, high = starts.count
        while low < high { let mid = (low + high) / 2; if starts[mid] <= offset { low = mid + 1 } else { high = mid } }
        return max(1, low)
    }
}

/// Lines of a file as they were compiled, matched against the same file now, so a SyncTeX line from the last
/// build still points at the right text after figures or paragraphs were added above it.
public struct LineMap {
    private let oldToNew: [Int]
    private let newToOld: [Int]

    public init(compiled: String, current: String) {
        let old = compiled.split(separator: "\n", omittingEmptySubsequences: false)
        let new = current.split(separator: "\n", omittingEmptySubsequences: false)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var forward = [Int](repeating: 0, count: old.count), backward = [Int](repeating: 0, count: new.count)
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) || j >= new.count { forward[i] = min(j, max(0, new.count - 1)); i += 1 }
            else if j < new.count, inserted.contains(j) || i >= old.count { backward[j] = min(i, max(0, old.count - 1)); j += 1 }
            else { forward[i] = j; backward[j] = i; i += 1; j += 1 }
        }
        oldToNew = forward; newToOld = backward
    }
    /// Current line for a line of the compiled file (both 1-based).
    public func current(forCompiled line: Int) -> Int {
        guard !oldToNew.isEmpty else { return line }
        return oldToNew[min(max(0, line - 1), oldToNew.count - 1)] + 1
    }
    /// Compiled line for a current line (both 1-based). A line typed since the build maps to the line before it.
    public func compiled(forCurrent line: Int) -> Int {
        guard !newToOld.isEmpty else { return line }
        return newToOld[min(max(0, line - 1), newToOld.count - 1)] + 1
    }
}

/// The TeX sources as the last successful build read them.
public struct SourceSnapshot {
    public private(set) var files: [String: String] = [:]
    public init(files: [String: String] = [:]) { self.files = files }

    public static func capture(directory: URL, limit: Int = 800) -> SourceSnapshot {
        var files: [String: String] = [:]
        let skipped: Set<String> = [".bettertex", "node_modules", ".git", "build", "dist"]
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return SourceSnapshot() }
        while let url = iterator.nextObject() as? URL, files.count < limit {
            if skipped.contains(url.lastPathComponent) { iterator.skipDescendants(); continue }
            guard ["tex", "ltx"].contains(url.pathExtension.lowercased()), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            files[url.standardizedFileURL.resolvingSymlinksInPath().path] = text
        }
        return SourceSnapshot(files: files)
    }
    public func lineMap(for file: URL, current: String) -> LineMap? {
        guard let compiled = files[file.standardizedFileURL.resolvingSymlinksInPath().path] else { return nil }
        return compiled == current ? nil : LineMap(compiled: compiled, current: current)
    }
}
