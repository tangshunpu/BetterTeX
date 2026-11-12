import AppKit
import NaturalLanguage

/// One English grammar or spelling problem, located by UTF-16 range in the checked text.
public struct GrammarIssue: Equatable {
    public var range: NSRange
    public let message: String
    /// Rule name, e.g. "SpellCheck" or "RepeatedWords" (Harper's names where the rule comes from Harper).
    public let rule: String
    /// Replacements for `range`; spelling suggestions are looked up on demand instead.
    public let suggestions: [String]
    public var isSpelling: Bool { rule == GrammarChecker.spelling }

    public init(range: NSRange, message: String, rule: String, suggestions: [String] = []) {
        self.range = range; self.message = message; self.rule = rule; self.suggestions = suggestions
    }

    /// Keeps issues usable while the text is edited before the next check: issues the edit touches go away,
    /// later ones move with the text.
    public static func shift(_ issues: [GrammarIssue], editing range: NSRange, replacementLength: Int) -> [GrammarIssue] {
        let delta = replacementLength - range.length
        return issues.compactMap { issue in
            if NSMaxRange(issue.range) < range.location { return issue }
            if issue.range.location > NSMaxRange(range) { var moved = issue; moved.range.location += delta; return moved }
            return nil
        }
    }
}

/// A lightweight, offline English checker for LaTeX sources. Markup, math and comments are masked out;
/// spelling comes from the macOS dictionary, and the grammar rules are ported from Harper
/// (https://github.com/Automattic/harper, Apache-2.0).
public final class GrammarChecker: @unchecked Sendable {
    public static let shared = GrammarChecker()
    public static let spelling = "SpellCheck"

    private let lock = NSLock()
    private var ignored: Set<String>
    private let defaults: UserDefaults
    private static let ignoredKey = "grammar.ignored"
    private let spellTag = NSSpellChecker.uniqueSpellDocumentTag()
    /// Off in tests, where the user's learned words would make results vary.
    public var checksSpelling = true

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ignored = Set(defaults.stringArray(forKey: Self.ignoredKey) ?? [])
    }

    /// Checks a whole LaTeX document. Safe to call off the main thread.
    public func check(_ text: String) -> [GrammarIssue] {
        let prose = TeXProse(text)
        let tokens = Tokenizer.tokenize(prose.plain, mask: prose.mask)
        var run = Run(tokens: tokens, plain: prose.string)
        run.lintAll()
        if checksSpelling { run.issues += spellingIssues(prose.string, tokens: tokens) }
        let source = text as NSString
        lock.lock(); let ignored = ignored; lock.unlock()
        var seen = Set<String>()
        return run.issues
            .filter { !ignored.contains(Self.key($0, in: source)) && seen.insert("\($0.range.location):\($0.range.length)").inserted }
            .sorted { $0.range.location < $1.range.location }
    }

    /// The replacements to offer for an issue; spelling guesses come from the macOS dictionary.
    public func suggestions(for issue: GrammarIssue, in text: String) -> [String] {
        guard issue.suggestions.isEmpty, issue.isSpelling, NSMaxRange(issue.range) <= (text as NSString).length else { return issue.suggestions }
        let word = (text as NSString).substring(with: issue.range)
        return Array((NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length), in: word, language: "en", inSpellDocumentWithTag: spellTag) ?? []).prefix(6))
    }

    /// Stops reporting this rule for this exact text, across launches.
    public func ignore(_ issue: GrammarIssue, in text: String) {
        guard NSMaxRange(issue.range) <= (text as NSString).length else { return }
        lock.lock(); ignored.insert(Self.key(issue, in: text as NSString)); let all = Array(ignored); lock.unlock()
        defaults.set(all, forKey: Self.ignoredKey)
    }

    /// Adds a word to the macOS spelling dictionary, shared with other apps.
    public func learn(_ word: String) { NSSpellChecker.shared.learnWord(word) }

    static func key(_ issue: GrammarIssue, in text: NSString) -> String {
        guard NSMaxRange(issue.range) <= text.length else { return "" }
        return issue.rule + "|" + text.substring(with: issue.range).lowercased()
    }

    /// Common research vocabulary the system dictionary lacks; anything else can be learned from the menu.
    private static let knownWords: Set<String> = [
        "et", "al", "cf", "etc", "ie", "eg", "vs", "wrt", "latex", "tex", "bibtex", "arxiv", "github",
        "pretrained", "pretraining", "pretrain", "finetune", "finetuned", "finetuning", "autoencoder", "autoencoders", "autoregressive", "autoregressively",
        "logit", "logits", "softmax", "hyperparameter", "hyperparameters", "hypernetwork", "hypernetworks", "backpropagation", "backbone", "backbones",
        "dataset", "datasets", "tokenizer", "tokenizers", "tokenization", "detokenization", "embeddings", "multimodal", "underexplored", "sparsification",
        "quantization", "dequantization", "dequantize", "dequantized", "dequantizer", "quantizer", "beamforming", "beamformer", "precoding", "precoder",
        "sublinear", "superlinear", "pointwise", "convolutional", "subcarrier", "subcarriers", "transceiver", "transceivers", "downlink", "uplink",
        "eigenvalue", "eigenvalues", "eigenvector", "eigenvectors", "minimizer", "maximizer", "minimiser", "maximiser", "parameterized", "parameterised",
        "iid", "lemma", "lemmas", "corollary", "wireless", "codebook", "codebooks", "codeword", "codewords", "ablation", "ablations", "parallelly"]
    private func spellingIssues(_ plain: String, tokens: [Token]) -> [GrammarIssue] {
        var words: [Int: Token] = [:]
        for token in tokens where token.kind == .word { words[token.range.location] = token }
        let checker = NSSpellChecker.shared
        let results = checker.check(plain, range: NSRange(location: 0, length: (plain as NSString).length), types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                                    options: nil, inSpellDocumentWithTag: spellTag, orthography: nil, wordCount: nil)
        return results.compactMap { result in
            guard let token = words[result.range.location], token.range.length == result.range.length else { return nil }
            let text = token.text
            // Acronyms, identifiers, single letters and suffixes glued to math or markup ("$n$-th", "\LaTeX{}s") are left alone.
            guard text.count > 1, !token.attached, !Self.knownWords.contains(token.lower), text.dropFirst().allSatisfy({ !$0.isUppercase }),
                  !text.contains(where: \.isNumber) else { return nil }
            // US and British spellings are both fine.
            guard checker.checkSpelling(of: text, startingAt: 0, language: "en_GB", wrap: false, inSpellDocumentWithTag: spellTag, wordCount: nil).location != NSNotFound else { return nil }
            return GrammarIssue(range: token.range, message: "Did you mean to spell `\(text)` this way?", rule: Self.spelling)
        }
    }
}

