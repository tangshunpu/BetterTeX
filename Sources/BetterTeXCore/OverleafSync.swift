import Foundation
import CryptoKit

/// Line-based three-way merge used when both the local copy and Overleaf changed a file.
public enum Merge3 {
    public enum ConflictStyle { case markers, preferOurs }
    public static let oursMarker = "<<<<<<< BetterTeX（本地）"
    public static let theirsMarker = ">>>>>>> Overleaf"

    public static func merge(base: String, ours: String, theirs: String, style: ConflictStyle) -> (text: String, conflicts: Int) {
        if ours == theirs || theirs == base { return (ours, 0) }
        if ours == base { return (theirs, 0) }
        let o = base.components(separatedBy: "\n"), a = ours.components(separatedBy: "\n"), b = theirs.components(separatedBy: "\n")
        let matchA = matches(o, a), matchB = matches(o, b)
        var output: [String] = []; var conflicts = 0
        var io = 0, ia = 0, ib = 0
        func emit(_ oChunk: ArraySlice<String>, _ aChunk: ArraySlice<String>, _ bChunk: ArraySlice<String>) {
            if aChunk == bChunk || bChunk == oChunk { output.append(contentsOf: aChunk) }
            else if aChunk == oChunk { output.append(contentsOf: bChunk) }
            else {
                conflicts += 1
                if style == .preferOurs { output.append(contentsOf: aChunk) }
                else { output.append(oursMarker); output.append(contentsOf: aChunk); output.append("======="); output.append(contentsOf: bChunk); output.append(theirsMarker) }
            }
        }
        while true {
            var stable = 0
            while io + stable < o.count, matchA[io + stable] == ia + stable, matchB[io + stable] == ib + stable { stable += 1 }
            if stable > 0 { output.append(contentsOf: o[io..<io + stable]); io += stable; ia += stable; ib += stable; continue }
            // Unstable region: runs to the next base line that survives on both sides.
            var next = io
            while next < o.count, matchA[next] < 0 || matchB[next] < 0 { next += 1 }
            if next >= o.count { emit(o[io...], a[ia...], b[ib...]); break }
            emit(o[io..<next], a[ia..<matchA[next]], b[ib..<matchB[next]])
            io = next; ia = matchA[next]; ib = matchB[next]
        }
        return (output.joined(separator: "\n"), conflicts)
    }

    /// For each line of `x`, the index of its partner in `y` along a longest common subsequence (-1 if none).
    static func matches(_ x: [String], _ y: [String]) -> [Int] {
        var result = [Int](repeating: -1, count: x.count)
        var head = 0
        while head < x.count, head < y.count, x[head] == y[head] { result[head] = head; head += 1 }
        var tail = 0
        while tail < x.count - head, tail < y.count - head, x[x.count - 1 - tail] == y[y.count - 1 - tail] { result[x.count - 1 - tail] = y.count - 1 - tail; tail += 1 }
        let n = x.count - head - tail, m = y.count - head - tail
        guard n > 0, m > 0, n * m <= 16_000_000 else { return result }
        let width = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * width + j] = x[head + i] == y[head + j] ? table[(i + 1) * width + j + 1] + 1 : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var i = 0, j = 0
        while i < n, j < m {
            if x[head + i] == y[head + j] { result[head + i] = head + j; i += 1; j += 1 }
            else if table[(i + 1) * width + j] >= table[i * width + j + 1] { i += 1 } else { j += 1 }
        }
        return result
    }

    public static func hasMarkers(_ text: String) -> Bool { text.contains(oursMarker) && text.contains(theirsMarker) }
}

public enum SyncAction: Equatable {
    case download(String)      // Overleaf → local
    case upload(String)        // local → Overleaf
    case merge(String)         // both changed
    case deleteLocal(String)   // removed on Overleaf, untouched locally
    case deleteRemote(String)  // removed locally, untouched on Overleaf
    case record(String)        // both sides already agree; only the base needs updating
    public var path: String {
        switch self { case .download(let p), .upload(let p), .merge(let p), .deleteLocal(let p), .deleteRemote(let p), .record(let p): return p }
    }
}

public enum SyncPlanner {
    /// Compares content hashes of the local folder, Overleaf and the last synced state.
    public static func plan(local: [String: String], remote: [String: String], base: [String: String]) -> [SyncAction] {
        var actions: [SyncAction] = []
        for path in Set(local.keys).union(remote.keys).union(base.keys).sorted() {
            let l = local[path], r = remote[path], b = base[path]
            if l == r { if b != l { actions.append(.record(path)) }; continue }
            guard let b else { actions.append(l == nil ? .download(path) : r == nil ? .upload(path) : .merge(path)); continue }
            if l == b { actions.append(r == nil ? .deleteLocal(path) : .download(path)) }
            else if r == b { actions.append(l == nil ? .deleteRemote(path) : .upload(path)) }
            else if l == nil { actions.append(.download(path)) }
            else if r == nil { actions.append(.upload(path)) }
            else { actions.append(.merge(path)) }
        }
        return actions
    }
}

