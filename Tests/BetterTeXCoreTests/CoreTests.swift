import XCTest
@testable import BetterTeXCore

final class CoreTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeX tests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    @discardableResult func write(_ path: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8); return url
    }
    func testRootDirectivesResolveSpacesAndNestedFiles() throws {
        let main = try write("my paper.tex", "\\documentclass{article}")
        let sub = try write("sections/intro.tex", "% !TeX root = ../my paper.tex\nText")
        XCTAssertEqual(try TeXProject.root(active: sub, project: directory), main)
    }
    func testRootCycleRejected() throws {
        let a = try write("a.tex", "% !TeX root = b.tex")
        try write("b.tex", "% !TeX root = a.tex")
        XCTAssertThrowsError(try TeXProject.root(active: a, project: directory))
    }
    func testAmbiguousProjectDoesNotChooseArbitraryRoot() throws {
        try write("a.tex", "\\documentclass{article}"); try write("b.tex", "\\documentclass{book}")
        let child = try write("section.tex", "A section")
        XCTAssertThrowsError(try TeXProject.root(active: child, project: directory))
    }
    func testEngineDirectiveAndOverride() {
        XCTAssertEqual(TeXProject.engine(for: "% !TEX program = lualatex", selected: .automatic), .luaLaTeX)
        XCTAssertEqual(TeXProject.engine(for: "% !TeX program = xelatex", selected: .pdfLaTeX), .pdfLaTeX)
        XCTAssertEqual(TeXProject.engine(for: "\\documentclass{ctexart}", selected: .automatic), .xeLaTeX)
        XCTAssertEqual(TeXProject.engine(for: "\\usepackage{fontspec}", selected: .automatic), .xeLaTeX)
    }
    func testSyncTeXParsingAndCoordinateConversion() throws {
        let point = try XCTUnwrap(SyncTeX.parseForward("Page:2\nx:123.4\ny:56.7\nPage:3\nx:9\ny:10\n"))
        XCTAssertEqual(point.page, 2); XCTAssertEqual(point.point(mediaHeight: 800, originX: 10, originY: 20).y, 763.3, accuracy: 0.001)
        let source = try XCTUnwrap(SyncTeX.parseInverse("Input:./sections/my file.tex\nLine:42\nColumn:-1\n", directory: directory))
        XCTAssertEqual(source.line, 42); XCTAssertEqual(source.column, 0); XCTAssertEqual(source.file, directory.appendingPathComponent("sections/my file.tex"))
    }
    func testDiskSnapshotDetectsSameSizeRewrite() throws {
        let file = try write("main.tex", "abcd"); let snapshot = try DiskSnapshot(url: file)
        XCTAssertTrue(snapshot.isCurrent(at: file)); try write("main.tex", "efgh"); XCTAssertFalse(snapshot.isCurrent(at: file))
    }
    func testPorcelainHandlesRenameAndNewlines() {
        let changes = GitService.parseStatus(" M main.tex\0R  new file.tex\0old file.tex\0?? weird\nname.tex\0")
        XCTAssertEqual(changes.count, 3); XCTAssertEqual(changes[1].path, "new file.tex"); XCTAssertEqual(changes[2].path, "weird\nname.tex")
        XCTAssertEqual(changes[1].commitPaths, ["new file.tex", "old file.tex"])
    }
    func testRunnerDoesNotInterpretShellMetacharacters() throws {
        let argument = "path with spaces; $(touch injected) `echo unsafe`"
        let result = try ProcessRunner().run("/usr/bin/printf", ["%s", argument], directory: directory)
        XCTAssertEqual(result.output, argument); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("injected").path))
    }
    func testDiagnosticsAllowColonAndSpaceInPaths() {
        let diagnostic = TeXDiagnostic.parse("/tmp/my project/main.tex:12: Undefined control sequence.\n").first
        XCTAssertEqual(diagnostic?.line, 12); XCTAssertEqual(diagnostic?.file, "/tmp/my project/main.tex")
    }
    func testAgentSettingsPassRealCLIArgumentsAndPreserveDefaults() throws {
        XCTAssertEqual(try AgentConfiguration().arguments(for: .codex), [])
        XCTAssertEqual(try AgentConfiguration(model: "gpt-6-astra", effort: "xhigh").arguments(for: .codex), ["--model", "gpt-6-astra", "-c", "model_reasoning_effort=\"xhigh\""])
        XCTAssertEqual(try AgentConfiguration(model: "opus", effort: "max").arguments(for: .claude), ["--model", "opus", "--effort", "max"])
        XCTAssertThrowsError(try AgentConfiguration(model: "--bad-model").arguments(for: .codex))
        XCTAssertThrowsError(try AgentConfiguration(model: "model; touch injected").arguments(for: .codex))
        XCTAssertThrowsError(try AgentConfiguration(effort: "ultra").arguments(for: .claude))
    }
    func testModelCacheReadsCapabilitiesAndSkipsHiddenModels() throws {
        let fixture = #"{"models":[{"slug":"local-model","display_name":"Local Model","supported_reasoning_levels":[{"effort":"low"},{"effort":"ultra"}]},{"slug":"internal","visibility":"hide"}]}"#
        let models = AgentConfiguration.codexModels(from: Data(fixture.utf8))
        XCTAssertEqual(models, [AgentModel(id: "local-model", name: "Local Model", efforts: ["low", "ultra"])])
        XCTAssertEqual(AgentConfiguration.codexModels(from: Data("broken".utf8)), [])
    }
    func testAgentHistoryListsOnlyThisProjectsSessionsNewestFirst() throws {
        let home = directory.appendingPathComponent("home"); let project = directory.appendingPathComponent("my paper")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        // Claude: one folder per project, one log per session; meta and tool-result records carry no title.
        let folder = ".claude/projects/" + AgentHistory.claudeProjectFolder(for: project)
        XCTAssertFalse(AgentHistory.claudeProjectFolder(for: project).contains(" "))
        try write("home/\(folder)/11111111-aaaa-bbbb-cccc-000000000001.jsonl", """
        {"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>ignore</local-command-caveat>"}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}
        {"type":"user","message":{"role":"user","content":"@main.tex 润色摘要"}}
        """)
        try write("home/\(folder)/empty.jsonl", "{\"type\":\"summary\"}\n")
        let claude = AgentHistory.sessions(for: .claude, project: project, home: home)
        XCTAssertEqual(claude.map(\.title), ["润色摘要"]); XCTAssertEqual(claude.first?.id, "11111111-aaaa-bbbb-cccc-000000000001")
        XCTAssertEqual(try AgentHistory.resumeArguments(for: claude[0]), ["--resume", "11111111-aaaa-bbbb-cccc-000000000001"])
        // Codex: logs for every directory share one tree, so the working directory decides.
        func rollout(_ id: String, cwd: String, prompt: String) -> String {
            let meta: [String: Any] = ["type": "session_meta", "payload": ["id": id, "cwd": cwd]]
            let context: [String: Any] = ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>x</environment_context>"]]]]
            let user: [String: Any] = ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": prompt]]]]
            return [meta, context, user].map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        }
        try write("home/.codex/sessions/2026/11/10/rollout-a.jsonl", rollout("01a1c9dd-0000-7000-8000-000000000001", cwd: project.path, prompt: "@main.tex\n```tex\n\\section{A}\n```\n检查公式"))
        try write("home/.codex/sessions/2026/11/11/rollout-b.jsonl", rollout("01a1c9dd-0000-7000-8000-000000000002", cwd: "/somewhere/else", prompt: "别的项目"))
        let codex = AgentHistory.sessions(for: .codex, project: project, home: home)
        XCTAssertEqual(codex.map(\.title), ["检查公式"])
        XCTAssertEqual(try AgentHistory.resumeArguments(for: codex[0]), ["resume", "01a1c9dd-0000-7000-8000-000000000001"])
        XCTAssertThrowsError(try AgentHistory.resumeArguments(for: AgentSession(provider: .codex, id: "--dangerous flag", title: "", date: Date())))
    }
    func testRealTeXEnginesAndSyncTeXRoundTrip() throws {
        let discovered = Toolchain.discover()
        guard discovered["pdflatex"] != nil, discovered["synctex"] != nil else { throw XCTSkip("Requires a local TeX installation") }
        let main = try write("my paper.tex", "\\documentclass{article}\n\\begin{document}\nHello from BetterTeX.\\par\n\\input{sections/intro}\n\\end{document}\n")
        let intro = try write("sections/intro.tex", "% !TeX root = ../my paper.tex\nThis source line should round trip through SyncTeX.\n")
        for engine in [TeXEngine.pdfLaTeX, .xeLaTeX, .luaLaTeX] where discovered[engine.executable] != nil {
            var paths = discovered.paths; paths.removeValue(forKey: "latexmk")
            let tools = Toolchain(environment: discovered.environment, paths: paths)
            let result = try TeXCompiler().build(active: intro, project: directory, selected: engine, tools: tools)
            XCTAssertTrue(result.succeeded, "\(engine): \(result.log)")
            let forward = try SyncTeX.forward(file: intro, line: 2, column: 1, pdf: result.pdf, tools: tools)
            let inverse = try SyncTeX.inverse(page: forward.page, x: forward.x, y: forward.y, pdf: result.pdf, root: main, tools: tools)
            XCTAssertEqual(inverse.file.resolvingSymlinksInPath(), intro.resolvingSymlinksInPath()); XCTAssertEqual(inverse.line, 2)
        }
        if discovered["latexmk"] != nil {
            let result = try TeXCompiler().build(active: intro, project: directory, selected: .automatic, tools: discovered)
            XCTAssertTrue(result.succeeded, result.log)
            let before = try Data(contentsOf: result.pdf)
            try write("my paper.tex", "\\documentclass{article}\n\\begin{document}\n\\undefinedcommand\n\\end{document}")
            let failure = try TeXCompiler().build(active: main, project: directory, selected: .automatic, tools: discovered)
            XCTAssertFalse(failure.succeeded); XCTAssertEqual(try Data(contentsOf: result.pdf), before, "Failed builds must not replace the good preview")
        }
    }
    func testLocalGitCommitPushAndFastForwardPullFromSubfolder() throws {
        let tools = Toolchain(environment: ProcessInfo.processInfo.environment, paths: ["git": "/usr/bin/git"])
        let runner = ProcessRunner()
        func git(_ args: [String], at path: URL) throws {
            let result = try runner.run("/usr/bin/git", args, directory: path); XCTAssertTrue(result.succeeded, result.output)
        }
        let remote = directory.appendingPathComponent("remote.git"); let local = directory.appendingPathComponent("local"); let peer = directory.appendingPathComponent("peer")
        try git(["init", "--bare", remote.path], at: directory); try git(["init", "-b", "main", local.path], at: directory)
        for (key, value) in [("user.email", "test@example.invalid"), ("user.name", "BetterTeX Tests")] { try git(["config", key, value], at: local) }
        let file = try write("local/sections/my paper.tex", "First version")
        try git(["add", "."], at: local); try git(["commit", "-m", "Initial"], at: local); try git(["remote", "add", "origin", remote.path], at: local); try git(["push", "-u", "origin", "main"], at: local)
        let service = GitService(directory: local.appendingPathComponent("sections"), tools: tools)
        try "Second version".write(to: file, atomically: true, encoding: .utf8)
        let state = try service.state(); XCTAssertEqual(state.changes.first?.path, "sections/my paper.tex")
        _ = try service.commitAndPush(message: "Update paper", paths: state.changes.map(\.path))
        try git(["clone", "-b", "main", remote.path, peer.path], at: directory)
        for (key, value) in [("user.email", "test@example.invalid"), ("user.name", "BetterTeX Tests")] { try git(["config", key, value], at: peer) }
        try write("peer/sections/my paper.tex", "Third version")
        try git(["commit", "-am", "Peer update"], at: peer); try git(["push"], at: peer)
        _ = try service.pull(); XCTAssertEqual(try String(contentsOf: file), "Third version")
        try git(["mv", "sections/my paper.tex", "sections/renamed paper.tex"], at: local)
        let renamed = try service.state()
        _ = try service.commitAndPush(message: "Rename paper", paths: renamed.changes.flatMap(\.commitPaths))
        let headFiles = try service.checked(["ls-tree", "-r", "--name-only", "HEAD"])
        XCTAssertTrue(headFiles.contains("renamed paper.tex")); XCTAssertFalse(headFiles.contains("my paper.tex"))
    }
}