/// Whether the editor underlines grammar and spelling problems.
public enum GrammarPreferences {
    public static let changed = Notification.Name("BetterTeX.GrammarPreferencesChanged")
    static let key = "editor.grammarCheck"
    public static func enabled(in defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
    public static func setEnabled(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key); NotificationCenter.default.post(name: changed, object: nil)
    }
}

// MARK: - LaTeX masking

/// The source with everything that is not prose blanked to spaces, so offsets stay identical.
/// Adapted from harper-tex's masker, extended to nested braces, display math, comments and code environments.
struct TeXProse {
    enum Mask: UInt8 { case prose = 0, gap = 1, hard = 2 }
    let source: [UInt16]
    private(set) var plain: [UInt16]
    /// `gap`: inline markup or math inside a sentence. `hard`: a boundary no rule looks across.
    private(set) var mask: [Mask]
    var string: String { String(decoding: plain, as: UTF16.self) }
    private var n: Int { source.count }

    static let inlineProse: Set<String> = ["textbf", "textit", "emph", "underline", "textsc", "textrm", "textsf", "textup", "textmd", "textsl",
                                           "textnormal", "mbox", "text", "hl", "uline", "enquote"]
    static let blockProse: Set<String> = ["section", "subsection", "subsubsection", "paragraph", "subparagraph", "chapter", "part",
                                          "caption", "title", "footnote", "footnotetext", "thanks"]
    static let codeEnvironments: Set<String> = ["equation", "align", "gather", "multline", "flalign", "alignat", "eqnarray", "math", "displaymath",
                                                "split", "verbatim", "Verbatim", "lstlisting", "minted", "comment", "tikzpicture", "algorithmic",
                                                "thebibliography", "filecontents"]

    init(_ text: String) {
        source = Array(text.utf16); plain = source; mask = Array(repeating: .prose, count: source.count)
        scan()
        for index in 0..<plain.count where mask[index] != .prose { plain[index] = 32 }
    }

