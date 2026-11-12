import Foundation

/// How much the agent may touch, mapped to Codex's own sandbox modes.
public enum CodexSandbox: String, CaseIterable {
    case readOnly = "read-only", workspaceWrite = "workspace-write", fullAccess = "danger-full-access"
    public var title: String { switch self { case .readOnly: return L10n.tr("只读"); case .workspaceWrite: return L10n.tr("可改项目"); case .fullAccess: return L10n.tr("完全访问") } }
    public var detail: String {
        switch self {
        case .readOnly: return L10n.tr("只能读取文件和运行只读命令")
        case .workspaceWrite: return L10n.tr("可以修改项目文件夹里的文件，不能联网")
        case .fullAccess: return L10n.tr("不受沙盒限制，可读写任意文件并联网")
        }
    }
}

/// One entry of a Codex turn: a message, a command it ran, files it changed, and so on.
public struct CodexItem: Equatable {
    public enum Kind: Equatable { case message, reasoning, command, fileChange, toolCall, webSearch, todo, notice }
    public enum Status: Equatable { case running, done, failed }
    public let id: String
    public let kind: Kind
    /// The message, the command line, the tool name or the search query.
    public var text: String
    /// Command output, changed paths or checklist lines.
    public var detail: String
    public var status: Status
    public var exitCode: Int?
    /// For file changes: unified-diff body lines, each starting with "+", "-" or a space.
    public var diff: String
    public init(id: String, kind: Kind, text: String, detail: String = "", status: Status = .done, exitCode: Int? = nil, diff: String = "") {
        self.id = id; self.kind = kind; self.text = text; self.detail = detail; self.status = status; self.exitCode = exitCode; self.diff = diff
    }
}

/// The JSON Lines events printed by `codex exec --json`.
public enum CodexEvent: Equatable {
    case threadStarted(String)
    case turnStarted
    case item(CodexItem)
    case turnCompleted(inputTokens: Int, outputTokens: Int)
    case turnFailed(String)
    case contextUsage(AgentContextUsage?)
    case rateLimits(AgentQuotaSnapshot)

    public static func parse(line: String) -> CodexEvent? {
        guard line.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let type = object["type"] as? String else { return nil }
        switch type {
        case "thread.started": return (object["thread_id"] as? String).map(CodexEvent.threadStarted)
        case "turn.started": return .turnStarted
        case "turn.completed":
            let usage = object["usage"] as? [String: Any] ?? [:]
            return .turnCompleted(inputTokens: usage["input_tokens"] as? Int ?? 0, outputTokens: usage["output_tokens"] as? Int ?? 0)
        case "turn.failed": return .turnFailed((object["error"] as? [String: Any])?["message"] as? String ?? L10n.tr("这一轮没有完成。"))
        case "error": return .turnFailed(object["message"] as? String ?? L10n.tr("Codex 报告了一个错误。"))
        case "item.started", "item.updated", "item.completed":
            guard let raw = object["item"] as? [String: Any], let item = item(raw, finished: type == "item.completed") else { return nil }
            return .item(item)
        default: return nil
        }
    }
    private static func item(_ raw: [String: Any], finished: Bool) -> CodexItem? {
        guard let id = raw["id"] as? String, let type = raw["type"] as? String else { return nil }
        let state = raw["status"] as? String
        let status: CodexItem.Status = state == "failed" || state == "declined" ? .failed : (finished || state == "completed") ? .done : .running
        switch type {
        case "agent_message": return CodexItem(id: id, kind: .message, text: raw["text"] as? String ?? "", status: status)
        case "reasoning": return CodexItem(id: id, kind: .reasoning, text: raw["text"] as? String ?? "", status: status)
        case "command_execution":
            let code = raw["exit_code"] as? Int
            return CodexItem(id: id, kind: .command, text: displayCommand(raw["command"] as? String ?? ""), detail: raw["aggregated_output"] as? String ?? "",
                             status: status == .done && (code ?? 0) != 0 ? .failed : status, exitCode: code)
        case "file_change":
            let changes = (raw["changes"] as? [[String: Any]] ?? []).map { change -> String in
                let kind = ["add": L10n.tr("新增"), "delete": L10n.tr("删除"), "update": L10n.tr("修改")][change["kind"] as? String ?? ""] ?? (change["kind"] as? String ?? "")
                return "\(kind)  \(change["path"] as? String ?? "")"
            }
            return CodexItem(id: id, kind: .fileChange, text: L10n.tr("\(changes.count) 个文件"), detail: changes.joined(separator: "\n"), status: status)
        case "mcp_tool_call": return CodexItem(id: id, kind: .toolCall, text: [raw["server"] as? String, raw["tool"] as? String].compactMap { $0 }.joined(separator: " · "), status: status)
        case "web_search": return CodexItem(id: id, kind: .webSearch, text: raw["query"] as? String ?? "", status: status)
        case "todo_list":
            let lines = (raw["items"] as? [[String: Any]] ?? []).map { ($0["completed"] as? Bool == true ? "☑ " : "☐ ") + ($0["text"] as? String ?? "") }
            return CodexItem(id: id, kind: .todo, text: L10n.tr("计划"), detail: lines.joined(separator: "\n"), status: status)
        case "error": return CodexItem(id: id, kind: .notice, text: raw["message"] as? String ?? "", status: .done)
        default: return nil
        }
    }
    /// Codex wraps every command as `/bin/zsh -lc '…'`; show just the command.
    static func displayCommand(_ command: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "^(?:/\\S+/)?(?:zsh|bash|sh)\\s+-l?c\\s+(['\"])(.*)\\1$", options: [.dotMatchesLineSeparators]) else { return command }
        let ns = command as NSString
        guard let match = regex.firstMatch(in: command, range: NSRange(location: 0, length: ns.length)) else { return command }
        return ns.substring(with: match.range(at: 2)).replacingOccurrences(of: "'\\''", with: "'")
    }
}

