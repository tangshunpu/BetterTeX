import Foundation

/// One entry of the completion list.
public struct CompletionItem: Equatable {
    public let label: String
    public let detail: String
    /// The text that replaces what was typed.
    public let insert: String
    /// Caret position inside `insert` after accepting; nil puts it at the end.
    public let caret: Int?
    public init(label: String, detail: String = "", insert: String? = nil, caret: Int? = nil) {
        self.label = label; self.detail = detail; self.insert = insert ?? label; self.caret = caret
    }
}

public enum CompletionKind: Equatable { case command, citation, reference, environment, graphics, input, bibliography, package }

/// What is being typed at the caret and which span a completion would replace.
public struct CompletionRequest: Equatable {
    public let kind: CompletionKind
    /// The command owning the argument (`cite`, `begin`, …); empty for command completion.
    public let command: String
    public let prefix: String
    /// UTF-16 range of `prefix` in the document.
    public let range: NSRange

    /// Looks at the current line up to the caret. Returns nil when nothing can be completed there.
    public static func detect(in text: String, cursor: Int) -> CompletionRequest? {
        let ns = text as NSString
        guard cursor >= 0, cursor <= ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: cursor, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
        let line = before as NSString
        // Nothing is completed inside a comment.
        if let comment = try? NSRegularExpression(pattern: "(?<!\\\\)%"), comment.firstMatch(in: before, range: NSRange(location: 0, length: line.length)) != nil { return nil }

        // An argument being typed: \cite[p. 3]{a,b|   \begin{ali|
        if let match = argument.firstMatch(in: before, range: NSRange(location: 0, length: line.length)) {
            let command = line.substring(with: match.range(at: 1)), content = match.range(at: 2)
            if let kind = kind(of: command) {
                var start = content.location
                if kind == .citation || kind == .reference || kind == .package || kind == .bibliography {
                    let comma = line.range(of: ",", options: .backwards, range: content)
                    if comma.location != NSNotFound { start = NSMaxRange(comma) }
                }
                while start < line.length, line.character(at: start) == 32 { start += 1 }
                return CompletionRequest(kind: kind, command: command, prefix: line.substring(from: start), range: NSRange(location: lineStart + start, length: line.length - start))
            }
        }
        // A command being typed: \alp|  (but not after a line break "\\").
        if let match = commandStart.firstMatch(in: before, range: NSRange(location: 0, length: line.length)) {
            let slash = match.range.location
            var slashes = 0; var index = slash
            while index >= 0, line.character(at: index) == 92 { slashes += 1; index -= 1 }
            let name = line.substring(with: match.range(at: 1))
            if slashes % 2 == 1, !name.isEmpty { return CompletionRequest(kind: .command, command: "", prefix: name, range: NSRange(location: lineStart + slash, length: line.length - slash)) }
        }
        return nil
    }
    private static let argument = try! NSRegularExpression(pattern: "\\\\([a-zA-Z@]+)\\*?(?:\\[[^\\]]*\\])*\\{([^{}]*)$")
    private static let commandStart = try! NSRegularExpression(pattern: "\\\\([a-zA-Z@]*)$")
    private static func kind(of command: String) -> CompletionKind? {
        let lower = command.lowercased()
        if lower == "begin" || lower == "end" { return .environment }
        if lower.contains("cite") { return .citation }
        if lower.hasSuffix("ref") && lower != "href" { return .reference }
        if ["includegraphics", "includesvg", "includepdf"].contains(lower) { return .graphics }
        if ["input", "include", "subfile", "subfileinclude"].contains(lower) { return .input }
        if ["bibliography", "addbibresource"].contains(lower) { return .bibliography }
        if ["usepackage", "requirepackage"].contains(lower) { return .package }
        return nil
    }
}

/// Names collected from the project's files: labels, citation keys, user macros, paths.
public struct ProjectIndex {
    public var labels: [CompletionItem] = []
    public var citations: [CompletionItem] = []
    public var commands: [String] = []
    public var environments: [String] = []
    public var graphics: [String] = []
    public var inputs: [String] = []
    public var bibliographies: [String] = []
    public init() {}

