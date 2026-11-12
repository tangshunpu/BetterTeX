import Foundation

/// The earlier messages of a resumed conversation, read from the CLI's own log so the chat can
/// show them again. Read-only; works on the same item model as a live turn.
public enum AgentTranscript {
    public enum Entry: Equatable {
        case user(String)
        case item(CodexItem)
    }

    /// Reads a whole session log. Only the most recent `limit` entries are kept.
    public static func load(_ session: AgentSession, project: URL? = nil, limit: Int = 400) -> (entries: [Entry], omitted: Int) {
        guard let file = session.file, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return ([], 0) }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        let entries: [Entry]
        switch session.provider {
        case .claude: entries = claude(lines, root: project?.standardizedFileURL.path)
        case .codex: entries = codex(lines)
        }
        let omitted = max(0, entries.count - limit)
        return (Array(entries.suffix(limit)), omitted)
    }

    // MARK: Claude
    /// Claude Code logs the same messages its stream prints, so the stream parser replays them.
    static func claude<S: Sequence>(_ lines: S, root: String?) -> [Entry] where S.Element: StringProtocol {
        let stream = ClaudeStream(root: root)
        var log = Log()
        for line in lines {
            // Most lines are bookkeeping (request blobs, snapshots); skip them before decoding.
            guard line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\""),
                  var object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant",
                  object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true else { continue }
            if type == "user", let message = object["message"] as? [String: Any] {
                if let text = message["content"] as? String { if let prompt = prompt(text) { log.user(prompt) }; continue }
                if let blocks = message["content"] as? [[String: Any]], !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                    if let prompt = prompt(blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")) { log.user(prompt) }
                    continue
                }
                // The log spells the structured tool result differently from the stream.
                if let result = object["toolUseResult"] { object["tool_use_result"] = result }
            }
            guard let json = try? JSONSerialization.data(withJSONObject: object), let text = String(data: json, encoding: .utf8) else { continue }
            for event in stream.parse(line: text) { if case .item(let item) = event { log.item(item) } }
        }
        return log.entries
    }

    // MARK: Codex
    /// Newer Codex logs record each finished item; older ones only the raw model messages.
    static func codex<S: Sequence>(_ lines: S) -> [Entry] where S.Element: StringProtocol {
        var log = Log(), fallback = Log(), structured = false
        for line in lines {
            let completed = line.contains("\"item_completed\"")
            guard completed || line.contains("\"response_item\""),
                  let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            if completed, payload["type"] as? String == "item_completed", let raw = payload["item"] as? [String: Any] {
                structured = true
                if raw["type"] as? String == "UserMessage" {
                    if let prompt = prompt(texts(raw["content"])) { log.user(prompt) }
                } else if let item = codexItem(raw) { log.item(item) }
            } else if object["type"] as? String == "response_item", payload["type"] as? String == "message" {
                let text = texts(payload["content"])
                switch payload["role"] as? String {
                case "user": if let prompt = prompt(text) { fallback.user(prompt) }
                case "assistant": if !text.isEmpty { fallback.item(CodexItem(id: "m\(fallback.entries.count)", kind: .message, text: text)) }
                default: break
                }
            }
        }
        return structured ? log.entries : fallback.entries
    }
    static func codexItem(_ raw: [String: Any]) -> CodexItem? {
        guard let id = raw["id"] as? String, let type = raw["type"] as? String else { return nil }
        let failed = ["failed", "declined"].contains(raw["status"] as? String ?? "")
        switch type {
        case "AgentMessage":
            let text = texts(raw["content"]); return text.isEmpty ? nil : CodexItem(id: id, kind: .message, text: text)
        case "Reasoning":
            let text = ((raw["summary_text"] as? [Any]) ?? []).compactMap { $0 as? String }.joined(separator: "\n")
            return text.isEmpty ? nil : CodexItem(id: id, kind: .reasoning, text: text)
        case "CommandExecution":
            var command = raw["command"] as? String ?? ""
            if let parts = raw["command"] as? [String] {
                command = parts.count == 3 && ["-lc", "-c"].contains(parts[1]) ? parts[2] : parts.joined(separator: " ")
            }
            let code = raw["exit_code"] as? Int
            return CodexItem(id: id, kind: .command, text: command, detail: raw["aggregated_output"] as? String ?? "",
                             status: failed || (code ?? 0) != 0 ? .failed : .done, exitCode: code)
        case "FileChange":
            let changes = (raw["changes"] as? [String: [String: Any]] ?? [:]).sorted { $0.key < $1.key }
            let detail = changes.map { path, change -> String in
                let kind = ["add": L10n.tr("新增"), "delete": L10n.tr("删除"), "update": L10n.tr("修改")][change["type"] as? String ?? ""] ?? L10n.tr("修改")
                return "\(kind)  \(path)"
            }.joined(separator: "\n")
            let diff = changes.compactMap { $0.value["unified_diff"] as? String }.joined(separator: "\n")
                .components(separatedBy: "\n").filter { !$0.hasPrefix("@@") && !$0.hasPrefix("+++") && !$0.hasPrefix("---") }
            return CodexItem(id: id, kind: .fileChange, text: L10n.tr("\(changes.count) 个文件"), detail: detail, status: failed ? .failed : .done,
                             diff: ClaudeStream.clip(Array(diff.reversed().drop { $0.isEmpty }.reversed())))
        case "McpToolCall":
            let isError = (raw["result"] as? [String: Any])?["isError"] as? Bool == true
            return CodexItem(id: id, kind: .toolCall, text: [raw["server"] as? String, raw["tool"] as? String].compactMap { $0 }.joined(separator: " · "), status: failed || isError ? .failed : .done)
        case "WebSearch":
            return CodexItem(id: id, kind: .webSearch, text: raw["query"] as? String ?? "")
        case "Extension":
            guard (raw["kind"] as? String)?.hasPrefix("web.") == true else { return nil }
            return CodexItem(id: id, kind: .webSearch, text: raw["query"] as? String ?? "")
        case "ImageView":
            let path = (raw["path"] as? String).flatMap { URL(string: $0)?.path } ?? ""
            return CodexItem(id: id, kind: .toolCall, text: path.isEmpty ? "View" : "View · \((path as NSString).lastPathComponent)")
        default: return nil
        }
    }

    // MARK: Helpers
    /// Keeps entries in first-seen order; a later copy of an item replaces the earlier one.
    struct Log {
        private(set) var entries: [Entry] = []
        private var index: [String: Int] = [:]
        mutating func user(_ text: String) { entries.append(.user(text)) }
        mutating func item(_ item: CodexItem) {
            if let position = index[item.id] { entries[position] = .item(item) }
            else { index[item.id] = entries.count; entries.append(.item(item)) }
        }
    }
    static func texts(_ content: Any?) -> String {
        if let text = content as? String { return text }
        return ((content as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    /// A prompt as the user saw it: injected blocks (environment, commands) are dropped and an
    /// attached excerpt collapses to its "@file:lines" reference.
    static func prompt(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return trimmed.replacingOccurrences(of: "^(@\\S+)\\n(`{3,})tex\\n[\\s\\S]*?\\n\\2(?=\\n|$)", with: "$1", options: .regularExpression)
    }
}
