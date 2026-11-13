import AppKit
import XCTest
import BetterTeXCore
@testable import BetterTeX

final class EditorContextMenuTests: XCTestCase {
    @MainActor func testMenuPreservesSelectionAndSharesSnippetInsertion() async throws {
        _ = NSApplication.shared
        let editor = EditorPane(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor
        defer { window.close() }
        let text = editor.textView
        window.makeFirstResponder(text)
        text.string = "Hello 中文 📝 world"
        let selected = (text.string as NSString).range(of: "中文 📝")
        text.setSelectedRange(selected)
        text.sourceContext = { AgentSourceContext(file: "main.tex", source: text.string, range: text.selectedRange()) }
        var attachment: AgentSourceContext?
        text.onAttachContext = { attachment = $0 }; text.onProofread = { _ in }
        let menu = text.editingMenu(at: selected.location + 1)
        XCTAssertEqual(text.selectedRange(), selected)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), [L10n.tr("加入 Agent 上下文"), L10n.tr("校对选中文字"), L10n.tr("插入"), L10n.tr("剪切"), L10n.tr("复制"), L10n.tr("粘贴"), L10n.tr("全选"), L10n.tr("切换注释")])
        // The action uses the snapshot made when the menu opened.
        text.setSelectedRange(NSRange(location: 0, length: 0))
        try invoke(try XCTUnwrap(menu.items.first))
        XCTAssertEqual(attachment?.selection, "中文 📝")
        text.setSelectedRange(selected)
        let insert = try XCTUnwrap(menu.items.first { $0.submenu != nil }?.submenu)
        XCTAssertEqual(insert.items.filter { !$0.isSeparatorItem }.count, Snippet.allCases.count)
        try invoke(try XCTUnwrap(insert.items.first { $0.title == Snippet.bold.title }))
        XCTAssertEqual(text.string, "Hello \\textbf{中文 📝} world")
        XCTAssertEqual((text.string as NSString).substring(with: text.selectedRange()), "中文 📝")
        let undo = try XCTUnwrap(text.undoManager)
        XCTAssertTrue(undo.canUndo); undo.undo()
        XCTAssertEqual(text.string, "Hello 中文 📝 world")
    }

    @MainActor func testClickOutsideSelectionHasNoAgentActionsAndMovesInsertionPoint() async throws {
        _ = NSApplication.shared
        let text = CodeTextView(frame: .zero)
        text.string = "one two three"; text.setSelectedRange(NSRange(location: 0, length: 3))
        text.sourceContext = { AgentSourceContext(file: "main.tex", source: text.string, range: text.selectedRange()) }
        text.onAttachContext = { _ in }; text.onProofread = { _ in }; text.onInsertSnippet = { _ in }
        let menu = text.editingMenu(at: 8)
        XCTAssertEqual(text.selectedRange(), NSRange(location: 8, length: 0))
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.count, 6)
        try invoke(try XCTUnwrap(menu.items.first { $0.title == L10n.tr("切换注释") }))
        XCTAssertEqual(text.string, "% one two three")
        XCTAssertEqual(text.selectedRange(), NSRange(location: 10, length: 0))
        try invoke(try XCTUnwrap(text.editingMenu(at: 10).items.first { $0.title == L10n.tr("切换注释") }))
        XCTAssertEqual(text.string, "one two three")
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == L10n.tr("复制") }).isEnabled)
        text.isEditable = false
        XCTAssertNil(text.editingMenu(at: 8).items.first { $0.submenu != nil })
    }

    @MainActor func testPinnedContextSurvivesFileChangesAndClearsAfterSending() async throws {
        let fixture = try AgentFixture(); defer { fixture.remove() }
        let panel = TerminalPanel(frame: .zero); defer { panel.stopAll() }
        panel.configure(project: fixture.directory, tools: fixture.tools)
        let composer = try XCTUnwrap(descendants(panel).compactMap { $0 as? ComposerTextView }.first)
        composer.string = "Explain this selection"
        let attachment = try context("selected 📝", file: "first.tex")
        panel.attach(attachment)
        panel.contextFile = "second.tex"; panel.contextLines = nil
        panel.currentContext = { AgentSourceContext(file: "second.tex", source: "different", range: NSRange(location: 0, length: 9)) }
        XCTAssertEqual(panel.attachedContext, attachment)
        XCTAssertEqual(composer.string, "Explain this selection")
        composer.onSubmit?()
        XCTAssertNil(panel.attachedContext); XCTAssertEqual(composer.string, "")
        try await fixture.waitForCompletion(panel.chat)
        let arguments = try fixture.arguments()
        XCTAssertEqual(arguments.last, attachment.excerpt + "\n\nExplain this selection")
        panel.attach(attachment); panel.stopAll(); XCTAssertNil(panel.attachedContext)
    }

    @MainActor func testCancellingPinnedContextExcludesItFromTheNextMessage() async throws {
        let fixture = try AgentFixture(); defer { fixture.remove() }
        let panel = TerminalPanel(frame: .zero); defer { panel.stopAll() }
        panel.configure(project: fixture.directory, tools: fixture.tools)
        let selected = try context("Do not send this", file: "main.tex")
        panel.currentContext = { selected }; panel.attach(selected)
        XCTAssertTrue(NSApp.sendAction(Selector(("toggleContext")), to: panel, from: nil))
        XCTAssertNil(panel.attachedContext)
        let composer = try XCTUnwrap(descendants(panel).compactMap { $0 as? ComposerTextView }.first)
        composer.string = "Only this message"; composer.onSubmit?()
        try await fixture.waitForCompletion(panel.chat)
        XCTAssertEqual(try fixture.arguments().last, "Only this message")
    }

    @MainActor func testProofreadingUsesCurrentProviderReadOnlyAndPreservesDraft() async throws {
        for provider in ["Codex", "Claude"] {
            let fixture = try AgentFixture(); defer { fixture.remove() }
            let panel = TerminalPanel(frame: .zero); defer { panel.stopAll() }
            panel.configure(project: fixture.directory, tools: fixture.tools)
            panel.select(provider)
            let composer = try XCTUnwrap(descendants(panel).compactMap { $0 as? ComposerTextView }.first)
            composer.string = "Unsent draft"
            let pinned = try context("another selection", file: "draft.tex")
            panel.attach(pinned)
            // Output should return to the most recently used agent, including Claude.
            panel.select("Output")
            let selection = try context("This are a test. \\cite{key}", file: "paper.tex")
            XCTAssertTrue(panel.proofread(selection))
            XCTAssertEqual(panel.active, provider == "Claude" ? "Claude" : "Agent")
            XCTAssertFalse(panel.proofread(selection), "Busy agents must not receive a second request.")
            XCTAssertEqual(composer.string, "Unsent draft"); XCTAssertEqual(panel.attachedContext, pinned)
            try await fixture.waitForCompletion(provider == "Claude" ? panel.claudeChat : panel.chat)
            let arguments = try fixture.arguments()
            XCTAssertEqual(arguments.last, selection.proofreadingPrompt)
            XCTAssertTrue(arguments.contains(provider == "Claude" ? "plan" : "sandbox_mode=\"read-only\""))
            XCTAssertEqual(composer.string, "Unsent draft"); XCTAssertEqual(panel.attachedContext, pinned)
        }
    }

    @MainActor func testUnavailableAgentKeepsDraftAndAttachment() async throws {
        let panel = TerminalPanel(frame: .zero); defer { panel.stopAll() }
        panel.configure(project: URL(fileURLWithPath: NSTemporaryDirectory()), tools: Toolchain(environment: [:], paths: [:]))
        var error: String?
        panel.onError = { error = $0 }
        let composer = try XCTUnwrap(descendants(panel).compactMap { $0 as? ComposerTextView }.first)
        composer.string = "Keep this draft"
        let selected = try context("Some text", file: "main.tex")
        panel.attach(selected); composer.onSubmit?()
        XCTAssertNotNil(error); XCTAssertEqual(composer.string, "Keep this draft"); XCTAssertEqual(panel.attachedContext, selected)
        XCTAssertFalse(panel.proofread(selected)); XCTAssertTrue(panel.chat.isEmpty)
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor private func invoke(_ item: NSMenuItem) throws { XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)) }
    private func context(_ source: String, file: String) throws -> AgentSourceContext {
        try XCTUnwrap(AgentSourceContext(file: file, source: source, range: NSRange(location: 0, length: (source as NSString).length)))
    }
}

/// A local CLI double exercises the real dispatch boundary without invoking a model.
private struct AgentFixture {
    let directory: URL
    let tools: Toolchain
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeX-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("agent")
        try "#!/bin/sh\nprintf '%s\\0' \"$@\" > \"$BETTERTEX_TEST_ARGS\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        tools = Toolchain(environment: ["BETTERTEX_TEST_ARGS": directory.appendingPathComponent("args").path], paths: ["codex": executable.path, "claude": executable.path])
    }
    func arguments() throws -> [String] { try String(contentsOf: directory.appendingPathComponent("args"), encoding: .utf8).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    @MainActor func waitForCompletion(_ chat: AgentChatView) async throws {
        for _ in 0..<150 {
            if !chat.running { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Local agent fixture did not finish")
    }
}