    private func at(_ index: Int) -> UInt16 { index >= 0 && index < n ? source[index] : 0 }
    private static func isLetter(_ c: UInt16) -> Bool { (65...90).contains(c) || (97...122).contains(c) || c == 64 }
    private mutating func set(_ start: Int, _ end: Int, _ kind: Mask) {
        let end = min(end, n); guard start < end else { return }
        for index in start..<end where mask[index].rawValue < kind.rawValue { mask[index] = kind }
    }
    private func find(_ pattern: String, from start: Int) -> Int? {
        let needle = Array(pattern.utf16); guard !needle.isEmpty, start + needle.count <= n else { return nil }
        var index = start
        while index + needle.count <= n {
            if source[index] == needle[0], Array(source[index..<index + needle.count]) == needle { return index }
            index += 1
        }
        return nil
    }
    /// From an opening bracket, the index just past its match, skipping escaped characters.
    private func group(_ start: Int, open: UInt16, close: UInt16) -> Int? {
        var depth = 0, index = start
        let limit = min(n, start + 4000)
        while index < limit {
            let c = source[index]
            if c == 92 { index += 2; continue }
            if c == open { depth += 1 } else if c == close { depth -= 1; if depth == 0 { return index + 1 } }
            index += 1
        }
        return nil
    }
    /// Skips `[...]` and `{...}` arguments directly after a command.
    private func arguments(_ start: Int) -> Int {
        var index = start
        while true {
            if at(index) == 123, let end = group(index, open: 123, close: 125) { index = end }
            else if at(index) == 91, let end = group(index, open: 91, close: 93) { index = end }
            else { return index }
        }
    }

    private mutating func scan() {
        var index = 0, end = n
        if let begin = find("\\begin{document}", from: 0) { set(0, begin + 16, .hard); index = begin + 16 }
        if let finish = find("\\end{document}", from: index) { set(finish, n, .hard); end = finish }
        while index < end {
            switch source[index] {
            case 37: // % comment
                var stop = index; while stop < n, source[stop] != 10 { stop += 1 }
                set(index, stop, .hard); index = stop
            case 92: index = command(index)
            case 36: // $ math
                if at(index + 1) == 36 {
                    let stop = find("$$", from: index + 2).map { $0 + 2 } ?? index + 2
                    set(index, stop, .hard); index = stop
                } else {
                    var stop = index + 1
                    while stop < min(n, index + 1500), !(source[stop] == 36 && source[stop - 1] != 92) { stop += 1 }
                    stop = at(stop) == 36 ? stop + 1 : index + 1
                    set(index, stop, .gap); index = stop
                }
            case 123, 125: set(index, index + 1, .gap); index += 1
            case 126: plain[index] = 32; index += 1 // ~ is a space
            case 38: set(index, index + 1, .hard); index += 1 // table cell
            case 10: // a blank line ends the paragraph
                var stop = index + 1
                while stop < n, [32, 9, 13].contains(source[stop]) { stop += 1 }
                if at(stop) == 10 { set(index, stop + 1, .hard); index = stop + 1 } else { index += 1 }
            default: index += 1
            }
        }
    }

    private mutating func command(_ start: Int) -> Int {
        let first = at(start + 1)
        guard Self.isLetter(first) else {
            switch first {
            case 91: if let close = find("\\]", from: start + 2) { set(start, close + 2, .hard); return close + 2 }
            case 40: if let close = find("\\)", from: start + 2) { set(start, close + 2, .gap); return close + 2 }
            case 92: // \\ line break, possibly with [2pt]
                var stop = start + 2; if at(stop) == 91, let close = group(stop, open: 91, close: 93) { stop = close }
                set(start, stop, .hard); return stop
            case 44, 59, 58, 33, 32: plain[start] = 32; if start + 1 < n { plain[start + 1] = 32 }; return start + 2 // \, \; \: \! "\ "
            default: break
            }
            set(start, start + 2, .gap); return start + 2
        }
        var stop = start + 1; while Self.isLetter(at(stop)) { stop += 1 }
        let name = String(decoding: source[(start + 1)..<stop], as: UTF16.self)
        if at(stop) == 42 { stop += 1 }
        switch name {
        case "begin", "end":
            guard at(stop) == 123, let close = group(stop, open: 123, close: 125) else { set(start, stop, .hard); return stop }
            let environment = String(decoding: source[(stop + 1)..<(close - 1)], as: UTF16.self)
            let base = environment.hasSuffix("*") ? String(environment.dropLast()) : environment
            if name == "begin", Self.codeEnvironments.contains(base) {
                let finish = find("\\end{\(environment)}", from: close).map { $0 + 6 + environment.utf16.count } ?? n
                set(start, finish, .hard); return finish
            }
            let after = name == "begin" ? arguments(close) : close
            set(start, after, .hard); return after
        case "item":
            if at(stop) == 91, let close = group(stop, open: 91, close: 93) { stop = close }
            set(start, stop, .hard); return stop
        case "verb":
            let delimiter = at(stop); var finish = stop + 1
            while finish < n, source[finish] != delimiter, source[finish] != 10 { finish += 1 }
            set(start, finish + 1, .gap); return finish + 1
        default:
            let inline = Self.inlineProse.contains(name), block = Self.blockProse.contains(name)
            guard inline || block else { let after = arguments(stop); set(start, after, .gap); return after }
            let kind: Mask = block ? .hard : .gap
            if at(stop) == 91, let close = group(stop, open: 91, close: 93) { stop = close }
            guard at(stop) == 123, let close = group(stop, open: 123, close: 125) else { set(start, stop, kind); return stop }
            // Keep the argument's text; only the command and its braces are masked.
            set(start, stop + 1, kind); set(close - 1, close, kind); return stop + 1
        }
    }
}

