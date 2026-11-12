import Foundation

public struct GitChange {
    public let status: String
    public let path: String
    public let originalPath: String?
    public var isUntracked: Bool { status == "??" }
    public var commitPaths: [String] { [path] + (originalPath.map { [$0] } ?? []) }
}
public struct GitState {
    public let branch: String
    public let changes: [GitChange]
    public let hasRemote: Bool
}

/// A run of lines in the working copy that differs from the last commit.
public struct LineChange: Equatable {
    public enum Kind { case added, modified, deleted }
    public let kind: Kind
    /// 1-based lines in the current file. For `deleted`, the single line the removed text sat before.
    public let lines: ClosedRange<Int>
    /// The whole `git diff` hunk this run came from (both halves of a grown replacement share it).
    public let hunk: Hunk?
    /// 1-based line spans of a hunk; a count of 0 means nothing on that side.
    public struct Hunk: Equatable {
        public let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
        public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) { self.oldStart = oldStart; self.oldCount = oldCount; self.newStart = newStart; self.newCount = newCount }
    }
    public init(_ kind: Kind, _ lines: ClosedRange<Int>, hunk: Hunk? = nil) { self.kind = kind; self.lines = lines; self.hunk = hunk }
    /// Two runs are the same change when they mark the same lines; the hunk is supporting detail.
    public static func == (lhs: LineChange, rhs: LineChange) -> Bool { lhs.kind == rhs.kind && lhs.lines == rhs.lines }

    /// Reads the hunk headers of `git diff -U0` output.
    public static func parse(diff: String) -> [LineChange] {
        var changes: [LineChange] = []
        for line in diff.split(separator: "\n") where line.hasPrefix("@@ ") {
            let fields = line.split(separator: " ")
            guard fields.count >= 3, fields[1].hasPrefix("-"), fields[2].hasPrefix("+") else { continue }
            func span(_ field: Substring) -> (start: Int, count: Int)? {
                let numbers = field.dropFirst().split(separator: ",")
                guard let first = numbers.first, let start = Int(first) else { return nil }
                return (start, numbers.count > 1 ? Int(numbers[1]) ?? 1 : 1)
            }
            guard let old = span(fields[1]), let new = span(fields[2]) else { continue }
            let hunk = Hunk(oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count)
            if new.count == 0 { let at = new.start + 1; changes.append(LineChange(.deleted, at...at, hunk: hunk)) }
            else if old.count == 0 { changes.append(LineChange(.added, new.start...(new.start + new.count - 1), hunk: hunk)) }
            else {
                // A replacement that grew: the first lines count as modified, the surplus as added.
                let rewritten = min(old.count, new.count)
                changes.append(LineChange(.modified, new.start...(new.start + rewritten - 1), hunk: hunk))
                if new.count > rewritten { changes.append(LineChange(.added, (new.start + rewritten)...(new.start + new.count - 1), hunk: hunk)) }
            }
        }
        return changes
    }
}

public final class GitService {
    let directory: URL
    let tools: Toolchain
    public init(directory: URL, tools: Toolchain) { self.directory = directory; self.tools = tools }
    public func command(_ arguments: [String]) throws -> CommandResult {
        guard let git = tools["git"] else { throw BetterTeXError.message(L10n.tr("未检测到 Git，请安装 Xcode Command Line Tools。")) }
        var env = tools.environment; env["GIT_TERMINAL_PROMPT"] = "0"; env["GCM_INTERACTIVE"] = "never"
        return try ProcessRunner().run(git, ["-c", "core.quotepath=false"] + arguments, directory: directory, environment: env, timeout: 60)
    }
    public func checked(_ arguments: [String]) throws -> String {
        let result = try command(arguments)
        guard result.succeeded else { throw BetterTeXError.message(result.output.isEmpty ? L10n.tr("Git 操作失败（\(result.status)）。") : result.output) }
        return result.output
    }
    public func state() throws -> GitState {
        _ = try checked(["rev-parse", "--show-toplevel"])
        let branch = try checked(["symbolic-ref", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let status = try checked(["status", "--porcelain=v1", "-z", "--untracked-files=normal"])
        let remotes = try checked(["remote"])
        return GitState(branch: branch, changes: Self.parseStatus(status), hasRemote: !remotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    public static func parseStatus(_ output: String) -> [GitChange] {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var changes: [GitChange] = []; var index = 0
        while index < records.count {
            let record = records[index]; index += 1
            guard record.count >= 4 else { continue }
            let status = String(record.prefix(2)); let path = String(record.dropFirst(3))
            var original: String?
            if status.contains("R") || status.contains("C") {
                if index < records.count { original = records[index] }; index += 1
            }
            changes.append(GitChange(status: status, path: path, originalPath: original))
        }
        return changes
    }
    /// Lines of `file` that differ from HEAD. An untracked file is one big addition; a file
    /// outside any repository (or a repository without commits) has no changes to show.
    public func lineChanges(file: URL) -> [LineChange] {
        guard let root = try? checked(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .newlines), !root.isEmpty else { return [] }
        let path = file.resolvingSymlinksInPath().path
        if let tracked = try? command(["-C", root, "ls-files", "--error-unmatch", "--", path]), !tracked.succeeded {
            guard let ignored = try? command(["-C", root, "check-ignore", "-q", "--", path]), !ignored.succeeded,
                  let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else { return [] }
            let lines = text.components(separatedBy: "\n").count - (text.hasSuffix("\n") ? 1 : 0)
            return [LineChange(.added, 1...max(1, lines), hunk: LineChange.Hunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: max(1, lines)))]
        }
        guard let diff = try? checked(["-C", root, "diff", "--no-color", "--no-ext-diff", "-U0", "HEAD", "--", path]) else { return [] }
        return LineChange.parse(diff: diff)
    }
    /// The committed text of `file`, or nil when it is untracked or outside a repository.
    public func headText(file: URL) -> String? {
        guard let root = try? checked(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .newlines), !root.isEmpty else { return nil }
        let path = file.resolvingSymlinksInPath().path
        guard path.hasPrefix(root + "/") else { return nil }
        return try? checked(["-C", root, "show", "HEAD:" + String(path.dropFirst(root.count + 1))])
    }
    public func pull() throws -> String { try checked(["pull", "--ff-only"]) }
    public func push() throws -> String { try checked(["push"]) }
    public func commitAndPush(message: String, paths: [String]) throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !paths.isEmpty else { throw BetterTeXError.message(L10n.tr("请填写提交说明并选择文件。")) }
        let root = try checked(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .newlines)
        let existing = paths.filter { FileManager.default.fileExists(atPath: URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent($0).path) }
        if !existing.isEmpty { _ = try checked(["-C", root, "add", "--"] + existing) }
        _ = try checked(["-C", root, "commit", "-m", message, "--"] + paths)
        return try push()
    }
}