/// The link between a local folder and an Overleaf project, stored in `.bettertex/overleaf.json`.
public struct OverleafLink: Codable, Equatable {
    public enum Mode: String, Codable { case realtime, interval, manual }
    public var host: String
    public var projectID: String
    public var name: String
    public var mode: Mode = .realtime
    public var intervalMinutes = 5
    /// Path → SHA-256 of the content both sides agreed on at the last sync.
    public var base: [String: String] = [:]
    public var lastSync: Date?

    public init(host: String, projectID: String, name: String) { self.host = host; self.projectID = projectID; self.name = name }

    static func directory(_ project: URL) -> URL { project.appendingPathComponent(".bettertex", isDirectory: true) }
    static func file(_ project: URL) -> URL { directory(project).appendingPathComponent("overleaf.json") }
    static func baseFolder(_ project: URL) -> URL { directory(project).appendingPathComponent("overleaf-base", isDirectory: true) }

    public static func load(project: URL) -> OverleafLink? {
        guard let data = try? Data(contentsOf: file(project)) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OverleafLink.self, from: data)
    }
    public func save(project: URL) throws {
        try FileManager.default.createDirectory(at: Self.directory(project), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.file(project), options: .atomic)
    }
    public static func remove(project: URL) {
        try? FileManager.default.removeItem(at: file(project)); try? FileManager.default.removeItem(at: baseFolder(project))
    }

    /// The text both sides agreed on last time; the ancestor for three-way merges.
    public static func baseText(project: URL, path: String) -> String? {
        try? String(contentsOf: baseFolder(project).appendingPathComponent(path), encoding: .utf8)
    }
    /// Records agreed content for `path` (nil forgets it). Only text is kept as a merge ancestor.
    public mutating func setBase(project: URL, path: String, data: Data?) {
        let copy = Self.baseFolder(project).appendingPathComponent(path)
        guard let data else { base[path] = nil; try? FileManager.default.removeItem(at: copy); return }
        base[path] = OverleafFiles.hash(data)
        if OverleafFiles.isText(path: path, data: data) {
            try? FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: copy, options: .atomic)
        } else { try? FileManager.default.removeItem(at: copy) }
    }
}

public enum OverleafFiles {
    static let ignoredExtensions: Set<String> = ["aux", "log", "out", "toc", "lof", "lot", "fls", "fdb_latexmk", "blg", "bcf", "nav", "snm", "vrb", "xdv"]
    static let textExtensions: Set<String> = ["tex", "bib", "cls", "sty", "bst", "txt", "md", "tikz", "csv", "json", "yml", "yaml", "latexmkrc", "bbx", "cbx", "dtx", "ins", "def", "lco", "rnw", "rtex", "mtx", "ltx", "clo", "cfg", "lua", "py", "r", "gv", "mf", "asy", "bbl"]

    /// Hidden files, BetterTeX's own folder and TeX by-products never travel to Overleaf.
    public static func isIgnored(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        if parts.contains(where: { $0.hasPrefix(".") }) { return true }
        guard let name = parts.last?.lowercased() else { return true }
        if name.hasSuffix(".synctex.gz") || name.hasSuffix(".synctex") || name.hasSuffix(".run.xml") { return true }
        return ignoredExtensions.contains((name as NSString).pathExtension)
    }
    public static func isText(path: String, data: Data) -> Bool {
        guard data.count < 4_000_000, !data.contains(0) else { return false }
        let name = (path as NSString).lastPathComponent.lowercased()
        return (textExtensions.contains((name as NSString).pathExtension) || name == "latexmkrc" || name == "makefile") && String(data: data, encoding: .utf8) != nil
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Path → content hash for every syncable file below `root`.
    public static func scan(_ root: URL) -> [String: String] {
        var result: [String: String] = [:]
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard let iterator = FileManager.default.enumerator(at: URL(fileURLWithPath: base), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return result }
        while let url = iterator.nextObject() as? URL {
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            if isIgnored(relative) { if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile != true { iterator.skipDescendants() }; continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true, (values.fileSize ?? 0) <= 50_000_000,
                  let data = try? Data(contentsOf: url) else { continue }
            result[relative.precomposedStringWithCanonicalMapping] = hash(data)
        }
        return result
    }

    /// Unpacks a project archive downloaded from Overleaf.
    public static func unzip(_ archive: URL, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try ProcessRunner().run("/usr/bin/unzip", ["-q", "-o", archive.path, "-d", directory.path], timeout: 180)
        guard result.succeeded else { throw BetterTeXError.message(L10n.tr("无法解压 Overleaf 项目：\(result.output)")) }
    }
    /// Zips the syncable files of a project for upload as a new Overleaf project.
    public static func zip(project: URL, to archive: URL) throws {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appendingPathComponent("BetterTeX-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        let files = scan(project).keys
        guard !files.isEmpty else { throw BetterTeXError.message(L10n.tr("项目中没有可上传的文件。")) }
        for path in files {
            let target = staging.appendingPathComponent(path)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: project.appendingPathComponent(path), to: target)
        }
        try? manager.removeItem(at: archive)
        let result = try ProcessRunner().run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", staging.path, archive.path], timeout: 180)
        guard result.succeeded else { throw BetterTeXError.message(L10n.tr("无法打包项目：\(result.output)")) }
    }
}
