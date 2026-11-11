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

public final class GitService {
    let directory: URL
    let tools: Toolchain
    public init(directory: URL, tools: Toolchain) { self.directory = directory; self.tools = tools }
    public func command(_ arguments: [String]) throws -> CommandResult {
        guard let git = tools["git"] else { throw BetterTeXError.message("未检测到 Git，请安装 Xcode Command Line Tools。") }
        var env = tools.environment; env["GIT_TERMINAL_PROMPT"] = "0"; env["GCM_INTERACTIVE"] = "never"
        return try ProcessRunner().run(git, ["-c", "core.quotepath=false"] + arguments, directory: directory, environment: env, timeout: 60)
    }
    public func checked(_ arguments: [String]) throws -> String {
        let result = try command(arguments)
        guard result.succeeded else { throw BetterTeXError.message(result.output.isEmpty ? "Git 操作失败（\(result.status)）。" : result.output) }
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
    public func pull() throws -> String { try checked(["pull", "--ff-only"]) }
    public func push() throws -> String { try checked(["push"]) }
    public func commitAndPush(message: String, paths: [String]) throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !paths.isEmpty else { throw BetterTeXError.message("请填写提交说明并选择文件。") }
        let root = try checked(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .newlines)
        let existing = paths.filter { FileManager.default.fileExists(atPath: URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent($0).path) }
        if !existing.isEmpty { _ = try checked(["-C", root, "add", "--"] + existing) }
        _ = try checked(["-C", root, "commit", "-m", message, "--"] + paths)
        return try push()
    }
}