// MARK: - Tokens

struct Token {
    enum Kind { case word, number, punctuation, foreign }
    let range: NSRange
    let text: String
    let lower: String
    let kind: Kind
    /// The strongest mask between this token and the previous one.
    let gap: TeXProse.Mask
    /// Whitespace (or masked markup) separates this token from the previous one.
    let spaced: Bool
    /// Masked markup or math sits directly before this token, or a hyphen joins it to such ("$n$th", "$k$-th").
    var attached = false
}

enum Tokenizer {
    static func isLatinLetter(_ c: UInt16) -> Bool {
        (65...90).contains(c) || (97...122).contains(c) || ((0xC0...0x24F).contains(c) && c != 0xD7 && c != 0xF7)
    }
    static func isDigit(_ c: UInt16) -> Bool { (48...57).contains(c) }
    static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 0xA0 }
    static func isApostrophe(_ c: UInt16) -> Bool { c == 39 || c == 0x2019 }

    static func tokenize(_ units: [UInt16], mask: [TeXProse.Mask]? = nil) -> [Token] {
        var tokens: [Token] = [], index = 0, gap = TeXProse.Mask.prose, spaced = false
        let n = units.count
        func at(_ i: Int) -> UInt16 { i < n ? units[i] : 0 }
        while index < n {
            let c = units[index]
            if let mask, mask[index] != .prose { if mask[index].rawValue > gap.rawValue { gap = mask[index] }; spaced = true; index += 1; continue }
            if isSpace(c) { spaced = true; index += 1; continue }
            let start = index, kind: Token.Kind
            if isLatinLetter(c) {
                kind = .word; index += 1
                while index < n, isLatinLetter(units[index]) || isDigit(units[index]) || (isApostrophe(units[index]) && isLatinLetter(at(index + 1))) { index += 1 }
            } else if isDigit(c) {
                kind = .number; index += 1
                while index < n, isDigit(units[index]) || ((units[index] == 46 || units[index] == 44) && isDigit(at(index + 1))) || isLatinLetter(units[index]) { index += 1 }
            } else if c >= 0x2E80 {
                kind = .foreign; index += 1
                while index < n, units[index] >= 0x2E80 { index += 1 }
            } else {
                kind = .punctuation; index += 1
            }
            let text = String(decoding: units[start..<index], as: UTF16.self)
            var token = Token(range: NSRange(location: start, length: index - start), text: text, lower: text.lowercased(), kind: kind, gap: gap, spaced: spaced)
            if let mask, start > 0 {
                let before = start - 1
                token.attached = mask[before] != .prose || (units[before] == 45 && before > 0 && mask[before - 1] != .prose)
            }
            tokens.append(token)
            gap = .prose; spaced = false
        }
        return tokens
    }
}

// MARK: - Rules

private struct PhraseRule {
    let words: [(text: String, spaced: Bool)]
    let replacements: [String]
    let rule: String
    let message: String
}

private enum Phrases {
    /// Harper's phrase corrections, indexed by their first word.
    static let byFirstWord: [String: [PhraseRule]] = {
        guard let url = try? AppResources.requiredURL("GrammarPhrases", fileExtension: "json"), let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rules = root["rules"] as? [[String: Any]] else { return [:] }
        var index: [String: [PhraseRule]] = [:]
        for rule in rules {
            guard let name = rule["rule"] as? String, let message = rule["message"] as? String, let map = rule["map"] as? [[[String]]] else { continue }
            for pair in map where pair.count == 2 {
                for wrong in pair[0] {
                    let tokens = Tokenizer.tokenize(Array(wrong.lowercased().utf16))
                    guard let first = tokens.first else { continue }
                    index[first.lower, default: []].append(PhraseRule(words: tokens.map { ($0.lower, $0.spaced) }, replacements: pair[1], rule: name, message: message))
                }
            }
        }
        for key in index.keys { index[key]?.sort { $0.words.count > $1.words.count } }
        return index
    }()
}