    private static let label = try! NSRegularExpression(pattern: "\\\\label\\{([^{}]+)\\}")
    private static let macro = try! NSRegularExpression(pattern: "\\\\(?:(?:re|provide)?newcommand\\*?\\s*\\{?|DeclareMathOperator\\*?\\s*\\{|DeclareRobustCommand\\*?\\s*\\{?|def\\s*|NewDocumentCommand\\s*\\{?)\\\\([a-zA-Z@]+)")
    private static let environment = try! NSRegularExpression(pattern: "\\\\(?:(?:re)?newenvironment|newtheorem|NewDocumentEnvironment|newtcolorbox)\\*?\\s*\\{([^{}]+)\\}")
    private static let bibitem = try! NSRegularExpression(pattern: "\\\\bibitem(?:\\[[^\\]]*\\])?\\{([^{}]+)\\}")
    private static let entry = try! NSRegularExpression(pattern: "@([a-zA-Z]+)\\s*\\{\\s*([^,\\s{}]+)\\s*,")
    private static func captures(_ regex: NSRegularExpression, _ text: String) -> [String] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
    /// The value of a BibTeX field: braced (with nesting), quoted or bare.
    private static func field(_ name: String, in entry: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?i)(?<![a-z])\(name)\\s*=\\s*") else { return nil }
        let ns = entry as NSString
        guard let match = regex.firstMatch(in: entry, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var index = NSMaxRange(match.range); guard index < ns.length else { return nil }
        var value = ""
        let opener = ns.character(at: index)
        if opener == 123 {
            var depth = 0
            while index < ns.length {
                let unit = ns.character(at: index)
                if unit == 123 { depth += 1 } else if unit == 125 { depth -= 1; if depth == 0 { break } }
                else { value.append(ns.substring(with: NSRange(location: index, length: 1))) }
                index += 1
            }
        } else {
            let quoted = opener == 34; if quoted { index += 1 }
            while index < ns.length {
                let unit = ns.character(at: index)
                if quoted ? unit == 34 : (unit == 44 || unit == 10 || unit == 125) { break }
                if unit != 123, unit != 125 { value.append(ns.substring(with: NSRange(location: index, length: 1))) }
                index += 1
            }
        }
        let cleaned = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Labels defined in one document, e.g. the unsaved text in the editor.
    public static func labels(in text: String, file: String) -> [CompletionItem] { captures(label, text).map { CompletionItem(label: $0, detail: file) } }

    /// Citation keys of a `.bib` file with "Author Year · Title" as detail.
    public static func citations(inBib text: String) -> [CompletionItem] {
        let ns = text as NSString; var items: [CompletionItem] = []
        let matches = entry.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for (index, match) in matches.enumerated() {
            let type = ns.substring(with: match.range(at: 1)).lowercased()
            if ["comment", "string", "preamble"].contains(type) { continue }
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: NSMaxRange(match.range), length: min(4000, end - NSMaxRange(match.range))))
            var author = field("author", in: body)?.components(separatedBy: " and ").first ?? ""
            author = author.contains(",") ? String(author.split(separator: ",")[0]) : (author.split(separator: " ").last.map(String.init) ?? "")
            let head = [author, field("year", in: body) ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            items.append(CompletionItem(label: ns.substring(with: match.range(at: 2)), detail: [head, field("title", in: body) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")))
        }
        return items
    }

    /// Reads the project's sources. `base` is the folder paths are written relative to (the root document's).
    public static func scan(project: URL, base: URL) -> ProjectIndex {
        var index = ProjectIndex()
        let root = base.standardizedFileURL.path, excluded: Set<String> = [".git", ".build", ".bettertex", "node_modules", "dist", "build", ".venv"]
        func relative(_ url: URL) -> String? {
            let path = url.standardizedFileURL.path
            return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
        }
        var commands = Set<String>(), environments = Set<String>(), keys = Set<String>()
        guard let iterator = FileManager.default.enumerator(at: project, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return index }
        var visited = 0
        while let url = iterator.nextObject() as? URL {
            visited += 1; if visited > 10_000 { break }
            if excluded.contains(url.lastPathComponent) { iterator.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            func text() -> String? { (values.fileSize ?? 0) < 4_000_000 ? try? String(contentsOf: url, encoding: .utf8) : nil }
            switch ext {
            case "tex", "sty", "cls", "ltx":
                guard let source = text() else { continue }
                if ext == "tex" {
                    index.labels += labels(in: source, file: url.lastPathComponent)
                    for key in captures(bibitem, source) where keys.insert(key).inserted { index.citations.append(CompletionItem(label: key, detail: url.lastPathComponent)) }
                    if let path = relative(url) { index.inputs.append(String(path.dropLast(4))) }
                }
                commands.formUnion(captures(macro, source)); environments.formUnion(captures(environment, source))
            case "bib":
                if let path = relative(url) { index.bibliographies.append(path) }
                guard let source = text() else { continue }
                for item in citations(inBib: source) where keys.insert(item.label).inserted { index.citations.append(item) }
            case "png", "jpg", "jpeg", "pdf", "eps", "svg":
                if let path = relative(url) { index.graphics.append(path) }
            default: break
            }
        }
        index.commands = commands.sorted(); index.environments = environments.sorted()
        index.graphics.sort(); index.inputs.sort(); index.bibliographies.sort()
        return index
    }
}

public enum Completer {
    // Commands followed by "{}" with the caret inside; a second "{}" where two arguments are usual.
    static let oneArgument = ["section", "subsection", "subsubsection", "paragraph", "chapter", "part", "textbf", "textit", "emph", "texttt", "textsc", "textrm", "textsf", "underline",
        "label", "ref", "eqref", "pageref", "autoref", "cref", "Cref", "cite", "citep", "citet", "parencite", "textcite", "autocite", "nocite", "footnote", "caption", "includegraphics",
        "input", "include", "usepackage", "documentclass", "begin", "end", "title", "author", "date", "bibliography", "bibliographystyle", "addbibresource", "url", "text", "mathbb", "mathcal",
        "mathbf", "mathrm", "mathit", "mathsf", "mathfrak", "boldsymbol", "bm", "operatorname", "sqrt", "hat", "bar", "tilde", "vec", "dot", "ddot", "overline", "underbrace", "overbrace",
        "hspace", "vspace", "textcolor", "color", "pagestyle", "thispagestyle", "item", "mbox", "thanks", "keywords", "subfile", "graphicspath", "captionof", "subcaption"]
    static let twoArguments = ["frac", "dfrac", "tfrac", "binom", "href", "newcommand", "renewcommand", "setlength", "setcounter", "addtocounter", "stackrel", "overset", "underset", "multirow"]
    static let plain = ["alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta", "theta", "vartheta", "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma", "tau",
        "upsilon", "phi", "varphi", "chi", "psi", "omega", "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Phi", "Psi", "Omega", "sum", "prod", "int", "iint", "oint", "lim", "inf", "sup",
        "max", "min", "arg", "log", "ln", "exp", "sin", "cos", "tan", "det", "infty", "partial", "nabla", "forall", "exists", "in", "notin", "subset", "subseteq", "supset", "cup", "cap", "setminus",
        "emptyset", "cdot", "cdots", "ldots", "vdots", "ddots", "times", "div", "pm", "mp", "leq", "geq", "neq", "approx", "equiv", "sim", "simeq", "propto", "ll", "gg", "to", "rightarrow",
        "leftarrow", "Rightarrow", "Leftarrow", "leftrightarrow", "Leftrightarrow", "mapsto", "implies", "iff", "left", "right", "big", "Big", "bigg", "Bigg", "langle", "rangle", "lVert", "rVert",
        "quad", "qquad", "odot", "oplus", "otimes", "circ", "top", "bot", "ell", "hbar", "Re", "Im", "prime", "angle", "perp", "parallel", "mid", "nonumber", "notag", "maketitle",
        "tableofcontents", "listoffigures", "listoftables", "newpage", "clearpage", "noindent", "centering", "raggedright", "newline", "linebreak", "par", "medskip", "bigskip", "smallskip",
        "hline", "toprule", "midrule", "bottomrule", "cline", "textwidth", "linewidth", "columnwidth", "textheight", "appendix", "today", "LaTeX", "TeX", "hfill", "vfill", "displaystyle",
        "textstyle", "scriptstyle", "small", "footnotesize", "scriptsize", "tiny", "large", "Large", "LARGE", "huge", "Huge", "normalsize", "bfseries", "itshape", "ttfamily", "item"]
    static let environments = ["document", "abstract", "figure", "figure*", "table", "table*", "tabular", "tabularx", "equation", "equation*", "align", "align*", "aligned", "gather", "gather*",
        "multline", "split", "cases", "matrix", "pmatrix", "bmatrix", "vmatrix", "array", "itemize", "enumerate", "description", "center", "flushleft", "flushright", "quote", "verbatim",
        "minipage", "subfigure", "theorem", "lemma", "proposition", "corollary", "definition", "remark", "proof", "algorithm", "algorithmic", "tikzpicture", "frame", "columns", "lstlisting",
        "thebibliography", "appendices", "IEEEkeywords", "IEEEproof", "IEEEbiography"]
    static let packages = ["amsmath", "amssymb", "amsthm", "amsfonts", "mathtools", "bm", "graphicx", "xcolor", "hyperref", "cleveref", "geometry", "booktabs", "multirow", "array", "tabularx",
        "caption", "subcaption", "float", "enumitem", "listings", "algorithm", "algorithmic", "algpseudocode", "tikz", "pgfplots", "siunitx", "natbib", "biblatex", "cite", "url", "inputenc",
        "fontenc", "babel", "ctex", "xeCJK", "fontspec", "microtype", "setspace", "fancyhdr", "titlesec", "appendix", "soul", "ulem", "csquotes", "physics", "nicefrac", "placeins", "subfiles"]

    /// Candidates for a request, best matches first.
    public static func items(for request: CompletionRequest, index: ProjectIndex, limit: Int = 60) -> [CompletionItem] {
        let candidates: [CompletionItem]
        switch request.kind {
        case .citation: candidates = index.citations
        case .reference: candidates = index.labels
        case .graphics: candidates = index.graphics.map { CompletionItem(label: $0) }
        case .input: candidates = index.inputs.map { CompletionItem(label: $0) }
        case .bibliography: candidates = index.bibliographies.map { CompletionItem(label: request.command.lowercased() == "bibliography" && $0.hasSuffix(".bib") ? String($0.dropLast(4)) : $0) }
        case .package: candidates = packages.map { CompletionItem(label: $0) }
        case .environment: candidates = unique(index.environments + environments).map { CompletionItem(label: $0, detail: index.environments.contains($0) ? L10n.tr("项目定义") : "") }
        case .command:
            var seen = Set<String>(); var list: [CompletionItem] = []
            for name in index.commands where seen.insert(name).inserted { list.append(CompletionItem(label: "\\" + name, detail: L10n.tr("项目定义"))) }
            for name in twoArguments where seen.insert(name).inserted { list.append(CompletionItem(label: "\\" + name, insert: "\\\(name){}{}", caret: name.utf16.count + 2)) }
            for name in oneArgument where seen.insert(name).inserted {
                list.append(name == "item" ? CompletionItem(label: "\\item", insert: "\\item ") : CompletionItem(label: "\\" + name, insert: "\\\(name){}", caret: name.utf16.count + 2))
            }
            for name in plain where seen.insert(name).inserted { list.append(CompletionItem(label: "\\" + name)) }
            candidates = list
        }
        let needle = (request.kind == .command ? "\\" + request.prefix : request.prefix).lowercased()
        guard !needle.isEmpty else { return Array(candidates.prefix(limit)) }
        var starts: [CompletionItem] = [], contains: [CompletionItem] = [], described: [CompletionItem] = []
        for item in candidates {
            let label = item.label.lowercased()
            if label.hasPrefix(needle) { starts.append(item) }
            else if request.kind != .command, label.contains(needle) { contains.append(item) }
            else if request.kind == .citation, item.detail.lowercased().contains(needle) { described.append(item) }
        }
        // Shorter names first among prefix matches, so \in is not buried under \infty, \int…
        starts.sort { $0.label.count < $1.label.count }
        let result = Array((starts + contains + described).prefix(limit))
        // Typing a complete name that needs no expansion leaves nothing to offer.
        if result.count == 1, result[0].insert.lowercased() == needle { return [] }
        return result
    }
    private static func unique(_ values: [String]) -> [String] { var seen = Set<String>(); return values.filter { seen.insert($0).inserted } }

    /// The edit that accepting `item` makes: the range to replace, its new text and the caret afterwards.
    public static func apply(_ item: CompletionItem, to request: CompletionRequest, in text: String) -> (range: NSRange, replacement: String, caret: Int) {
        let ns = text as NSString; var range = request.range; var replacement = item.insert
        guard request.kind != .command else { return (range, replacement, range.location + (item.caret ?? (replacement as NSString).length)) }
        let end = NSMaxRange(range)
        let closed = end < ns.length && ns.character(at: end) == 125
        if !closed { replacement += "}" } else { range.length += 1; replacement += "}" }
        var caret = range.location + (replacement as NSString).length
        if request.command == "begin" {
            // Add the body and the matching \end unless the line already continues after the brace.
            let after = NSMaxRange(range), lineEnd = NSMaxRange(ns.lineRange(for: NSRange(location: min(after, ns.length), length: 0)))
            let rest = after <= ns.length ? ns.substring(with: NSRange(location: after, length: max(0, min(lineEnd, ns.length) - after))) : ""
            if rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let lineStart = ns.lineRange(for: NSRange(location: request.range.location, length: 0)).location
                let indent = String(ns.substring(with: NSRange(location: lineStart, length: request.range.location - lineStart)).prefix { $0 == " " || $0 == "\t" })
                let body = ["itemize", "enumerate", "description"].contains(item.insert) ? "\\item " : ""
                replacement += "\n\(indent)  \(body)"
                caret = range.location + (replacement as NSString).length
                replacement += "\n\(indent)\\end{\(item.insert)}"
            }
        }
        return (range, replacement, caret)
    }
}
