import CryptoKit
import Foundation

/// How a TeX source opens and closes groups: net `{`/`}` depth and the environments left open
/// (or closed without a match). Comments, escaped characters and verbatim text are ignored.
public struct TeXBalance: Equatable {
    public var braces = 0
    public var environments: [String] = []
    public init(braces: Int = 0, environments: [String] = []) { self.braces = braces; self.environments = environments }
}

public enum TeXSource {
    /// Environments whose body TeX reads literally, so braces and `%` inside them mean nothing.
    static let verbatim: Set<String> = ["verbatim", "verbatim*", "Verbatim", "lstlisting", "minted", "comment", "filecontents", "filecontents*"]
    /// Commands that take literal text, where `%` is not a comment.
    static let literalCommands = ["\\verb", "\\url", "\\href", "\\path", "\\lstinline", "\\mintinline"]

    public static func balance(of text: String) -> TeXBalance {
        let bytes = Array(text.utf8); var result = TeXBalance(); var i = 0
        func isLetter(_ b: UInt8) -> Bool { (b >= 65 && b <= 90) || (b >= 97 && b <= 122) }
        func readGroup(from start: Int) -> (String, Int)? {
            var j = start
            while j < bytes.count, bytes[j] == 32 || bytes[j] == 9 { j += 1 }
            guard j < bytes.count, bytes[j] == UInt8(ascii: "{") else { return nil }
            var k = j + 1
            while k < bytes.count, bytes[k] != UInt8(ascii: "}"), bytes[k] != 10 { k += 1 }
            guard k < bytes.count, bytes[k] == UInt8(ascii: "}") else { return nil }
            return (String(decoding: bytes[(j + 1)..<k], as: UTF8.self), k + 1)
        }
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "%") { while i < bytes.count, bytes[i] != 10 { i += 1 }; continue }
            if c == UInt8(ascii: "{") { result.braces += 1; i += 1; continue }
            if c == UInt8(ascii: "}") { result.braces -= 1; i += 1; continue }
            guard c == UInt8(ascii: "\\") else { i += 1; continue }
            i += 1; guard i < bytes.count else { result.environments.append("?\\"); break }
            guard isLetter(bytes[i]) else { i += 1; continue }  // \{ \} \% \\ and friends
            let start = i; while i < bytes.count, isLetter(bytes[i]) { i += 1 }
            let name = String(decoding: bytes[start..<i], as: UTF8.self)
            if name == "verb", i < bytes.count {
                let delimiter = bytes[i]; i += 1
                while i < bytes.count, bytes[i] != delimiter, bytes[i] != 10 { i += 1 }
                i += 1; continue
            }
            guard name == "begin" || name == "end" else { continue }
            guard let (env, next) = readGroup(from: i) else { result.environments.append("?\(name)"); continue }
            i = next
            if name == "begin" {
                if verbatim.contains(env) {
                    let closing = Array("\\end{\(env)}".utf8)
                    if let end = find(closing, in: bytes, from: i) { i = end + closing.count } else { result.environments.append(env); break }
                } else { result.environments.append(env) }
            } else if result.environments.last == env { result.environments.removeLast() }
            else { result.environments.append("/" + env) }
        }
        return result
    }

    /// Source text reduced to what can change the typeset output: comments, trailing spaces and
    /// repeated blank lines are dropped. Two texts with equal forms produce the same document.
    public static func normalized(_ text: String) -> String {
        var lines: [Substring] = []; var inVerbatim: String?; var blank = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw
            if let env = inVerbatim {
                lines.append(line); if line.contains("\\end{\(env)}") { inVerbatim = nil }
                blank = false; continue
            }
            if let env = verbatim.first(where: { line.contains("\\begin{\($0)}") }), !line.contains("\\end{\(env)}") {
                inVerbatim = env; lines.append(line); blank = false; continue
            }
            if !literalCommands.contains(where: { line.contains($0) }), let comment = commentStart(in: line) {
                var code = line[..<comment]
                let spaced = code.last.map { $0 == " " || $0 == "\t" } ?? true
                while let last = code.last, last == " " || last == "\t" { code = code.dropLast() }
                // A line that is only a comment contributes nothing, and must not turn into a paragraph break.
                if code.allSatisfy({ $0 == " " || $0 == "\t" }) { continue }
                // `%` swallows the line break; right after text that removes a space, so it stays.
                line = spaced ? code : code + "%"
            }
            while let last = line.last, last == " " || last == "\t" || last == "\r" { line = line.dropLast() }
            if line.isEmpty { if blank { continue }; blank = true } else { blank = false }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func commentStart(in line: Substring) -> Substring.Index? {
        var backslashes = 0; var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if c == "%", backslashes % 2 == 0 { return index }
            backslashes = c == "\\" ? backslashes + 1 : 0
            index = line.index(after: index)
        }
        return nil
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var i = start
        while i + needle.count <= haystack.count {
            if haystack[i] == needle[0], Array(haystack[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }
}

public enum AutoBuildTiming {
    /// How long to wait after the last keystroke before an automatic build. A finished sentence,
    /// line or group builds sooner; a word in progress waits longer, and so does a slow document.
    public static func delay(previousCharacter: Character?, lastBuildSeconds: TimeInterval?) -> TimeInterval {
        let settled: Set<Character> = ["\n", ".", "!", "?", ";", "}", "$", "。", "！", "？", "；", "，", ",", "、"]
        let base: TimeInterval = previousCharacter.map { settled.contains($0) } == true ? 0.7 : 1.4
        let cost = min(2.0, max(0, (lastBuildSeconds ?? 0) * 0.25))
        return min(3.5, base + cost)
    }
}

/// Remembers each file's digest by size and modification time, so fingerprinting a project only
/// reads files that changed since the last time.
public final class BuildSignatureCache {
    private struct Entry { let size: Int; let modified: TimeInterval; let digest: String }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    public init() {}
    func digest(path: String, size: Int, modified: TimeInterval, compute: () -> String) -> String {
        lock.lock(); let cached = entries[path]; lock.unlock()
        if let cached, cached.size == size, cached.modified == modified { return cached.digest }
        let digest = compute()
        lock.lock(); entries[path] = Entry(size: size, modified: modified, digest: digest); lock.unlock()
        return digest
    }
    public func reset() { lock.lock(); entries = [:]; lock.unlock() }
}

public enum BuildSignature {
    static let textSources: Set<String> = ["tex", "ltx", "sty", "cls", "clo", "def", "cfg", "fd", "tikz", "pgf"]
    /// Files TeX writes for itself or editors leave behind; they never feed a build.
    static let ignoredExtensions: Set<String> = ["log", "aux", "fls", "fdb_latexmk", "blg", "toc", "lof", "lot", "out", "nav", "snm", "vrb",
                                                 "xdv", "dvi", "ilg", "bcf", "synctex", "swp", "swo", "tmp", "bak", "md", "py", "ipynb", "sh"]
    static let ignoredFolders: Set<String> = ["node_modules", "__pycache__"]

    /// A fingerprint of everything a build reads: the root document, the engine and the source files.
    /// TeX sources count by meaning (comments and whitespace that cannot change the PDF are left out),
    /// other inputs by size and modification time. Equal fingerprints mean a rebuild would change nothing.
    public static func compute(project: URL, root: String, engine: String, cache: BuildSignatureCache? = nil) -> String {
        var entries: [String] = ["root=\(root)", "engine=\(engine)"]
        let base = project.standardizedFileURL.path
        let rootURL = URL(fileURLWithPath: root)
        let rootPDF = rootURL.deletingPathExtension().appendingPathExtension("pdf").standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        if let iterator = FileManager.default.enumerator(at: project, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            var visited = 0
            while let url = iterator.nextObject() as? URL {
                visited += 1; if visited > 20_000 { entries.append("truncated"); break }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true { if ignoredFolders.contains(url.lastPathComponent) { iterator.skipDescendants() }; continue }
                guard values.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.path, ext = url.pathExtension.lowercased()
                if ignoredExtensions.contains(ext) || path.hasSuffix(".synctex.gz") || path.hasSuffix("~") || path == rootPDF { continue }
                let size = values.fileSize ?? 0, stamp = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                let fingerprint: String
                if textSources.contains(ext), size < 4_000_000 {
                    let read = { () -> String in
                        guard let data = try? Data(contentsOf: url) else { return "unreadable|\(size)|\(stamp)" }
                        let text = String(decoding: data, as: UTF8.self)
                        return SHA256.hash(data: Data(TeXSource.normalized(text).utf8)).map { String(format: "%02x", $0) }.joined()
                    }
                    fingerprint = cache?.digest(path: path, size: size, modified: stamp, compute: read) ?? read()
                } else { fingerprint = "\(size)|\(stamp)" }
                entries.append("\(path.dropFirst(base.count))|\(fingerprint)")
            }
        }
        return entries.sorted().joined(separator: "\n")
    }
}
