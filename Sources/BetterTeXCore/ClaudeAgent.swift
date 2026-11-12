import Foundation

/// One prompt sent to Claude Code through its non-interactive ("print") interface.
public struct ClaudeRequest {
    public var prompt: String
    /// Continue this session instead of starting a new one.
    public var session: String?
    public var configuration: AgentConfiguration
    public var sandbox: CodexSandbox
    /// Appended to Claude Code's own system prompt (see `AgentInstructions`).
    public var instructions: String?
    public init(prompt: String, session: String? = nil, configuration: AgentConfiguration = AgentConfiguration(), sandbox: CodexSandbox = .workspaceWrite, instructions: String? = nil) {
        self.prompt = prompt; self.session = session; self.configuration = configuration; self.sandbox = sandbox; self.instructions = instructions
    }
    /// The shared three-step permission picker, expressed as Claude Code permission modes.
    public static func permissionMode(for sandbox: CodexSandbox) -> String {
        switch sandbox { case .readOnly: return "plan"; case .workspaceWrite: return "acceptEdits"; case .fullAccess: return "bypassPermissions" }
    }
    public static func detail(for sandbox: CodexSandbox) -> String {
        switch sandbox {
        case .readOnly: return L10n.tr("计划模式：只阅读和分析，不修改文件")
        case .workspaceWrite: return L10n.tr("自动接受文件修改；其余操作按你的 Claude 权限设置，需要确认的会被拒绝")
        case .fullAccess: return L10n.tr("跳过所有权限确认，可运行任意命令")
        }
    }
    /// Arguments for `claude`. The prompt travels as its own argument after `--`, never through a shell.
    public func arguments() throws -> [String] {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BetterTeXError.message(L10n.tr("请输入要发给 Claude 的内容。")) }
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--permission-mode", Self.permissionMode(for: sandbox)]
        if let instructions, !instructions.isEmpty { arguments += ["--append-system-prompt", instructions] }
        arguments += try configuration.arguments(for: .claude)
        if let session {
            guard session.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{7,63}$", options: .regularExpression) != nil else { throw BetterTeXError.message(L10n.tr("会话 ID 无效，无法继续。")) }
            arguments += ["--resume", session]
        }
        return arguments + ["--", prompt]
    }
}

/// Translates the JSON Lines printed by `claude -p --output-format stream-json` into the same
/// events the Codex conversation uses. Stateful: text arrives in deltas before the finished
/// message, and a tool's result arrives after its call.
public final class ClaudeStream {
    private var items: [String: CodexItem] = [:]
    private var blocks = 0
    /// Paths under this folder are shown relative to it on tool cards.
    private let root: String?
    // Live text: the message being streamed, its open blocks by index, and the ids handed to
    // partial blocks so the finished block replaces the partial one instead of duplicating it.
    private var streamingMessage = "message"
    private var open: [Int: CodexItem] = [:]
    private var partialIDs: [String: [String]] = [:]
    private var usageModel: String?
    private var lastInputTokens: Int?
    private var contextWindows: [String: Int] = [:]
    public init(root: String? = nil) { self.root = root.map { $0.hasSuffix("/") ? $0 : $0 + "/" } }