private struct Run {
    let tokens: [Token]
    let plain: String
    var issues: [GrammarIssue] = []
    private var tagger: NLTagger?

    init(tokens: [Token], plain: String) { self.tokens = tokens; self.plain = plain }

    mutating func lintAll() {
        var index = 0
        while index < tokens.count {
            if let skip = phrase(at: index) { index += skip; continue }
            if tokens[index].kind == .word { word(at: index) }
            else if tokens[index].kind == .punctuation { spaceBefore(index) }
            index += 1
        }
    }

    // MARK: Helpers

    /// The next token when nothing but plain whitespace separates them.
    func next(_ index: Int) -> Int? { index + 1 < tokens.count && tokens[index + 1].gap == .prose ? index + 1 : nil }
    func previous(_ index: Int) -> Int? { index > 0 && tokens[index].gap == .prose ? index - 1 : nil }
    func nextWord(_ index: Int) -> Token? { next(index).map { tokens[$0] }.flatMap { $0.kind == .word && $0.spaced ? $0 : nil } }
    func previousWord(_ index: Int) -> Token? { previous(index).map { tokens[$0] }.flatMap { $0.kind == .word && tokens[index].spaced ? $0 : nil } }
    func startsSentence(_ index: Int) -> Bool {
        guard let before = previous(index) else { return true }
        return [".", "!", "?", ":"].contains(tokens[before].text) || tokens[before].kind == .foreign
    }
    mutating func add(_ range: NSRange, _ rule: String, _ message: String, _ suggestions: [String]) {
        issues.append(GrammarIssue(range: range, message: message, rule: rule, suggestions: suggestions))
    }
    static func matchCase(_ replacement: String, like original: String) -> String {
        if original.count > 1, original == original.uppercased(), original != original.lowercased() { return replacement.uppercased() }
        if let first = original.first, first.isUppercase { return replacement.prefix(1).uppercased() + replacement.dropFirst() }
        return replacement
    }
    private mutating func tag(_ token: Token) -> (word: NLTag?, lemma: String?) {
        if tagger == nil {
            let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma]); tagger.string = plain
            tagger.setLanguage(.english, range: plain.startIndex..<plain.endIndex); self.tagger = tagger
        }
        guard let tagger, let start = Range(token.range, in: plain)?.lowerBound else { return (nil, nil) }
        let word = tagger.tag(at: start, unit: .word, scheme: .lexicalClass).0
        let lemma = tagger.tag(at: start, unit: .word, scheme: .lemma).0?.rawValue.lowercased()
        return (word, lemma)
    }

    // MARK: Phrase corrections (Harper)

    private mutating func phrase(at index: Int) -> Int? {
        guard tokens[index].kind == .word, let candidates = Phrases.byFirstWord[tokens[index].lower] else { return nil }
        for candidate in candidates {
            var end = index, matched = true
            for (offset, word) in candidate.words.enumerated() {
                let position = index + offset
                guard position < tokens.count, tokens[position].lower == word.text,
                      offset == 0 || (tokens[position].gap == .prose && tokens[position].spaced == word.spaced) else { matched = false; break }
                end = position
            }
            guard matched else { continue }
            let range = NSUnionRange(tokens[index].range, tokens[end].range)
            let original = (plain as NSString).substring(with: range)
            add(range, candidate.rule, candidate.message, candidate.replacements.map { Self.matchCase($0, like: original) })
            return end - index + 1
        }
        return nil
    }

    // MARK: Word rules

    private static let openCompounds = ["alot": "a lot", "afew": "a few", "aswell": "as well", "atall": "at all", "atleast": "at least",
                                        "eachother": "each other", "incase": "in case", "infact": "in fact", "infront": "in front", "upto": "up to",
                                        "ofcourse": "of course", "everytime": "every time", "noone": "no one", "thankyou": "thank you"]
    private static let modals: Set<String> = ["can", "could", "will", "would", "shall", "should", "may", "might", "must"]
    private static let comparatives: Set<String> = ["more", "less", "better", "worse", "rather", "other", "bigger", "smaller", "larger", "higher", "lower",
                                                    "greater", "faster", "slower", "longer", "shorter", "fewer", "easier", "harder", "stronger", "weaker"]

    private mutating func word(at index: Int) {
        let token = tokens[index]
        if let fix = Self.openCompounds[token.lower] {
            add(token.range, "OpenCompounds", "`\(fix)` should be written as two words.", [Self.matchCase(fix, like: token.text)])
        }
        switch token.lower {
        case "a", "an": article(index)
        case "i", "i'm", "i've", "i'd", "i'll": pronounI(index); if token.lower == "i" { agreement(index) }
        case "he", "she", "we", "they": agreement(index)
        case "their", "there", "they're": theirThere(index)
        case "its", "it's": its(index)
        case "then":
            if let before = previousWord(index), Self.comparatives.contains(before.lower) {
                add(token.range, "ThenThan", "Did you mean `than` for a comparison?", [Self.matchCase("than", like: token.text)])
            }
        case "of":
            if let before = previousWord(index), Self.modals.contains(before.lower) || before.lower.hasSuffix("n't"), nextWord(index)?.lower != "course" {
                add(token.range, "ModalOf", "Use `have` after a modal verb, not `of`.", [Self.matchCase("have", like: token.text)])
            }
        default: break
        }
        repeated(index)
        capitalization(index)
    }

    private static let repeatable: Set<String> = ["that", "had", "is", "very", "so", "no", "bye", "ha", "do"]
    private mutating func repeated(_ index: Int) {
        guard let following = next(index), tokens[following].kind == .word, tokens[following].spaced, tokens[following].lower == tokens[index].lower,
              !Self.repeatable.contains(tokens[index].lower) else { return }
        add(NSUnionRange(tokens[index].range, tokens[following].range), "RepeatedWords", "Did you mean to repeat this word?", [tokens[index].text])
    }

    private mutating func article(_ index: Int) {
        let token = tokens[index]
        guard let following = nextWord(index), !["and", "or", "nor"].contains(following.lower) else { return }
        // A capital "A" mid-sentence is usually a name or variable ("matrix A is").
        if token.text == "A", !startsSentence(index) { return }
        if let before = previousWord(index), before.lower == "a" || before.lower == "an" { return }
        let a: Bool
        switch Article.initialSound(following.text) { case .vowel: a = false; case .consonant: a = true; case .either: return }
        guard a != (token.lower == "a") else { return }
        add(token.range, "AnA", "Incorrect indefinite article.", [Self.matchCase(a ? "a" : "an", like: token.text)])
    }

    private mutating func pronounI(_ index: Int) {
        let token = tokens[index]
        guard token.text.first == "i" else { return }
        // i.e., (i), i-th
        if let following = next(index), !tokens[following].spaced, [".", ")", "-", "_", "^"].contains(tokens[following].text) { return }
        if let before = previous(index), !token.spaced, ["(", "_", "^", "\\"].contains(tokens[before].text) { return }
        add(token.range, "CapitalizePersonalPronouns", "The first-person singular subject pronoun must be capitalized.", ["I" + token.text.dropFirst()])
    }

    private static let subjunctive: Set<String> = ["that", "demanded", "demanding", "insisted", "insisting", "recommended", "recommending",
                                                   "requested", "requesting", "suggested", "suggesting", "let", "make", "makes", "made", "help", "helps",
                                                   "helped", "see", "saw", "watch", "hear", "heard", "have", "had", "do", "does", "did", "to", "why",
                                                   "can", "could", "will", "would", "shall", "should", "may", "might", "must"]
    private static let unchangedPast: Set<String> = ["put", "cut", "set", "let", "hit", "hurt", "cost", "quit", "read", "spread", "shut", "split", "bet",
                                                     "cast", "burst", "thrust", "upset", "broadcast", "fit", "rid", "shed", "spit", "bid", "beat"]
    static func thirdPerson(_ verb: String) -> String {
        switch verb { case "have": return "has"; case "be": return "is"; default: break }
        if ["s", "sh", "ch", "x", "z", "o"].contains(where: verb.hasSuffix) { return verb + "es" }
        if verb.hasSuffix("y"), let before = verb.dropLast().last, !"aeiou".contains(before) { return verb.dropLast() + "ies" }
        return verb + "s"
    }

    private mutating func agreement(_ index: Int) {
        let pronoun = tokens[index]
        guard let position = next(index), tokens[position].kind == .word, tokens[position].spaced else { return }
        let verb = tokens[position]
        guard verb.text == verb.lower else { return }
        let message = "The form of the verb must agree in grammatical number with the pronoun."
        if pronoun.lower == "he" || pronoun.lower == "she" {
            if let before = previousWord(index), Self.subjunctive.contains(before.lower) { return }
            let irregular = ["are": "is", "were": "was", "don't": "doesn't", "haven't": "hasn't", "aren't": "isn't"]
            if let fix = irregular[verb.lower] { add(verb.range, "PronounVerbAgreement", message, [fix]); return }
            guard !Self.modals.contains(verb.lower), !Self.unchangedPast.contains(verb.lower), !["be", "and", "or", "also", "only", "even", "never", "always"].contains(verb.lower) else { return }
            let (tag, lemma) = tag(verb)
            guard tag == .verb, lemma == verb.lower else { return }
            add(verb.range, "PronounVerbAgreement", message, [Self.thirdPerson(verb.lower)])
            return
        }
        // "Type I has", "World War I is": a capitalised word before "I" makes it a numeral or name.
        if pronoun.text == "I", let before = previousWord(index), before.text.first?.isUppercase == true { return }
        if pronoun.lower == "i", pronoun.text != "I" { return }
        let plural = pronoun.lower != "i"
        let irregular: [String: String] = plural ? ["has": "have", "does": "do", "doesn't": "don't", "hasn't": "haven't", "is": "are", "isn't": "aren't", "was": "were", "wasn't": "weren't"]
                                                 : ["has": "have", "does": "do", "doesn't": "don't", "hasn't": "haven't", "is": "am", "are": "am"]
        if let fix = irregular[verb.lower] { add(verb.range, "PronounVerbAgreement", message, [fix]); return }
        guard verb.lower.hasSuffix("s") else { return }
        let (tag, lemma) = tag(verb)
        guard tag == .verb, let lemma, lemma != verb.lower, Self.thirdPerson(lemma) == verb.lower else { return }
        add(verb.range, "PronounVerbAgreement", message, [lemma])
    }

    private static let progressive: Set<String> = ["going", "coming", "doing", "trying", "getting", "making", "taking", "looking", "saying", "working", "playing", "planning"]
    private static let placePrepositions: Set<String> = ["to", "in", "at", "from", "of", "with", "for", "by", "about", "into", "on"]
    private static let timeWords: Set<String> = ["today", "tomorrow", "yesterday", "tonight", "now", "too", "again", "yet", "first", "before", "after", "later", "instead"]
    private mutating func theirThere(_ index: Int) {
        let token = tokens[index]
        guard let following = nextWord(index) else { return }
        let next = following.lower
        if token.lower == "their", ["is", "are", "was", "were"].contains(next) {
            add(token.range, "TheirToThere", "Did you mean `there`?", [Self.matchCase("there", like: token.text)])
        } else if token.lower != "they're", Self.progressive.contains(next) {
            add(token.range, "TheirToTheyre", "Did you mean `they're`?", [Self.matchCase("they're", like: token.text)])
        } else if token.lower != "their", next == "own" {
            add(token.range, "ThereToTheir", "Did you mean `their`?", [Self.matchCase("their", like: token.text)])
        } else if token.lower == "there", let before = previousWord(index), Self.placePrepositions.contains(before.lower),
                  following.text == next, !Self.timeWords.contains(next), tag(following).word == .noun {
            add(token.range, "ThereToTheir", "Did you mean `their`?", [Self.matchCase("their", like: token.text)])
        }
    }

    private static let afterItIs: Set<String> = ["a", "an", "the", "not", "been", "going", "important", "possible", "likely", "unlikely", "clear", "true",
                                                 "easy", "hard", "difficult", "necessary", "worth", "known", "also", "time", "obvious", "interesting"]
    private mutating func its(_ index: Int) {
        let token = tokens[index]
        guard let following = nextWord(index) else { return }
        if token.lower == "it's", following.lower == "own" {
            add(token.range, "ItsPossessive", "Use the possessive `its`, without an apostrophe.", [Self.matchCase("its", like: token.text)])
        } else if token.lower == "its", Self.afterItIs.contains(following.lower) {
            add(token.range, "ItsContraction", "Did you mean `it's` (it is)?", [Self.matchCase("it's", like: token.text)])
        }
    }

    private static let abbreviations: Set<String> = ["e", "g", "i", "etc", "al", "cf", "vs", "fig", "figs", "eq", "eqs", "sec", "secs", "tab", "ref", "refs",
                                                     "approx", "resp", "no", "vol", "pp", "ch", "dr", "mr", "mrs", "ms", "prof", "st", "jr", "viz", "ca", "thm", "def", "lem", "prop"]
    private mutating func capitalization(_ index: Int) {
        let token = tokens[index]
        guard token.spaced, let first = token.text.first, first.isLowercase, let dot = previous(index), ["!", "?", "."].contains(tokens[dot].text),
              let ended = previous(dot), !tokens[dot].spaced else { return }
        let last = tokens[ended]
        if tokens[dot].text == "." {
            guard last.kind == .word, last.text.count > 1, !Self.abbreviations.contains(last.lower) else { return }
            // Short capitalised words before a dot are usually abbreviations ("Tab.", "Thm.", "Tax.").
            if last.text.first?.isUppercase == true, last.text.count <= 4 { return }
            // "e.g." / "U.S." style abbreviations end in a single letter after another dot.
            if let earlier = previous(ended), tokens[earlier].text == "." { return }
        }
        add(token.range, "SentenceCapitalization", "This sentence does not start with a capital letter", [first.uppercased() + token.text.dropFirst()])
    }

    private mutating func spaceBefore(_ index: Int) {
        let token = tokens[index]
        guard token.spaced, [",", ";", "."].contains(token.text), let before = previous(index), tokens[before].kind == .word else { return }
        // Only plain spaces on the same line; the gap itself is what gets removed.
        let start = NSMaxRange(tokens[before].range), ns = plain as NSString
        let between = ns.substring(with: NSRange(location: start, length: token.range.location - start))
        guard !between.contains("\n"), token.text != "." || next(index).map({ tokens[$0].kind != .number }) ?? true else { return }
        add(NSRange(location: start, length: token.range.location - start + token.range.length), "Spaces", "Remove the space before `\(token.text)`.", [token.text])
    }
}

