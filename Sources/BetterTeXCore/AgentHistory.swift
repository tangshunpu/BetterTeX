import Foundation

/// A past CLI conversation that can be resumed.
public struct AgentSession: Equatable {
    public let provider: AgentProvider
    public let id: String
    public let title: String
    public let date: Date
    public init(provider: AgentProvider, id: String, title: String, date: Date) { self.provider = provider; self.id = id; self.title = title; self.date = date }
}

/// Reads the session logs the Codex and Claude CLIs keep on disk, read-only, to list the
/// conversations that belong to a project. Only the head of each log is read.
public enum AgentHistory {
    static let headBytes = 256 * 1024

    /// Claude Code stores a project's sessions under a folder named after its path with
    /// every non-alphanumeric character replaced by a hyphen.
    public static func claudeProjectFolder(for project: URL) -> String {
        String(project.standardizedFileURL.path.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)) ? Character(scalar) : "-"
        })
    }

    /// Arguments that reopen a session; the id is validated because it reaches the command line.
    public static func resumeArguments(for session: AgentSession) throws -> [String] {
        guard session.id.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{7,63}$", options: .regularExpression) != nil else { throw BetterTeXError.message(L10n.tr("会话 ID 无效，无法恢复。")) }
        switch session.provider {
        case .codex: return ["resume", session.id]
        case .claude: return ["--resume", session.id]
        }
    }

    public static func sessions(for provider: AgentProvider, project: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                codexHome: String? = nil, limit: Int = 12) -> [AgentSession] {
        switch provider {
        case .claude: return claudeSessions(project: project, home: home, limit: limit)
        case .codex: return codexSessions(project: project, root: URL(fileURLWithPath: codexHome ?? home.appendingPathComponent(".codex").path), limit: limit)
        }
    }

    // MARK: Claude
    static func claudeSessions(project: URL, home: URL, limit: Int) -> [AgentSession] {
        let folder = home.appendingPathComponent(".claude/projects").appendingPathComponent(claudeProjectFolder(for: project))
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        var result: [AgentSession] = []
        for (file, date) in files {
            guard result.count < limit else { break }
            guard let title = claudeTitle(head(of: file)) else { continue }
            result.append(AgentSession(provider: .claude, id: file.deletingPathExtension().lastPathComponent, title: title, date: date))
        }
        return result
    }
    /// The first prompt the user typed; tool results, commands and sidechain logs are skipped.
    static func claudeTitle(_ head: String) -> String? {
        for object in objects(in: head) {
            guard object["type"] as? String == "user", object["isMeta"] as? Bool != true, object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any] else { continue }
            var text: String?
            if let content = message["content"] as? String { text = content }
            else if let parts = message["content"] as? [[String: Any]] { text = parts.first { $0["type"] as? String == "text" }?["text"] as? String }
            if let title = text.flatMap(clean) { return title }
        }
        return nil
    }

    // MARK: Codex
    static func codexSessions(project: URL, root: URL, limit: Int) -> [AgentSession] {
        let sessions = root.appendingPathComponent("sessions")
        let manager = FileManager.default
        func children(_ url: URL) -> [URL] {
            ((try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        let target = project.standardizedFileURL.path
        var result: [AgentSession] = []; var scanned = 0
        // Logs are filed as sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl; walk newest first.
        scan: for year in children(sessions) {
            for month in children(year) {
                for day in children(month) {
                    for file in children(day) where file.pathExtension == "jsonl" {
                        scanned += 1; if scanned > 1500 || result.count >= limit { break scan }
                        guard let entry = codexEntry(head(of: file)), URL(fileURLWithPath: entry.cwd).standardizedFileURL.path == target else { continue }
                        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        result.append(AgentSession(provider: .codex, id: entry.id, title: entry.title, date: date))
                    }
                }
            }
        }
        return result.sorted { $0.date > $1.date }
    }
    /// Session id and working directory from the meta record, plus the first real user prompt.
    static func codexEntry(_ head: String) -> (id: String, cwd: String, title: String)? {
        var id: String?, cwd: String?, title: String?
        for object in objects(in: head) {
            guard let payload = object["payload"] as? [String: Any] else { continue }
            if object["type"] as? String == "session_meta" { id = payload["id"] as? String; cwd = payload["cwd"] as? String }
            else if title == nil, payload["type"] as? String == "message", payload["role"] as? String == "user", let parts = payload["content"] as? [[String: Any]] {
                title = parts.compactMap { $0["text"] as? String }.compactMap(clean).first
            }
            if id != nil, title != nil { break }
        }
        guard let id, let cwd else { return nil }
        return (id, cwd, title ?? L10n.tr("未命名会话"))
    }

    // MARK: Helpers
    static func head(of file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: headBytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
    /// Parses complete JSON lines; a final line cut off by the head limit is ignored.
    static func objects(in head: String) -> [[String: Any]] {
        head.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }
    /// Turns a prompt into a one-line title, dropping injected context blocks and file mentions.
    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        var body = trimmed.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        body = body.replacingOccurrences(of: "(^|\\s)@\\S+", with: " ", options: .regularExpression)
        let line = body.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let title = line.isEmpty ? trimmed.components(separatedBy: .newlines)[0] : line
        return title.count > 60 ? String(title.prefix(60)) + "…" : title
    }
}
