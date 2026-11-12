import AppKit
import XCTest
import BetterTeXCore
@testable import BetterTeX

final class AgentUsageViewTests: XCTestCase {
    @MainActor func testResumedCodexContextLoadsAndResetDiscardsPendingReads() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = root.appendingPathComponent("sessions/2026/11/12")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":12345},"model_context_window":100000}}}"#.write(to: day.appendingPathComponent("rollout-date-abcdefgh-1.jsonl"), atomically: true, encoding: .utf8)
        let chat = AgentChatView()
        chat.configureUsage(environment: ["CODEX_HOME": root.path]); chat.resume(thread: "abcdefgh-1", title: "Fixture")
        chat.refreshContextUsage(force: true)
        for _ in 0..<100 { if chat.contextUsage != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(chat.contextUsage?.usedTokens, 12345)
        chat.refreshContextUsage(force: true); chat.reset()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(chat.contextUsage); XCTAssertNil(chat.thread)
    }

    @MainActor func testClaudeStreamUpdatesComposerAndSwitchingProviderKeepsScopesSeparate() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("agent")
        try #"""
        #!/bin/sh
        /bin/cat <<'JSON'
        {"type":"system","subtype":"init","session_id":"abcdefgh-1","model":"fixture-model"}
        {"type":"assistant","message":{"model":"fixture-model","usage":{"input_tokens":2000,"cache_read_input_tokens":6000},"content":[{"type":"text","text":"Done"}]}}
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","utilization":0.3}}
        {"type":"result","usage":{"input_tokens":50000},"modelUsage":{"fixture-model":{"contextWindow":100000}}}
        JSON
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let panel = TerminalPanel(frame: .zero); defer { panel.stopAll() }
        panel.select("Claude")
        XCTAssertTrue(panel.claudeChat.send(prompt: "fixture", display: "fixture", executable: executable.path, directory: root, environment: [:], configuration: .init(), sandbox: .readOnly))
        for _ in 0..<100 { if !panel.claudeChat.running { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(panel.claudeChat.running)
        XCTAssertEqual(panel.usageView.ring.usage?.fraction, 0.08)
        XCTAssertEqual(panel.usageView.quotaButton.title, L10n.tr("额度剩余 \(70)%"))
        panel.select("Codex"); XCTAssertNil(panel.usageView.ring.usage)
        panel.select("Claude"); XCTAssertEqual(panel.usageView.ring.usage?.fraction, 0.08)
        panel.claudeChat.reset(); XCTAssertNil(panel.usageView.ring.usage)
    }

    @MainActor func testUnknownUsageIsNotZeroAndProviderSwitchClearsRing() async throws {
        _ = NSApplication.shared
        let view = AgentUsageView(frame: .zero)
        XCTAssertEqual(view.quotaButton.title, L10n.tr("额度 —"))
        XCTAssertEqual(view.ring.accessibilityLabel(), L10n.tr("上下文用量尚未获取"))
        let now = Date()
        let quota = AgentQuotaSnapshot(windows: [.init(id: "primary", usedPercent: 25, durationMinutes: 300)], observedAt: now)
        view.update(provider: .codex, context: .init(usedTokens: 12000, limitTokens: 100000), quota: quota, now: now)
        XCTAssertEqual(view.quotaButton.title, L10n.tr("额度剩余 \(75)%"))
        XCTAssertEqual(view.ring.accessibilityLabel(), L10n.tr("上下文已用 \(12)%"))
        let details = view.detailsMenu(now: now).items.map(\.title).joined(separator: "\n")
        XCTAssertTrue(details.contains("12,000")); XCTAssertTrue(details.contains("100,000"))
        view.update(provider: .claude, context: nil, quota: nil)
        XCTAssertNil(view.ring.usage)
        XCTAssertEqual(view.quotaButton.title, L10n.tr("额度 —"))
        XCTAssertEqual(view.detailsMenu().items.last?.title, L10n.tr("刷新用量"))
        let plan = AgentQuotaSnapshot(windows: [.init(id: "five_hour", usedPercent: 2, durationMinutes: 300), .init(id: "seven_day_fable", usedPercent: 41, durationMinutes: 10080, scope: "Fable")], observedAt: now)
        view.update(provider: .claude, context: nil, quota: plan, now: now)
        XCTAssertEqual(view.quotaButton.title, L10n.tr("额度剩余 \(59)%"))
        XCTAssertTrue(view.detailsMenu(now: now).items.contains { $0.title.contains("Fable") })
    }
    @MainActor func testExpiredQuotaShowsRefreshInsteadOfFullAvailability() async throws {
        _ = NSApplication.shared
        let view = AgentUsageView(frame: .zero), now = Date()
        let quota = AgentQuotaSnapshot(windows: [.init(id: "primary", usedPercent: 100, resetsAt: now.addingTimeInterval(-1))], observedAt: now, status: "rejected")
        view.update(provider: .codex, context: nil, quota: quota, now: now)
        XCTAssertEqual(view.quotaButton.title, L10n.tr("额度待刷新"))
        var refreshed = false; view.onRefresh = { refreshed = true }
        let item = try XCTUnwrap(view.detailsMenu().items.last)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertTrue(refreshed)
    }
    @MainActor func testUsageStripSitsAboveComposerAndRendersRing() async throws {
        _ = NSApplication.shared
        let panel = TerminalPanel(frame: NSRect(x: 0, y: 0, width: 380, height: 680))
        let window = NSWindow(contentRect: panel.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = panel
        defer { panel.stopAll(); window.close() }
        panel.contextFile = "a-very-long-section-filename-that-should-truncate.tex"
        panel.usageView.update(provider: .codex, context: .init(usedTokens: 82000, limitTokens: 100000), quota: .init(windows: [.init(id: "primary", usedPercent: 30)]))
        panel.layoutSubtreeIfNeeded()
        let ring = panel.usageView.ring.convert(panel.usageView.ring.bounds, to: panel)
        XCTAssertGreaterThan(ring.minX, 0); XCTAssertLessThanOrEqual(ring.maxX, panel.bounds.maxX)
        // The strip is its own line above the composer card, inside the panel on both sides.
        let quota = panel.usageView.quotaButton.convert(panel.usageView.quotaButton.bounds, to: panel)
        let hint = panel.hint.convert(panel.hint.bounds, to: panel)
        XCTAssertGreaterThan(quota.minX, 12); XCTAssertLessThan(quota.maxX, ring.minX)
        XCTAssertEqual(quota.midY, ring.midY, accuracy: 1)
        XCTAssertFalse(panel.usageView.isHidden)
        XCTAssertEqual(panel.usageView.frame.height, 18, accuracy: 0.1)
        // At least the composer card's minimum height separates the strip from the hint below.
        XCTAssertGreaterThan(panel.isFlipped ? hint.minY - ring.maxY : ring.minY - hint.maxY, 60)
        // Include the composer so placement, truncation and both indicators can be inspected together.
        if let path = ProcessInfo.processInfo.environment["BETTERTEX_USAGE_PREVIEW"] {
            let view = panel
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }
}
