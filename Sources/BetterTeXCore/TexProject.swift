import Foundation

public enum TeXEngine: String, CaseIterable {
    case automatic = "Auto", latexmk = "latexmk", pdfLaTeX = "pdfLaTeX", xeLaTeX = "XeLaTeX", luaLaTeX = "LuaLaTeX"
    public var executable: String { rawValue.lowercased() }
}

public enum TeXProject {
    public static func directive(_ key: String, in text: String) -> String? {
        let pattern = "(?im)^\\s*%\\s*!\\s*TEX\\s+" + NSRegularExpression.escapedPattern(for: key) + "\\s*=\\s*([^\\r\\n]+)"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    public static func root(active: URL, project: URL) throws -> URL {
        var candidate = active.standardizedFileURL
        var visited = Set<String>()
        for _ in 0..<12 {
            guard visited.insert(candidate.path).inserted else { throw BetterTeXError.message("检测到循环的 % !TeX root 指令。") }
            let text = (try? String(contentsOf: candidate, encoding: .utf8)) ?? ""
            if let relative = directive("root", in: text) {
                candidate = URL(fileURLWithPath: relative, relativeTo: candidate.deletingLastPathComponent()).standardizedFileURL
                guard FileManager.default.fileExists(atPath: candidate.path) else { throw BetterTeXError.message("主文件不存在：\(candidate.path)") }
                continue
            }
            if text.contains("\\documentclass") { return candidate }
            break
        }
        let files = sourceFiles(in: project)
        let mains = files.filter { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains("\\documentclass") }
        if let main = mains.first(where: { $0.lastPathComponent == "main.tex" }) { return main }
        if mains.count == 1 { return mains[0] }
        if mains.count > 1 { throw BetterTeXError.message("发现多个主文件。请打开要编译的主文件，或在子文件首行添加 % !TeX root = ../main.tex。") }
        throw BetterTeXError.message("未找到含 \\documentclass 的主文件。请打开 LaTeX 项目或设置 % !TeX root。")
    }

    public static func sourceFiles(in directory: URL) -> [URL] {
        let excluded: Set<String> = [".git", ".build", ".bettertex", "node_modules", "dist", "build", ".venv"]
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []; var visited = 0
        while let url = iterator.nextObject() as? URL {
            visited += 1; if visited > 10_000 { break }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if excluded.contains(url.lastPathComponent) || values?.isSymbolicLink == true || url.pathComponents.count - directory.pathComponents.count > 6 { iterator.skipDescendants(); continue }
            if url.pathExtension.lowercased() == "tex" { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    public static func engine(for text: String, selected: TeXEngine) -> TeXEngine {
        if selected != .automatic && selected != .latexmk { return selected }
        if let name = directive("program", in: text)?.lowercased(), let engine = TeXEngine.allCases.first(where: { $0.executable == name && $0 != .latexmk && $0 != .automatic }) { return engine }
        if text.contains("\\usepackage{fontspec}") || text.contains("\\setmainfont") || text.contains("ctex") || text.contains("xeCJK") { return .xeLaTeX }
        return .pdfLaTeX
    }
}

public struct DiskSnapshot: Equatable {
    public let data: Data
    public init(url: URL) throws { data = try Data(contentsOf: url) }
    public func isCurrent(at url: URL) -> Bool { (try? Data(contentsOf: url)) == data }
}

/// An undefined reference or citation reported by LaTeX. The log names only the line, so the
/// key is kept to find out which source file the warning belongs to.
public struct TeXWarning: Equatable {
    public let line: Int
    public let key: String
    public let message: String
    public static func parse(_ log: String) -> [TeXWarning] {
        // The log wraps at 79 columns; join the pieces before matching.
        let joined = log.replacingOccurrences(of: "\n", with: "")
        let regex = try! NSRegularExpression(pattern: "(?:LaTeX|Package \\w+) Warning: (Reference|Citation) [`']([^']+)' (?:on page \\d+ )?undefined on input line (\\d+)")
        let ns = joined as NSString; var seen = Set<String>(); var result: [TeXWarning] = []
        for match in regex.matches(in: joined, range: NSRange(location: 0, length: ns.length)) {
            guard let line = Int(ns.substring(with: match.range(at: 3))) else { continue }
            let key = ns.substring(with: match.range(at: 2)), citation = ns.substring(with: match.range(at: 1)) == "Citation"
            if seen.insert("\(line)|\(key)").inserted { result.append(TeXWarning(line: line, key: key, message: (citation ? "未定义的引用文献：" : "未定义的交叉引用：") + key)) }
        }
        return result
    }
}

public struct TeXDiagnostic {
    public let file: String
    public let line: Int
    public let message: String
    public static func parse(_ log: String) -> [TeXDiagnostic] {
        let regex = try! NSRegularExpression(pattern: "^(.+\\.(?:tex|sty|cls)):(\\d+):\\s*(.+)$", options: [.anchorsMatchLines])
        let ns = log as NSString
        return regex.matches(in: log, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let line = Int(ns.substring(with: match.range(at: 2))) else { return nil }
            return TeXDiagnostic(file: ns.substring(with: match.range(at: 1)), line: line, message: ns.substring(with: match.range(at: 3)))
        }
    }
}
