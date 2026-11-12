import Foundation
import Darwin

/// A short-lived, read-only connection to a local agent CLI speaking JSON lines over stdio.
/// The app never reads credentials or starts model turns.
public class AgentQuotaClient: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; let child = process; lock.unlock()
        if let child, child.isRunning { child.terminate() }
    }
    /// Sends `opening`, then hands each reply to `handle` until it returns a snapshot (or `.some(nil)` for "no quota applies").
    func exchange(executable: String, arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval,
                  opening: [[String: Any]], handle: ([String: Any], ([String: Any]) throws -> Void) throws -> AgentQuotaSnapshot??) throws -> AgentQuotaSnapshot? {
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
        child.environment = environment; child.currentDirectoryURL = directory
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw BetterTeXError.message(L10n.tr("操作已取消。")) }
        do { try child.run(); process = child; lock.unlock() } catch { lock.unlock(); throw error }
        let deadline = DispatchWorkItem {
            if child.isRunning { child.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
            // Always bound teardown, including a server that ignores stdin EOF or SIGTERM.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
            child.waitUntilExit(); deadline.cancel(); try? output.fileHandleForReading.close()
            lock.lock(); process = nil; lock.unlock()
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        for message in opening { try send(message) }
        var pending = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            guard pending.count < 2_000_000 else { throw BetterTeXError.message(L10n.tr("无法读取 Agent 额度")) }
            while let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]; pending.removeSubrange(...newline)
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                if let result = try handle(object, send) { return result }
            }
        }
        throw BetterTeXError.message(L10n.tr("无法读取 Agent 额度"))
    }
}

/// `codex app-server`: initialize/initialized, then only `account/rateLimits/read`.
public final class CodexQuotaClient: AgentQuotaClient, @unchecked Sendable {
    public func read(executable: String, environment: [String: String], directory: URL, timeout: TimeInterval = 12) throws -> AgentQuotaSnapshot? {
        var requested = false
        let hello: [String: Any] = ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "bettertex", "title": "BetterTeX", "version": "1.0"], "capabilities": ["explicitGatewayOauth": true]]]
        return try exchange(executable: executable, arguments: ["app-server", "--listen", "stdio://"], environment: environment, directory: directory, timeout: timeout, opening: [hello]) { object, send in
            let id = integer(object["id"])
            if id == 1, !requested {
                guard object["error"] == nil else { throw BetterTeXError.message(L10n.tr("无法读取 Agent 额度")) }
                try send(["method": "initialized"])
                try send(["id": 2, "method": "account/rateLimits/read"]); requested = true
            } else if id == 2 {
                guard object["error"] == nil else { throw BetterTeXError.message(L10n.tr("无法读取 Agent 额度")) }
                return .some(AgentQuotaSnapshot.codex(object))
            }
            return nil
        }
    }
}

/// `claude -p` in stream-json mode answers the `get_usage` control request (the data behind `/usage`)
/// without a prompt, so no model turn starts. Returns nil when plan limits do not apply (API key, Bedrock…).
public final class ClaudeQuotaClient: AgentQuotaClient, @unchecked Sendable {
    public func read(executable: String, environment: [String: String], directory: URL, timeout: TimeInterval = 20) throws -> AgentQuotaSnapshot? {
        let request: [String: Any] = ["type": "control_request", "request_id": "usage", "request": ["subtype": "get_usage", "skip_behaviors": true]]
        return try exchange(executable: executable, arguments: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands"],
                            environment: environment, directory: directory, timeout: timeout, opening: [request]) { object, _ in
            guard object["type"] as? String == "control_response", let response = object["response"] as? [String: Any],
                  response["request_id"] as? String == "usage" else { return nil }
            guard response["subtype"] as? String == "success", let usage = response["response"] as? [String: Any] else {
                throw BetterTeXError.message(L10n.tr("无法读取 Agent 额度"))
            }
            return .some(AgentQuotaSnapshot.claudeUsage(usage))
        }
    }
}

/// Reads only the current thread's bounded log tail. Finding a file never reads other conversations.
public final class CodexSessionUsageReader {
    public struct Snapshot {
        public let context: AgentContextUsage?
        public let quota: AgentQuotaSnapshot?
        public let hasContextUpdate: Bool
    }
    private var file: URL?
    private var key: String?
    public init() {}
    public func read(thread: String, home: URL) -> Snapshot? {
        guard thread.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{7,63}$", options: .regularExpression) != nil else { return nil }
        let newKey = home.path + "/" + thread
        if key != newKey { file = nil; key = newKey }
        if file == nil {
            let root = home.appendingPathComponent("sessions")
            func children(_ url: URL) -> [URL] { ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent } }
            var scanned = 0
            search: for year in children(root) {
                for month in children(year) {
                    for day in children(month) {
                        for candidate in children(day) {
                            scanned += 1; if scanned > 5000 { break search }
                            if candidate.lastPathComponent.hasSuffix("-\(thread).jsonl") { file = candidate; break search }
                        }
                    }
                }
            }
        }
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > 1_048_576 ? size - 1_048_576 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: 1_048_576) else { return nil }
        return Self.parse(data, droppingFirstLine: start > 0)
    }
    public static func parse(_ data: Data, droppingFirstLine: Bool = false) -> Snapshot? {
        var context: AgentContextUsage?, quota: AgentQuotaSnapshot?, hasUpdate = false
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if droppingFirstLine, !lines.isEmpty { lines.removeFirst() }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        for line in lines {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if object["type"] as? String == "compacted" { context = nil; hasUpdate = true; continue }
            guard object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any] else { continue }
            if payload["type"] as? String == "context_compacted" { context = nil; hasUpdate = true }
            guard payload["type"] as? String == "token_count" else { continue }
            if let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any], let used = integer(last["total_tokens"]) {
                context = .init(usedTokens: used, limitTokens: integer(info["model_context_window"])); hasUpdate = true
            }
            if let limits = payload["rate_limits"] as? [String: Any], let timestamp = object["timestamp"] as? String,
               let date = formatter.date(from: timestamp) ?? fallbackFormatter.date(from: timestamp) {
                quota = AgentQuotaSnapshot.codex(limits, observedAt: date)
            }
        }
        return hasUpdate || quota != nil ? Snapshot(context: context, quota: quota, hasContextUpdate: hasUpdate) : nil
    }
}