/// One prompt sent to Codex through its non-interactive interface.
public struct CodexRequest {
    public var prompt: String
    /// Continue this conversation instead of starting a new one.
    public var thread: String?
    public var configuration: AgentConfiguration
    public var sandbox: CodexSandbox
    public init(prompt: String, thread: String? = nil, configuration: AgentConfiguration = AgentConfiguration(), sandbox: CodexSandbox = .workspaceWrite) {
        self.prompt = prompt; self.thread = thread; self.configuration = configuration; self.sandbox = sandbox
    }
    /// Arguments for `codex`. The prompt travels as its own argument after `--`, never through a shell.
    public func arguments() throws -> [String] {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BetterTeXError.message(L10n.tr("请输入要发给 Codex 的内容。")) }
        var arguments = ["exec"]
        if let thread {
            guard thread.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{7,63}$", options: .regularExpression) != nil else { throw BetterTeXError.message(L10n.tr("会话 ID 无效，无法继续。")) }
            arguments.append("resume")
        }
        arguments += ["--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"\(sandbox.rawValue)\""]
        arguments += try configuration.arguments(for: .codex)
        arguments.append("--")
        if let thread { arguments.append(thread) }
        arguments.append(prompt)
        return arguments
    }
}

/// Runs one Codex turn and reports its events as they arrive. Uses whatever account the user's
/// own `codex` CLI is signed in to; BetterTeX never sees or stores those credentials.
public final class CodexTurn {
    public let runner = ProcessRunner()
    public init() {}
    public func cancel() { runner.cancel() }
    /// Blocks until the turn ends. Returns the process status and the trailing non-JSON output (for error messages).
    public func run(_ request: CodexRequest, executable: String, directory: URL, environment: [String: String], onEvent: @escaping (CodexEvent) -> Void) throws -> (status: Int32, stderr: String) {
        var pending = "", noise: [String] = []
        func consume(_ line: String) {
            if let event = CodexEvent.parse(line: line) { onEvent(event) }
            else if !line.trimmingCharacters(in: .whitespaces).isEmpty { noise.append(String(line.prefix(400))); if noise.count > 12 { noise.removeFirst() } }
        }
        let result = try runner.run(executable, try request.arguments(), directory: directory, environment: environment, timeout: 3600) { chunk in
            pending += chunk
            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newline]); pending = String(pending[pending.index(after: newline)...])
                consume(line)
            }
        }
        if !pending.isEmpty { consume(pending) }
        return (result.status, noise.joined(separator: "\n"))
    }
}
