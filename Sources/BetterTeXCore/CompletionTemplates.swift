import Foundation

/// Environment bodies are shared by \begin{…} and command-style shortcuts such as \fig.
enum EnvironmentTemplate {
    private static let cursor = "\u{E000}"

    static func detail(for name: String) -> String {
        switch name {
        case "figure", "figure*": return L10n.tr("图片模板 · graphicx")
        case "subfigure": return L10n.tr("子图模板 · subcaption")
        case "table", "table*", "tabular": return L10n.tr("表格模板")
        case "tabularx": return L10n.tr("自适应表格 · tabularx")
        case "itemize", "enumerate", "description": return L10n.tr("列表模板 · 含 item")
        default: return L10n.tr("环境模板 · 配对 end")
        }
    }

    /// A marker identifies the first editable field without putting placeholder text in the document.
    private static func parts(for name: String) -> (suffix: String, body: String) {
        switch name {
        case "figure", "figure*", "subfigure":
            return (name == "subfigure" ? "[b]{0.48\\textwidth}" : "[htbp]",
                    "  \\centering\n  \\includegraphics[width=\\linewidth]{\(cursor)}\n  \\caption{}\n  % \\label{fig:}")
        case "table", "table*":
            return ("[htbp]", "  \\centering\n  \\caption{\(cursor)}\n  % \\label{tab:}\n  \\begin{tabular}{ll}\n    \\hline\n     &  \\\\\n    \\hline\n     &  \\\\\n    \\hline\n  \\end{tabular}")
        case "tabular": return ("{\(cursor)}", "   &  \\\\")
        case "tabularx": return ("{\\linewidth}{\(cursor)}", "   &  \\\\")
        case "array": return ("{\(cursor)}", "   &  \\\\")
        case "itemize", "enumerate": return ("", "  \\item \(cursor)")
        case "description": return ("", "  \\item[\(cursor)] ")
        case "minipage": return ("{0.48\\textwidth}", "  \(cursor)")
        case "thebibliography": return ("{99}", "  \\bibitem{\(cursor)} ")
        case "frame": return ("{\(cursor)}", "  ")
        case "columns": return ("", "  \\begin{column}{0.48\\textwidth}\n    \(cursor)\n  \\end{column}\n  \\begin{column}{0.48\\textwidth}\n    \n  \\end{column}")
        case "column": return ("{0.48\\textwidth}", "  \(cursor)")
        case "algorithm": return ("", "  \\caption{\(cursor)}\n  % \\label{alg:}")
        default: return ("", "  \(cursor)")
        }
    }

    static func expansion(name: String, opening: String, indent: String, newline: String,
                          suffix: String = "") -> (text: String, caret: Int) {
        let parts = parts(for: name)
        // Existing placement options / required arguments take precedence over defaults.
        var header = suffix.isEmpty ? parts.suffix : suffix
        if !suffix.isEmpty, !suffix.contains("{"), let arguments = parts.suffix.firstIndex(of: "{") {
            header += parts.suffix[arguments...]
        }
        var body = parts.body
        if !header.contains(cursor), !body.contains(cursor) { body = "  " + cursor + body.dropFirst(2) }
        let unit = indent.contains("\t") ? "\t" : "  "
        let lines = body.components(separatedBy: "\n").map { line -> String in
            let spaces = line.prefix { $0 == " " }.count
            return indent + String(repeating: unit, count: spaces / 2) + String(repeating: " ", count: spaces % 2) + line.dropFirst(spaces)
        }
        let marked = opening + header + newline + lines.joined(separator: newline) + newline + indent + "\\end{\(name)}"
        let caret = (marked as NSString).range(of: cursor).location
        return (marked.replacingOccurrences(of: cursor, with: ""), caret)
    }
}

/// Only inspects TeX structure; translated UI strings never participate in matching.
enum CompletionEnvironmentContext {
    private static let token = try! NSRegularExpression(pattern: #"\\(begin|end)\s*\{([^{}\r\n]+)\}"#)
    private static let opaque: Set<String> = ["verbatim", "verbatim*", "Verbatim", "lstlisting", "minted", "comment"]

    static func hasClosing(_ name: String, after position: Int, in text: String) -> Bool {
        let ns = text as NSString
        var nested: [String] = []
        for match in token.matches(in: text, range: NSRange(location: position, length: ns.length - position)) {
            let command = ns.substring(with: match.range(at: 1)), environment = ns.substring(with: match.range(at: 2))
            if let current = nested.last, opaque.contains(current) {
                if command == "end", environment == current { nested.removeLast() }
                continue
            }
            guard isUnescaped(at: match.range.location, in: ns), !isComment(at: match.range.location, in: ns) else { continue }
            if command == "begin" { nested.append(environment) }
            else if let current = nested.last {
                guard environment == current else { return false }
                nested.removeLast()
            } else { return environment == name }
        }
        return false
    }

    static func isUnescaped(at position: Int, in text: NSString) -> Bool {
        var index = position - 1, slashes = 0
        while index >= 0, text.character(at: index) == 92 { slashes += 1; index -= 1 }
        return slashes % 2 == 0
    }

    static func isComment(at position: Int, in text: NSString) -> Bool {
        let start = text.lineRange(for: NSRange(location: position, length: 0)).location
        for index in start..<position where text.character(at: index) == 37 && isUnescaped(at: index, in: text) { return true }
        return false
    }

    /// A completed header may already have placement options or mandatory arguments.
    static func isHeaderSuffix(_ suffix: String) -> Bool {
        var stack: [Character] = []
        var escaped = false
        for character in suffix {
            if escaped { escaped = false; continue }
            if character == "\\", !stack.isEmpty { escaped = true; continue }
            if character == "[" || character == "{" { stack.append(character) }
            else if character == "]" || character == "}" {
                guard stack.popLast() == (character == "]" ? "[" : "{") else { return false }
            } else if stack.isEmpty, !character.isWhitespace { return false }
        }
        return stack.isEmpty && !escaped
    }
}