final class BuildProgressTests: XCTestCase {
    func testStageTrackerFollowsLatexmkAcrossChunks() {
        var tracker = BuildStageTracker()
        var stages = tracker.consume("Latexmk: applying rule 'pdflatex'...\n------------\nRunning 'pdfla")
        XCTAssertTrue(stages.isEmpty)
        stages += tracker.consume("tex  -interaction=nonstopmode \"m.tex\"'\n------------\nThis is pdfTeX\nRunning 'bibtex  \"m.aux\"'\n")
        stages += tracker.consume("Running 'pdflatex  -recorder \"m.tex\"'\nRunning '/Library/TeX/texbin/pdflatex -x'\nNot Running 'x'\n")
        XCTAssertEqual(stages.map(\.tool), ["pdflatex", "bibtex", "pdflatex", "pdflatex"])
        XCTAssertEqual(stages.map(\.pass), [1, 1, 2, 3]); XCTAssertEqual(stages.map(\.step), [1, 2, 3, 4])
        XCTAssertEqual(stages[1].title, "整理参考文献"); XCTAssertEqual(stages[3].title, "排版 · 第 3 遍")
        XCTAssertEqual(tracker.begin("/usr/bin/biber").step, 5)
    }
    /// Runs latexmk on a document with a bibliography and checks the reported programme sequence.
    func testRealBuildReportsStagesAndSecondBuildRunsNothing() throws {
        let tools = Toolchain.discover()
        try XCTSkipUnless(tools["latexmk"] != nil && tools["pdflatex"] != nil && tools["bibtex"] != nil, "需要 latexmk、pdflatex 和 bibtex")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeX stages \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = directory.appendingPathComponent("main.tex")
        try "\\documentclass{article}\\begin{document}Hi \\cite{a}\\bibliographystyle{plain}\\bibliography{refs}\\end{document}\n".write(to: main, atomically: true, encoding: .utf8)
        try "@book{a,title={T},author={A},year={2020},publisher={P}}\n".write(to: directory.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)
        var stages: [BuildStage] = []
        let first = try TeXCompiler().build(active: main, project: directory, selected: .automatic, tools: tools, onStage: { stages.append($0) })
        XCTAssertTrue(first.succeeded)
        XCTAssertEqual(Array(stages.map(\.tool).prefix(3)), ["pdflatex", "bibtex", "pdflatex"])
        XCTAssertGreaterThanOrEqual(stages.filter { $0.tool == "pdflatex" }.count, 3)
        XCTAssertEqual(stages.map(\.step), Array(1...stages.count))
        // With nothing changed latexmk starts no programme at all.
        var again: [BuildStage] = []
        let second = try TeXCompiler().build(active: main, project: directory, selected: .automatic, tools: tools, onStage: { again.append($0) })
        XCTAssertTrue(second.succeeded); XCTAssertTrue(again.isEmpty)
    }
    func testBuildSignatureChangesOnlyWithInputs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeX signature \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".bettertex"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = directory.appendingPathComponent("main.tex"); try "a".write(to: main, atomically: true, encoding: .utf8)
        let first = BuildSignature.compute(project: directory, root: main.path, engine: "Auto")
        XCTAssertEqual(first, BuildSignature.compute(project: directory, root: main.path, engine: "Auto"))
        // Build output lives in the hidden .bettertex folder and must not look like a source change.
        try "pdf".write(to: directory.appendingPathComponent(".bettertex/main.pdf"), atomically: true, encoding: .utf8)
        XCTAssertEqual(first, BuildSignature.compute(project: directory, root: main.path, engine: "Auto"))
        XCTAssertNotEqual(first, BuildSignature.compute(project: directory, root: main.path, engine: "XeLaTeX"))
        try "ab".write(to: main, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(first, BuildSignature.compute(project: directory, root: main.path, engine: "Auto"))
    }
}

