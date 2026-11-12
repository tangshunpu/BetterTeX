import Foundation

public enum DocumentFiles {
    private static let inputPattern = try! NSRegularExpression(pattern: #"\\(input|include|subfile|subfileinclude|bibliography|addbibresource)\s*(?:\[[^\]]*\])?\s*\{([^}]+)\}"#)

    /// The files a document is built from, in the order the main file brings them in: sources pulled in with
    /// \input, \include or \subfile (followed recursively) and the bibliographies it names. Commented-out lines
    /// do not count, and files that do not exist are left out.
    public static func included(from main: URL, limit: Int = 60) -> [URL] {
        let base = main.deletingLastPathComponent()
        var result: [URL] = []; var seen: Set<String> = [main.standardizedFileURL.path]
        var queue = [main]
        while let file = queue.first, result.count < limit {
            queue.removeFirst()
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: .newlines) {
                let code = uncommented(line)
                let ns = code as NSString
                for match in inputPattern.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                    let command = ns.substring(with: match.range(at: 1))
                    let bibliography = command == "bibliography" || command == "addbibresource"
                    for name in ns.substring(with: match.range(at: 2)).split(separator: ",") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { continue }
                        var url = base.appendingPathComponent(trimmed)
                        if url.pathExtension.isEmpty { url.appendPathExtension(bibliography ? "bib" : "tex") }
                        let path = url.standardizedFileURL.path
                        guard !seen.contains(path), FileManager.default.fileExists(atPath: path) else { continue }
                        seen.insert(path); result.append(url.standardizedFileURL)
                        if url.pathExtension.lowercased() == "tex" { queue.append(url) }
                    }
                }
            }
        }
        return result
    }

    /// The line up to its first unescaped `%`.
    private static func uncommented(_ line: String) -> String {
        var previous: Character = " "
        for (index, character) in zip(line.indices, line) {
            if character == "%", previous != "\\" { return String(line[..<index]) }
            previous = character
        }
        return line
    }
}