// MARK: - Indefinite articles (ported from harper-core's indefinite_article.rs)

enum Article {
    enum Sound { case vowel, consonant, either }

    static func initialSound(_ input: String) -> Sound {
        var chars = Array(input)
        guard !chars.isEmpty else { return .either }
        if ["LED", "SQL", "URL"].contains(input) { return .either }
        // A partial initialism such as "RFL" in "RFLink" or "m" in "mDNS".
        if chars.count > 1, chars[0].isLetter, chars[1].isUppercase {
            let upper = chars[0].isUppercase
            let length = chars.firstIndex { !$0.isLetter || $0.isUppercase != upper } ?? chars.count
            chars = Array(chars[0..<length])
        }
        // Two-letter abbreviations read letter by letter: "an Rx", "a Tx".
        if chars.count == 2, chars[0].isUppercase, chars[1].isLowercase, !"aeiouy".contains(chars[1]), !["Mr", "Ms", "Dr", "St"].contains(input) { chars = [chars[0]] }
        let initialism = chars.allSatisfy { !$0.isLetter || $0.isUppercase }
        if chars.count == 1 || (initialism && !likelyAcronym(chars)) {
            return "AEFHILMNORSX".contains(chars[0].uppercased()) ? .vowel : .consonant
        }
        let word = String(chars).lowercased()
        func starts(_ prefixes: String...) -> Bool { prefixes.contains { word.hasPrefix($0) } }
        func matches(_ pattern: String) -> Bool { word.range(of: pattern, options: .regularExpression) != nil }
        if starts("ubi") { return .either }
        if matches("^mp[0-9]") || word == "npm" || starts("eule") { return .vowel }
        if starts("uk", "ude", "euph", "eug", "eul", "euc", "one") { return .consonant }
        if starts("hour", "unin", "unim", "una", "unu", "urb", "int", "herb") { return .vowel }
        if matches("^u[ns][iau]") { return .consonant }
        if starts("un", "urg", "utt") { return .vowel }
        if matches("^u[trn]") || starts("eur", "uw", "use") { return .consonant }
        if word == "sos" || word == "xbox" || starts("rz", "ng", "nv", "heir", "honor", "hones") { return .vowel }
        if matches("^(ju|jo)n") || matches("^jur[aio]") { return .consonant }
        if matches("^x[-'.os]") { return .vowel }
        return "aeiou".contains(word.first!) ? .vowel : .consonant
    }

    private static func likelyAcronym(_ word: [Character]) -> Bool {
        guard word.count >= 3, word[0..<3].allSatisfy(\.isLetter), !String(word).contains("VC") else { return false }
        let vowels = word[0..<3].map { "aeiouAEIOU".contains($0) }
        return vowels == [false, true, false] || vowels == [false, true, true]
    }
}
