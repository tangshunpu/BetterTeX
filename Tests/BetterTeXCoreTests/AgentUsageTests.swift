import XCTest
@testable import BetterTeXCore

final class AgentUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func object(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }
    func testQuotaUsesTightestWindowAndDoesNotInventResetRecovery() throws {
        let quota = try XCTUnwrap(AgentQuotaSnapshot.codex(object(#"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800000100},"secondary":{"usedPercent":80,"windowDurationMins":10080,"resetsAt":1800005000},"planType":"pro"}}"#), observedAt: now))
        XCTAssertEqual(quota.remainingPercent(at: now), 20)
        XCTAssertEqual(quota.windows.map(\.durationMinutes), [300, 10080])
        XCTAssertEqual(quota.plan, "pro")
        XCTAssertNil(quota.remainingPercent(at: now.addingTimeInterval(101)))
        XCTAssertNil(quota.remainingPercent(at: now.addingTimeInterval(301)))
        XCTAssertNil(AgentQuotaSnapshot.codex([:]))
        XCTAssertNil(AgentQuotaSnapshot.codex(["primary": ["usedPercent": true]]))
        let unused = AgentQuotaSnapshot(windows: [.init(id: "primary", usedPercent: 0)], observedAt: now)
        XCTAssertEqual(unused.remainingPercent(at: now), 100)
        XCTAssertNil(AgentQuotaSnapshot(windows: [.init(id: "primary", usedPercent: nil)], observedAt: now).remainingPercent(at: now))
    }
    func testMultiBucketQuotaUsesCodexAndHonorsRejectedState() throws {
        let payload = try object(#"{"rateLimits":{"primary":{"usedPercent":2}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":40},"rateLimitReachedType":"workspace_member_usage_limit_reached"},"other":{"primary":{"usedPercent":99}}}}"#)
        let quota = try XCTUnwrap(AgentQuotaSnapshot.codex(payload, observedAt: now))
        XCTAssertEqual(quota.windows.first?.usedPercent, 40)
        XCTAssertEqual(quota.status, "rejected"); XCTAssertNil(quota.remainingPercent(at: now))
    }
    func testCodexLogUsesLatestRequestAndClearsAfterCompaction() throws {
        let line = #"{"timestamp":"2027-01-15T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":9000000},"last_token_usage":{"total_tokens":12000},"model_context_window":100000},"rate_limits":{"primary":{"used_percent":30,"window_minutes":300,"resets_at":1800000100}}}}"#
        let last = line.replacingOccurrences(of: "12000", with: "24000")
        let snapshot = try XCTUnwrap(CodexSessionUsageReader.parse(Data((line + "\n" + last + "\n{partial").utf8)))
        XCTAssertEqual(snapshot.context?.usedTokens, 24000)
        XCTAssertEqual(snapshot.context?.fraction, 0.24)
        XCTAssertEqual(snapshot.quota?.windows.first?.usedPercent, 30)
        let compact = #"{"type":"event_msg","payload":{"type":"context_compacted"}}"#
        let cleared = try XCTUnwrap(CodexSessionUsageReader.parse(Data((line + "\n" + compact).utf8)))
        XCTAssertTrue(cleared.hasContextUpdate); XCTAssertNil(cleared.context)
        let rolloutCompaction = try XCTUnwrap(CodexSessionUsageReader.parse(Data((line + "\n" + #"{"type":"compacted","payload":{}}"#).utf8)))
        XCTAssertTrue(rolloutCompaction.hasContextUpdate); XCTAssertNil(rolloutCompaction.context)
        XCTAssertNil(CodexSessionUsageReader.parse(Data(line.utf8), droppingFirstLine: true))
    }
    func testReaderFindsOnlyRequestedThreadAndRejectsInvalidIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = directory.appendingPathComponent("sessions/2026/11/12")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let sample = #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":12},"model_context_window":100}}}"#
        try sample.write(to: day.appendingPathComponent("rollout-date-abcdefgh-1.jsonl"), atomically: true, encoding: .utf8)
        try sample.replacingOccurrences(of: ":12", with: ":99").write(to: day.appendingPathComponent("rollout-date-abcdefgh-2.jsonl"), atomically: true, encoding: .utf8)
        let reader = CodexSessionUsageReader()
        XCTAssertEqual(reader.read(thread: "abcdefgh-1", home: directory)?.context?.usedTokens, 12)
        XCTAssertEqual(reader.read(thread: "abcdefgh-2", home: directory)?.context?.usedTokens, 99)
        XCTAssertNil(reader.read(thread: "../abcdefgh-1", home: directory))
        XCTAssertNil(reader.read(thread: "abcdefgh-3", home: directory))
    }
    func testClaudeContextIncludesCachesButNotCumulativeOrSubagentUsage() throws {
        let stream = ClaudeStream()
        _ = stream.parse(line: #"{"type":"system","subtype":"init","session_id":"abcdefgh-1","model":"model-a"}"#)
        let first = stream.parse(line: #"{"type":"stream_event","event":{"type":"message_start","message":{"model":"model-a","usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":70,"output_tokens":9}}}}"#)
        XCTAssertEqual(first, [.contextUsage(.init(usedTokens: 100, limitTokens: nil, model: "model-a"))])
        XCTAssertEqual(stream.parse(line: #"{"type":"assistant","parent_tool_use_id":"child","message":{"model":"model-b","usage":{"input_tokens":90000}}}"#), [])
        _ = stream.parse(line: #"{"type":"assistant","message":{"model":"model-a","usage":{"input_tokens":5,"cache_read_input_tokens":45}}}"#)
        let result = stream.parse(line: #"{"type":"result","usage":{"input_tokens":5000,"output_tokens":3000},"modelUsage":{"model-a":{"inputTokens":5000,"contextWindow":200},"model-b":{"contextWindow":1000000}}}"#)
        XCTAssertEqual(result.first, .contextUsage(.init(usedTokens: 50, limitTokens: 200, model: "model-a")))
        XCTAssertEqual(result.last, .turnCompleted(inputTokens: 5000, outputTokens: 3000))
        XCTAssertEqual(stream.parse(line: #"{"type":"system","subtype":"compact_boundary"}"#), [.contextUsage(nil)])
        let after = stream.parse(line: #"{"type":"result","usage":{"input_tokens":5000},"modelUsage":{"model-a":{"contextWindow":200}}}"#)
        XCTAssertEqual(after, [.turnCompleted(inputTokens: 5000, outputTokens: 0)])
    }
    func testClaudeRateLimitEventHandlesFractionAndUnknownUtilization() throws {
        let stream = ClaudeStream()
        guard case .rateLimits(let quota)? = stream.parse(line: #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","rateLimitType":"five_hour","utilization":0.85,"resetsAt":1900000000}}"#).first else { return XCTFail() }
        XCTAssertEqual(quota.windows.first?.usedPercent, 85)
        XCTAssertEqual(quota.remainingPercent(at: quota.observedAt), 15)
        let unknown = try XCTUnwrap(AgentQuotaSnapshot.claude(["status": "allowed"], observedAt: now))
        XCTAssertNil(unknown.remainingPercent(at: now))
        let rejected = try XCTUnwrap(AgentQuotaSnapshot.claude(["status": "rejected", "errorCode": "credits_required"], observedAt: now))
        XCTAssertEqual(rejected.status, "credits_required"); XCTAssertNil(rejected.remainingPercent(at: now))
    }
    func testContextMergingKeepsCapacityOnlyForSameModelAndClampsRing() {
        let old = AgentContextUsage(usedTokens: 100, limitTokens: 200, model: "a")
        XCTAssertEqual(AgentContextUsage(usedTokens: 50, limitTokens: nil, model: "a").merging(old).fraction, 0.25)
        XCTAssertNil(AgentContextUsage(usedTokens: 50, limitTokens: nil, model: "b").merging(old).fraction)
        XCTAssertEqual(AgentContextUsage(usedTokens: 300, limitTokens: 200).fraction, 1)
        XCTAssertNil(AgentContextUsage(usedTokens: -1, limitTokens: 0).fraction)
    }
    func testQuotaClientHandshakeAndReadOnlyRequest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("server")
        try """
        #!/bin/sh
        IFS= read -r init
        printf '%s\\n' "$init" > requests
        printf '{"id":1,"result":{}}\\n'
        IFS= read -r ready
        IFS= read -r request
        printf '%s\\n%s\\n' "$ready" "$request" >> requests
        printf '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":35,"windowDurationMins":300}}}}\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let result = try XCTUnwrap(CodexQuotaClient().read(executable: script.path, environment: [:], directory: directory, timeout: 2))
        XCTAssertEqual(result.remainingPercent(at: result.observedAt), 65)
        let requests = try String(contentsOf: directory.appendingPathComponent("requests")).split(separator: "\n").map { try object(String($0)) }
        XCTAssertEqual(requests.compactMap { $0["method"] as? String }, ["initialize", "initialized", "account/rateLimits/read"])
    }
    func testQuotaClientFailureTimeoutAndCancellation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("server")
        try "#!/bin/sh\nIFS= read -r init\nprintf '{\"id\":1,\"error\":{\"message\":\"unsupported\"}}\\n'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        XCTAssertThrowsError(try CodexQuotaClient().read(executable: script.path, environment: [:], directory: directory, timeout: 1))
        try "#!/bin/sh\nexec /bin/sleep 20\n".write(to: script, atomically: true, encoding: .utf8)
        let start = Date()
        XCTAssertThrowsError(try CodexQuotaClient().read(executable: script.path, environment: [:], directory: directory, timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let cancelled = CodexQuotaClient(); cancelled.cancel()
        XCTAssertThrowsError(try cancelled.read(executable: script.path, environment: [:], directory: directory))
    }
    func testLiveCodexQuotaReadWithoutModelTurn() throws {
        guard ProcessInfo.processInfo.environment["BETTERTEX_CODEX_USAGE_LIVE"] == "1" else { throw XCTSkip("Set BETTERTEX_CODEX_USAGE_LIVE=1 to check the installed CLI's read-only quota endpoint.") }
        let tools = Toolchain.discover(), directory = URL(fileURLWithPath: NSTemporaryDirectory())
        let executable = try XCTUnwrap(tools["codex"])
        let quota = try XCTUnwrap(CodexQuotaClient().read(executable: executable, environment: tools.environment, directory: directory))
        XCTAssertFalse(quota.windows.isEmpty)
    }
    func testClaudeUsageResponseBecomesWindowsWithoutModelTurn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("claude")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" > arguments
        IFS= read -r request
        printf '%s\\n' "$request" > requests
        printf '{"type":"system","subtype":"status"}\\n'
        printf '{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":2,"resets_at":"2099-11-12T09:40:00.437263+00:00"},"seven_day":{"utilization":22,"resets_at":"2099-11-17T12:00:00+00:00"},"seven_day_opus":null,"model_scoped":[{"display_name":"Fable","utilization":41,"resets_at":null}]}}}}\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let quota = try XCTUnwrap(ClaudeQuotaClient().read(executable: script.path, environment: [:], directory: directory, timeout: 2))
        XCTAssertEqual(quota.windows.map(\.usedPercent), [2, 22, 41])
        XCTAssertEqual(quota.windows.map(\.durationMinutes), [300, 10080, 10080])
        XCTAssertEqual(quota.windows.last?.scope, "Fable"); XCTAssertTrue(quota.windows.last?.title.hasSuffix("· Fable") == true)
        XCTAssertEqual(quota.windows.first?.resetsAt, ISO8601DateFormatter().date(from: "2099-11-12T09:40:00+00:00"))
        XCTAssertEqual(quota.remainingPercent(at: quota.observedAt), 59); XCTAssertEqual(quota.plan, "max")
        let request = try object(String(contentsOf: directory.appendingPathComponent("requests")))
        XCTAssertEqual((request["request"] as? [String: Any])?["subtype"] as? String, "get_usage")
        // A prompt argument would start a model turn.
        XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("arguments")).contains("--  "))
        XCTAssertNil(AgentQuotaSnapshot.claudeUsage(["rate_limits_available": false, "rate_limits": NSNull()]))
        XCTAssertNil(AgentQuotaSnapshot.claudeUsage(["rate_limits_available": true, "rate_limits": ["five_hour": ["utilization": NSNull()]]]))
        try "#!/bin/sh\nIFS= read -r request\nprintf '{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\",\"request_id\":\"usage\",\"error\":\"unsupported\"}}\\n'\n".write(to: script, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClaudeQuotaClient().read(executable: script.path, environment: [:], directory: directory, timeout: 2))
    }
    func testLiveClaudeQuotaReadWithoutModelTurn() throws {
        guard ProcessInfo.processInfo.environment["BETTERTEX_CLAUDE_USAGE_LIVE"] == "1" else { throw XCTSkip("Set BETTERTEX_CLAUDE_USAGE_LIVE=1 to check the installed CLI's read-only usage request.") }
        let tools = Toolchain.discover(), directory = URL(fileURLWithPath: NSTemporaryDirectory())
        let executable = try XCTUnwrap(tools["claude"])
        let quota = try XCTUnwrap(ClaudeQuotaClient().read(executable: executable, environment: tools.environment, directory: directory))
        XCTAssertFalse(quota.windows.isEmpty)
    }
}