final class CommitMessageTests: XCTestCase {
    func testPicksNewestLunaModelAndFallsBack() {
        let models = [AgentModel(id: "gpt-6.1-sol", name: "", efforts: []), AgentModel(id: "gpt-6-luna", name: "", efforts: []), AgentModel(id: "gpt-5.6-luna", name: "", efforts: [])]
        XCTAssertEqual(CommitMessageWriter.lunaModel(from: models), "gpt-6-luna")
        XCTAssertEqual(CommitMessageWriter.lunaModel(from: []), CommitMessageWriter.fallbackModel)
    }
    func testCleansModelReplyToOneSubjectLine() {
        XCTAssertEqual(CommitMessageWriter.clean("```\n\"Fix the tab switcher\"\n```\nBecause…"), "Fix the tab switcher")
        XCTAssertEqual(CommitMessageWriter.clean("git commit -m \"完善方法章节\"\n"), "完善方法章节")
        XCTAssertEqual(CommitMessageWriter.clean(" \n"), "")
    }
    func testReadsAgentMessageFromEventStream() {
        XCTAssertEqual(CommitMessageWriter.agentMessage(jsonLine: #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Fix tabs"}}"#), "Fix tabs")
        XCTAssertNil(CommitMessageWriter.agentMessage(jsonLine: #"{"type":"item.completed","item":{"type":"reasoning","text":"hm"}}"#))
        XCTAssertNil(CommitMessageWriter.agentMessage(jsonLine: "2026 ERROR not json"))
    }
    func testChangeSummaryCoversTrackedDiffAndNewFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bettertex-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ProcessRunner()
        func git(_ args: [String]) throws { let result = try runner.run("/usr/bin/git", args, directory: directory); XCTAssertTrue(result.succeeded, result.output) }
        try git(["init", "-b", "main"]); try git(["config", "user.email", "test@example.invalid"]); try git(["config", "user.name", "BetterTeX Tests"])
        try "old line\n".write(to: directory.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-m", "Initial"])
        try "new line\n".write(to: directory.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        try "fresh notes\n".write(to: directory.appendingPathComponent("notes.tex"), atomically: true, encoding: .utf8)
        let service = GitService(directory: directory, tools: Toolchain(environment: ProcessInfo.processInfo.environment, paths: ["git": "/usr/bin/git"]))
        let summary = try service.changeSummary(try service.state().changes)
        XCTAssertTrue(summary.contains("-old line") && summary.contains("+new line"), summary)
        XCTAssertTrue(summary.contains("New file notes.tex") && summary.contains("fresh notes"), summary)
        XCTAssertEqual(service.recentSubjects().trimmingCharacters(in: .newlines), "Initial")
        XCTAssertThrowsError(try service.changeSummary([]))
        XCTAssertTrue(try service.changeSummary(try service.state().changes, limit: 20).hasSuffix("(truncated)"))
    }
}

final class GitLineChangeTests: XCTestCase {
    func testParsesHunkHeaders() {
        let diff = "diff --git a/m.tex b/m.tex\n--- a/m.tex\n+++ b/m.tex\n@@ -2 +2 @@ ctx\n-b\n+B\n@@ -4,0 +5,2 @@\n+x\n+y\n@@ -9,3 +11,0 @@\n-a\n@@ -1,2 +0,0 @@\n@@ -20 +30,3 @@\n"
        XCTAssertEqual(LineChange.parse(diff: diff), [LineChange(.modified, 2...2), LineChange(.added, 5...6), LineChange(.deleted, 12...12), LineChange(.deleted, 1...1), LineChange(.modified, 30...30), LineChange(.added, 31...32)])
        XCTAssertTrue(LineChange.parse(diff: "").isEmpty)
    }
    func testLineChangesAgainstRealRepository() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeX gutter \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = Toolchain(environment: ProcessInfo.processInfo.environment, paths: ["git": "/usr/bin/git"])
        let service = GitService(directory: directory, tools: tools)
        let file = directory.appendingPathComponent("my paper.tex")
        try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(service.lineChanges(file: file).isEmpty, "no repository yet")
        func git(_ args: [String]) throws { XCTAssertTrue(try ProcessRunner().run("/usr/bin/git", args, directory: directory).succeeded) }
        try git(["init", "-b", "main"]); try git(["config", "user.email", "test@example.invalid"]); try git(["config", "user.name", "BetterTeX Tests"])
        try git(["add", "."]); try git(["commit", "-m", "Initial"])
        XCTAssertTrue(service.lineChanges(file: file).isEmpty)
        try "one\nTWO\nthree\nnew\nnewer\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(service.lineChanges(file: file), [LineChange(.modified, 2...2), LineChange(.modified, 4...4), LineChange(.added, 5...5)])
        try "two\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(service.lineChanges(file: file), [LineChange(.deleted, 1...1)])
        let fresh = directory.appendingPathComponent("fresh.tex"); try "a\nb\n".write(to: fresh, atomically: true, encoding: .utf8)
        XCTAssertEqual(service.lineChanges(file: fresh), [LineChange(.added, 1...2)])
    }
}

final class WarningTests: XCTestCase {
    func testUndefinedReferencesAndCitationsAcrossWrappedLogLines() {
        let log = """
        LaTeX Warning: Citation `tang2025osd' on page 3 undefined on input line 173.

        LaTeX Warning: Reference `fig:a-very-long-label-name-that-wraps-in-the-log' on page 1 undefined on inpu
        t line 42.
        Package natbib Warning: Citation `other' on page 2 undefined on input line 9.
        LaTeX Warning: Citation `tang2025osd' on page 3 undefined on input line 173.
        Overfull \\hbox (3.0pt too wide) in paragraph at lines 5--6
        """
        let warnings = TeXWarning.parse(log)
        XCTAssertEqual(warnings.map(\.line), [173, 42, 9])
        XCTAssertEqual(warnings.map(\.key), ["tang2025osd", "fig:a-very-long-label-name-that-wraps-in-the-log", "other"])
        XCTAssertTrue(warnings[0].message.contains("引用文献")); XCTAssertTrue(warnings[1].message.contains("交叉引用"))
        XCTAssertTrue(TeXWarning.parse("Output written on main.pdf").isEmpty)
    }
}

final class CodexAgentTests: XCTestCase {
    func testParsesExecEvents() {
        XCTAssertEqual(CodexEvent.parse(line: #"{"type":"thread.started","thread_id":"01a1ca5e-ca65-76c2-a7ab-ab8234bf6e2d"}"#), .threadStarted("01a1ca5e-ca65-76c2-a7ab-ab8234bf6e2d"))
        XCTAssertEqual(CodexEvent.parse(line: #"{"type":"turn.started"}"#), .turnStarted)
        XCTAssertEqual(CodexEvent.parse(line: #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"I’ll read note.txt.\n"}}"#),
                       .item(CodexItem(id: "item_2", kind: .message, text: "I’ll read note.txt.\n")))
        XCTAssertEqual(CodexEvent.parse(line: #"{"type":"item.started","item":{"id":"item_3","type":"command_execution","command":"/bin/zsh -lc 'cat note.txt'","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#),
                       .item(CodexItem(id: "item_3", kind: .command, text: "cat note.txt", status: .running)))
        XCTAssertEqual(CodexEvent.parse(line: #"{"type":"item.completed","item":{"id":"item_3","type":"command_execution","command":"/bin/zsh -lc 'cat note.txt'","aggregated_output":"hello\n","exit_code":0,"status":"completed"}}"#),
                       .item(CodexItem(id: "item_3", kind: .command, text: "cat note.txt", detail: "hello\n", status: .done, exitCode: 0)))
        XCTAssertEqual(CodexEvent.parse(line: #"{"type":"item.completed","item":{"id":"i","type":"command_execution","command":"bash -lc \"ls x\"","aggregated_output":"no","exit_code":2,"status":"completed"}}"#),
                       .item(CodexItem(id: "i", kind: .command, text: "ls x", detail: "no", status: .failed, exitCode: 2)))
        XCTAssertEqual(CodexEvent.parse(line: #"{"type":"item.completed","item":{"id":"f","type":"file_change","changes":[{"path":"main.tex","kind":"update"},{"path":"a.tex","kind":"add"}],"status":"completed"}}"#),
                       .item(CodexItem(id: "f", kind: .fileChange, text: "2 个文件", detail: "修改  main.tex\n新增  a.tex")))
        XCTAssertEqual(CodexEvent.parse(line: #"{"type":"item.updated","item":{"id":"t","type":"todo_list","items":[{"text":"read","completed":true},{"text":"edit","completed":false}]}}"#),
                       .item(CodexItem(id: "t", kind: .todo, text: "计划", detail: "☑ read\n☐ edit", status: .running)))
        XCTAssertEqual(CodexEvent.parse(line: #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"config warning"}}"#), .item(CodexItem(id: "item_0", kind: .notice, text: "config warning")))
        XCTAssertEqual(CodexEvent.parse(line: #"{"type":"turn.completed","usage":{"input_tokens":42049,"cached_input_tokens":28032,"output_tokens":57}}"#), .turnCompleted(inputTokens: 42049, outputTokens: 57))
        XCTAssertEqual(CodexEvent.parse(line: #"{"type":"turn.failed","error":{"message":"quota"}}"#), .turnFailed("quota"))
        XCTAssertNil(CodexEvent.parse(line: "Reading additional input from stdin...")); XCTAssertNil(CodexEvent.parse(line: #"{"type":"something.new"}"#)); XCTAssertNil(CodexEvent.parse(line: "{broken"))
    }
    func testRequestArguments() throws {
        let fresh = try CodexRequest(prompt: "--help; rm -rf /", configuration: AgentConfiguration(model: "gpt-5.5", effort: "high"), sandbox: .readOnly).arguments()
        XCTAssertEqual(fresh, ["exec", "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"read-only\"", "--model", "gpt-5.5", "-c", "model_reasoning_effort=\"high\"", "--", "--help; rm -rf /"])
        let resumed = try CodexRequest(prompt: "continue", thread: "01a1ca5e-ca65-76c2-a7ab-ab8234bf6e2d").arguments()
        XCTAssertEqual(resumed, ["exec", "resume", "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"workspace-write\"", "--", "01a1ca5e-ca65-76c2-a7ab-ab8234bf6e2d", "continue"])
        XCTAssertThrowsError(try CodexRequest(prompt: "  ").arguments()); XCTAssertThrowsError(try CodexRequest(prompt: "x", thread: "--last").arguments())
        XCTAssertThrowsError(try CodexRequest(prompt: "x", configuration: AgentConfiguration(model: "bad model;")).arguments())
    }
    func testTurnStreamsEventsFromAProcess() throws {
        // A stand-in executable that prints two events split across writes, plus noise on stderr.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeX codex \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-codex")
        try "#!/bin/sh\nprintf '{\"type\":\"thread.started\",'\nsleep 0.1\nprintf '\"thread_id\":\"abcdefgh-1\"}\\n'\necho 'noise line' >&2\nprintf '{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":3,\"output_tokens\":4}}'\nexit 3\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var events: [CodexEvent] = []
        let result = try CodexTurn().run(CodexRequest(prompt: "hi"), executable: script.path, directory: directory, environment: ProcessInfo.processInfo.environment) { events.append($0) }
        XCTAssertEqual(events, [.threadStarted("abcdefgh-1"), .turnCompleted(inputTokens: 3, outputTokens: 4)])
        XCTAssertEqual(result.status, 3); XCTAssertEqual(result.stderr, "noise line")
    }
}
