import XCTest
@testable import BetterTeXCore

final class AgentTranscriptTests: XCTestCase {
    private func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testClaudeLogReplaysPromptsRepliesAndToolsButSkipsSidechainsAndMeta() throws {
        let file = try write([
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"@draft.tex:3-4\n```tex\n\\section{A}\n```\n\nTighten this"}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"[Image: original]"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Reading it."}]}}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"id":"m9","content":[{"type":"text","text":"sub-agent chatter"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"main.tex"}]}}"#,
            #"{"type":"file-history-snapshot","snapshot":{}}"#
        ])
        let result = AgentTranscript.load(AgentSession(provider: .claude, id: "abcdefgh-1", title: "", date: Date(), file: file))
        XCTAssertEqual(result.omitted, 0)
        XCTAssertEqual(result.entries.count, 3)
        XCTAssertEqual(result.entries.first, .user("@draft.tex:3-4\n\nTighten this"))
        guard case .item(let reply) = result.entries[1], case .item(let command) = result.entries[2] else { return XCTFail("expected items") }
        XCTAssertEqual(reply.kind, .message); XCTAssertEqual(reply.text, "Reading it.")
        XCTAssertEqual(command.kind, .command); XCTAssertEqual(command.status, .done); XCTAssertEqual(command.detail, "main.tex")
    }

    func testCodexLogUsesCompletedItemsAndFallsBackToMessages() throws {
        let structured = try write([
            #"{"type":"session_meta","payload":{"id":"abcdefgh-2","cwd":"/p"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"system"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"Fix Fig. 2"}]}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","id":"r1","summary_text":[],"raw_content":[]}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"c1","command":["/bin/zsh","-lc","grep -n jscc main.tex"],"aggregated_output":"","exit_code":1,"status":"completed"}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"f1","changes":{"/p/main.tex":{"type":"update","unified_diff":"@@ -1 +1 @@\n-JSCC encoder\n+L-JSCC encoder\n"}}}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"a1","content":[{"type":"Text","text":"Renamed."}],"phase":"final"}}}"#
        ])
        let entries = AgentTranscript.load(AgentSession(provider: .codex, id: "abcdefgh-2", title: "", date: Date(), file: structured)).entries
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries.first, .user("Fix Fig. 2"))
        guard case .item(let command) = entries[1], case .item(let change) = entries[2], case .item(let reply) = entries[3] else { return XCTFail("expected items") }
        XCTAssertEqual(command.text, "grep -n jscc main.tex"); XCTAssertEqual(command.status, .failed); XCTAssertEqual(command.exitCode, 1)
        XCTAssertEqual(change.kind, .fileChange); XCTAssertEqual(change.diff, "-JSCC encoder\n+L-JSCC encoder"); XCTAssertTrue(change.detail.hasSuffix("/p/main.tex"))
        XCTAssertEqual(reply.text, "Renamed.")

        let legacy = try write([
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Hello"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hi"}]}}"#
        ])
        let old = AgentTranscript.load(AgentSession(provider: .codex, id: "abcdefgh-3", title: "", date: Date(), file: legacy)).entries
        XCTAssertEqual(old.count, 2); XCTAssertEqual(old.first, .user("Hello"))
    }

    func testOnlyTheMostRecentEntriesAreKept() throws {
        let lines = (0..<10).map { #"{"type":"user","message":{"role":"user","content":"prompt \#($0)"}}"# }
        let result = AgentTranscript.load(AgentSession(provider: .claude, id: "abcdefgh-4", title: "", date: Date(), file: try write(lines)), limit: 4)
        XCTAssertEqual(result.omitted, 6); XCTAssertEqual(result.entries.first, .user("prompt 6"))
    }
}

final class AgentLocationTests: XCTestCase {
    func testLinksResolveToSourceLinesAndPDFPages() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("loc-\(UUID().uuidString)/My Paper")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("sections"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        let intro = project.appendingPathComponent("sections/intro.tex"); try "x".write(to: intro, atomically: true, encoding: .utf8)
        let resolved = intro.standardizedFileURL
        XCTAssertEqual(AgentLocation.parse("sections/intro.tex:42", project: project), .source(resolved, line: 42))
        XCTAssertEqual(AgentLocation.parse("sections/intro.tex:10-14", project: project), .source(resolved, line: 10))
        XCTAssertEqual(AgentLocation.parse(intro.path + "#L7", project: nil), .source(resolved, line: 7))
        XCTAssertEqual(AgentLocation.parse(intro.absoluteString + ":3", project: nil), .source(resolved, line: 3))
        XCTAssertEqual(AgentLocation.parse("sections/intro.tex", project: project), .source(resolved, line: nil))
        XCTAssertEqual(AgentLocation.parse("pdf:3", project: project), .pdfPage(3))
        XCTAssertNil(AgentLocation.parse("missing.tex:2", project: project))
        XCTAssertNil(AgentLocation.parse("https://example.com/a.tex", project: project))
        XCTAssertNil(AgentLocation.parse("sections", project: project))
        let text = "Changed sections/intro.tex:42 and refs.bib, not v1.2 or e.g.tex2"
        XCTAssertEqual(AgentLocation.mentions(in: text).map { (text as NSString).substring(with: $0) }, ["sections/intro.tex:42", "refs.bib"])
    }
    func testInstructionsTravelAsSystemLevelArguments() throws {
        let claude = try ClaudeRequest(prompt: "hi", instructions: "Say \"x\"\nthen y").arguments()
        XCTAssertEqual(Array(claude[7...8]), ["--append-system-prompt", "Say \"x\"\nthen y"])
        let codex = try CodexRequest(prompt: "hi", instructions: "Say \"x\"\\ok\nthen y").arguments()
        XCTAssertTrue(codex.contains(#"developer_instructions="Say \"x\"\\ok\nthen y""#))
        XCTAssertEqual(codex.last, "hi")
    }
}