    public func parse(line: String) -> [CodexEvent] {
        guard line.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let type = object["type"] as? String else { return [] }
        switch type {
        case "system":
            guard object["parent_tool_use_id"] as? String == nil else { return [] }
            if object["subtype"] as? String == "compact_boundary" {
                lastInputTokens = nil
                return [.contextUsage(nil)]
            }
            guard object["subtype"] as? String == "init", let session = object["session_id"] as? String else { return [] }
            usageModel = object["model"] as? String
            return [.threadStarted(session), .turnStarted]
        case "rate_limit_event":
            guard let info = object["rate_limit_info"] as? [String: Any], let quota = AgentQuotaSnapshot.claude(info) else { return [] }
            return [.rateLimits(quota)]
        case "stream_event":
            // Sub-agent chatter stays out of the conversation; only its tool card in the parent shows.
            guard object["parent_tool_use_id"] as? String == nil, let event = object["event"] as? [String: Any] else { return [] }
            return partial(event)
        case "assistant":
            guard object["parent_tool_use_id"] as? String == nil, let message = object["message"] as? [String: Any] else { return [] }
            let messageID = message["id"] as? String ?? "message"
            let usage = contextUsage(message)
            let entries: [CodexEvent] = (message["content"] as? [[String: Any]] ?? []).compactMap { block in
                switch block["type"] as? String {
                case "text": return .item(CodexItem(id: finalID(messageID, "t"), kind: .message, text: block["text"] as? String ?? ""))
                case "thinking": return .item(CodexItem(id: finalID(messageID, "r"), kind: .reasoning, text: block["thinking"] as? String ?? ""))
                case "tool_use":
                    guard let id = block["id"] as? String, let item = Self.item(id: id, tool: block["name"] as? String ?? "", input: block["input"] as? [String: Any] ?? [:], root: root) else { return nil }
                    items[id] = item; return .item(item)
                default: return nil
                }
            }
            return usage + entries
        case "user":
            guard object["parent_tool_use_id"] as? String == nil, let message = object["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] else { return [] }
            let structured = object["tool_use_result"] as? [String: Any]
            return blocks.compactMap { block in
                guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String, var item = items[id] else { return nil }
                item.status = block["is_error"] as? Bool == true ? .failed : .done
                let output = Self.text(block["content"])
                if item.status == .failed { if item.kind == .command { item.detail = output } else if !output.isEmpty { item.detail += (item.detail.isEmpty ? "" : "\n") + output } }
                else {
                    switch item.kind {
                    case .command: item.detail = output
                    case .fileChange: if let patch = Self.patch(structured), !patch.isEmpty { item.diff = patch }
                    case .toolCall: item.detail = Self.summary(structured, output: output)
                    default: break
                    }
                }
                items[id] = item; return .item(item)
            }
        case "result":
            guard object["parent_tool_use_id"] as? String == nil else { return [] }
            if let models = object["modelUsage"] as? [String: [String: Any]] {
                for (model, usage) in models {
                    if let size = integer(usage["contextWindow"]), size > 0 { contextWindows[model] = size }
                }
            }
            // Result usage is cumulative across tools and subagents. Only use its capacity.
            let context: [CodexEvent]
            if let model = usageModel, let size = contextWindows[model], let used = lastInputTokens {
                context = [.contextUsage(.init(usedTokens: used, limitTokens: size, model: model))]
            } else { context = [] }
            if object["is_error"] as? Bool == true || (object["subtype"] as? String ?? "success") != "success" {
                let message = object["result"] as? String ?? ""
                return context + [.turnFailed(message.isEmpty ? L10n.tr("这一轮没有完成（\(object["subtype"] as? String ?? "error")）。") : message)]
            }
            let usage = object["usage"] as? [String: Any] ?? [:]
            let input = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
            return context + [.turnCompleted(inputTokens: input, outputTokens: usage["output_tokens"] as? Int ?? 0)]
        default: return []
        }
    }

    /// Text and thinking deltas become a growing, still-running entry.
    private func partial(_ event: [String: Any]) -> [CodexEvent] {
        switch event["type"] as? String {
        case "message_start":
            streamingMessage = (event["message"] as? [String: Any])?["id"] as? String ?? "message"; open.removeAll()
            return contextUsage(event["message"] as? [String: Any] ?? [:])
        case "content_block_start":
            guard let index = event["index"] as? Int, let kind = (event["content_block"] as? [String: Any])?["type"] as? String, kind == "text" || kind == "thinking" else { return [] }
            blocks += 1
            let suffix = kind == "text" ? "t" : "r", id = "\(streamingMessage)-\(suffix)\(blocks)"
            partialIDs[streamingMessage + suffix, default: []].append(id)
            open[index] = CodexItem(id: id, kind: kind == "text" ? .message : .reasoning, text: "", status: .running)
        case "content_block_delta":
            guard let index = event["index"] as? Int, var item = open[index], let delta = event["delta"] as? [String: Any] else { return [] }
            guard let piece = delta["text"] as? String ?? delta["thinking"] as? String, !piece.isEmpty else { return [] }
            item.text += piece; open[index] = item
            return [.item(item)]
        default: break
        }
        return []
    }
    private func contextUsage(_ message: [String: Any]) -> [CodexEvent] {
        guard let usage = message["usage"] as? [String: Any], let input = integer(usage["input_tokens"]) else { return [] }
        let counts = [input, integer(usage["cache_creation_input_tokens"]) ?? 0, integer(usage["cache_read_input_tokens"]) ?? 0]
        var total = 0
        for count in counts { let sum = total.addingReportingOverflow(count); guard !sum.overflow else { return [] }; total = sum.partialValue }
        usageModel = message["model"] as? String ?? usageModel; lastInputTokens = total
        // Match Claude's status line: input + cache reads + cache writes, excluding output.
        return [.contextUsage(.init(usedTokens: total, limitTokens: usageModel.flatMap { contextWindows[$0] }, model: usageModel))]
    }
    /// The id for a finished block: the one its partial version used, when it was streamed.
    private func finalID(_ message: String, _ suffix: String) -> String {
        if var queue = partialIDs[message + suffix], !queue.isEmpty { let id = queue.removeFirst(); partialIDs[message + suffix] = queue; return id }
        blocks += 1; return "\(message)-\(suffix)\(blocks)"
    }

    /// A card for one tool call, in the same vocabulary as Codex's items.
    static func item(id: String, tool: String, input: [String: Any], root: String? = nil) -> CodexItem? {
        func string(_ key: String) -> String { input[key] as? String ?? "" }
        func lines(_ text: String, _ sign: String) -> [String] { text.isEmpty ? [] : text.components(separatedBy: "\n").map { sign + $0 } }
        switch tool {
        case "Bash": return CodexItem(id: id, kind: .command, text: string("command"), status: .running)
        case "Write":
            return CodexItem(id: id, kind: .fileChange, text: L10n.tr("1 个文件"), detail: L10n.tr("写入  \(string("file_path"))"), status: .running, diff: clip(lines(string("content"), "+")))
        case "Edit":
            return CodexItem(id: id, kind: .fileChange, text: L10n.tr("1 个文件"), detail: L10n.tr("修改  \(string("file_path"))"), status: .running, diff: clip(lines(string("old_string"), "-") + lines(string("new_string"), "+")))
        case "MultiEdit":
            let edits = (input["edits"] as? [[String: Any]] ?? []).flatMap { lines($0["old_string"] as? String ?? "", "-") + lines($0["new_string"] as? String ?? "", "+") }
            return CodexItem(id: id, kind: .fileChange, text: L10n.tr("1 个文件"), detail: L10n.tr("修改  \(string("file_path"))"), status: .running, diff: clip(edits))
        case "NotebookEdit": return CodexItem(id: id, kind: .fileChange, text: L10n.tr("1 个文件"), detail: L10n.tr("修改  \(string("notebook_path"))"), status: .running)
        case "TodoWrite":
            let lines = (input["todos"] as? [[String: Any]] ?? []).map { todo -> String in
                let state = todo["status"] as? String
                return (state == "completed" ? "☑ " : state == "in_progress" ? "▸ " : "☐ ") + (todo["content"] as? String ?? "")
            }
            return CodexItem(id: id, kind: .todo, text: L10n.tr("计划"), detail: lines.joined(separator: "\n"), status: .running)
        case "WebSearch": return CodexItem(id: id, kind: .webSearch, text: string("query"), status: .running)
        case "WebFetch": return CodexItem(id: id, kind: .webSearch, text: string("url"), status: .running)
        default:
            // Read, Grep, Glob, Task and MCP tools: the tool name plus its most telling argument.
            var hint = ["file_path", "pattern", "path", "description", "skill", "query"].lazy.map(string).first { !$0.isEmpty } ?? ""
            if let root, hint.hasPrefix(root) { hint = String(hint.dropFirst(root.count)) }
            let short = hint.count > 80 ? String(hint.prefix(80)) + "…" : hint
            return CodexItem(id: id, kind: .toolCall, text: short.isEmpty ? tool : "\(tool) · \(short)", status: .running)
        }
    }
    static func clip(_ lines: [String], limit: Int = 200) -> String {
        (lines.count > limit ? Array(lines.prefix(limit)) + [L10n.tr(" … 还有 \(lines.count - limit) 行")] : lines).joined(separator: "\n")
    }
    /// The edit as Claude Code applied it: hunks with their surrounding context lines.
    static func patch(_ result: [String: Any]?) -> String? {
        guard let hunks = result?["structuredPatch"] as? [[String: Any]], !hunks.isEmpty else { return nil }
        let lines = hunks.enumerated().flatMap { index, hunk -> [String] in
            (index > 0 ? [" ⋯"] : []) + (hunk["lines"] as? [String] ?? [])
        }
        return clip(lines)
    }
    /// One short line about what a read or search returned.
    static func summary(_ result: [String: Any]?, output: String) -> String {
        if let file = result?["file"] as? [String: Any], let count = file["numLines"] as? Int { return L10n.tr("\(count) 行") }
        if let count = result?["numFiles"] as? Int { return L10n.tr("\(count) 个文件") }
        let count = output.isEmpty ? 0 : output.components(separatedBy: "\n").count
        return count == 0 ? "" : L10n.tr("\(count) 行结果")
    }
    /// A tool result is either a string or a list of content blocks.
    static func text(_ content: Any?) -> String {
        if let string = content as? String { return string }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}

/// Runs one Claude Code turn and reports its events as they arrive. Uses whatever account the
/// user's own `claude` CLI is signed in to; BetterTeX never sees or stores those credentials.
public final class ClaudeTurn {
    public let runner = ProcessRunner()
    public init() {}
    public func cancel() { runner.cancel() }
    /// Blocks until the turn ends. Returns the process status and the trailing non-JSON output (for error messages).
    public func run(_ request: ClaudeRequest, executable: String, directory: URL, environment: [String: String], onEvent: @escaping (CodexEvent) -> Void) throws -> (status: Int32, stderr: String) {
        let stream = ClaudeStream(root: directory.standardizedFileURL.path)
        var pending = "", noise: [String] = []
        func consume(_ line: String) {
            if line.hasPrefix("{") { stream.parse(line: line).forEach(onEvent) }
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
