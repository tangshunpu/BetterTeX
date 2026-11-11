import XCTest
@testable import BetterTeXCore

final class OverleafTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeX overleaf \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    @discardableResult func write(_ path: String, _ text: String, in root: URL? = nil) throws -> URL {
        let url = (root ?? directory).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8); return url
    }

    // MARK: socket.io framing
    func testSocketFramesRoundTrip() throws {
        guard case .event(let name, let args, let ack)? = SocketIOFrame.parse(#"5:::{"name":"otUpdateApplied","args":[{"doc":"d1","v":7,"op":[{"p":3,"i":"a:b"}]}]}"#) else { return XCTFail() }
        XCTAssertEqual(name, "otUpdateApplied"); XCTAssertNil(ack)
        XCTAssertEqual(((args[0] as? [String: Any])?["op"] as? [[String: Any]])?.first?["i"] as? String, "a:b")
        guard case .ack(let id, let values)? = SocketIOFrame.parse(#"6:::12+[null,["a","b"],5]"#) else { return XCTFail() }
        XCTAssertEqual(id, 12); XCTAssertEqual(values.count, 3); XCTAssertEqual(values[2] as? Int, 5)
        guard case .ack(let bare, let none)? = SocketIOFrame.parse("6:::4") else { return XCTFail() }
        XCTAssertEqual(bare, 4); XCTAssertTrue(none.isEmpty)
        guard case .heartbeat? = SocketIOFrame.parse("2::") else { return XCTFail() }
        guard case .connect? = SocketIOFrame.parse("1::") else { return XCTFail() }
        let encoded = SocketIOFrame.encodeEvent("joinDoc", args: ["abc", ["encodeRanges": true]], ackID: 3)
        XCTAssertTrue(encoded.hasPrefix("5:3+::"))
        guard case .event(let again, let payload, let ackID)? = SocketIOFrame.parse(encoded) else { return XCTFail() }
        XCTAssertEqual(again, "joinDoc"); XCTAssertEqual(payload[0] as? String, "abc"); XCTAssertEqual(ackID, 3)
    }

    // MARK: project tree
    func testTreePathsAndMutations() throws {
        let project: [String: Any] = ["rootFolder": [[
            "_id": "root", "name": "rootFolder",
            "docs": [["_id": "d1", "name": "main.tex"]], "fileRefs": [["_id": "f1", "name": "logo.png"]],
            "folders": [["_id": "s", "name": "sections", "docs": [["_id": "d2", "name": "intro.tex"]], "fileRefs": [], "folders": []]]
        ]]]
        var tree = try XCTUnwrap(OverleafTree(project: project))
        XCTAssertEqual(tree.rootID, "root")
        XCTAssertEqual(tree.path(of: "d2"), "sections/intro.tex")
        XCTAssertEqual(tree.entity(atPath: "logo.png")?.kind, .file)
        XCTAssertNil(tree.entity(atPath: "sections"))
        tree.add(["_id": "d3", "name": "method.tex"], kind: .doc, parent: "s")
        tree.rename("s", to: "chapters"); XCTAssertEqual(tree.entity(atPath: "chapters/method.tex")?.id, "d3")
        tree.move("d3", to: "root"); XCTAssertEqual(tree.path(of: "d3"), "method.tex")
        tree.remove("s"); XCTAssertNil(tree.path(of: "d2")); XCTAssertNil(tree.entity(atPath: "chapters/intro.tex"))
    }

    // MARK: text operations
    func testSpliceApplyAndUnicode() throws {
        let cases = [("hello world", "hello brave world"), ("abc", ""), ("", "abc"), ("中文测试", "中文的测试"), ("a😀b", "a😁b"), ("aaa", "aa"), ("x\ny\nz", "x\nz"), ("same", "same")]
        for (old, new) in cases {
            let ops = OverleafText.splice(from: old, to: new)
            XCTAssertEqual(try OverleafText.apply(ops, to: old), new, "\(old) → \(new)")
            for op in ops { XCTAssertNotNil(op.text.data(using: .utf8)); XCTAssertEqual(TextOp(json: op.json), op) }
        }
        XCTAssertTrue(OverleafText.splice(from: "same", to: "same").isEmpty)
        // Emoji are replaced whole, never split across a surrogate pair.
        let emoji = OverleafText.splice(from: "a😀b", to: "a😁b")
        XCTAssertEqual(emoji.first?.position, 1); XCTAssertEqual(emoji.first?.text, "😀")
        XCTAssertThrowsError(try OverleafText.apply([TextOp(.delete, at: 0, "zzz")], to: "abc"))
        XCTAssertThrowsError(try OverleafText.apply([TextOp(.insert, at: 9, "x")], to: "abc"))
    }
    func testWebsocketLineDecoding() {
        let packed = String(String.UnicodeScalarView("中文 é".utf8.map { Unicode.Scalar($0) }))
        XCTAssertEqual(OverleafText.decode(packed), "中文 é")
        XCTAssertEqual(OverleafText.decode("plain ascii"), "plain ascii")
        XCTAssertEqual(OverleafText.decode("已经是中文"), "已经是中文")
    }
    func testOffsetsAndShifts() {
        let text = "ab\ncde\n\nf"
        XCTAssertEqual(OverleafText.offset(row: 1, column: 2, in: text), 5)
        XCTAssertEqual(OverleafText.offset(row: 1, column: 99, in: text), 6)
        XCTAssertEqual(OverleafText.offset(row: 99, column: 0, in: text), 8)
        let position = OverleafText.rowColumn(of: 5, in: text); XCTAssertEqual(position.row, 1); XCTAssertEqual(position.column, 2)
        XCTAssertEqual(OverleafText.shift(5, by: [TextOp(.insert, at: 2, "xx")]), 7)
        XCTAssertEqual(OverleafText.shift(5, by: [TextOp(.delete, at: 3, "abcdef")]), 3)
        XCTAssertEqual(OverleafText.shift(5, by: [TextOp(.insert, at: 9, "xx")]), 5)
        var comments = [CommentRange(thread: "t", position: 4, text: "world")]
        comments = OverleafText.shift(comments, by: [TextOp(.insert, at: 0, "ab"), TextOp(.insert, at: 8, "!"), TextOp(.delete, at: 9, "rl")])
        XCTAssertEqual(comments[0].position, 6); XCTAssertEqual(comments[0].length, 4)
        comments = OverleafText.shift(comments, by: [TextOp(.comment, at: 1, "x", thread: "n")])
        XCTAssertEqual(comments.map(\.thread), ["t", "n"])
        let parsed = CommentRange(json: ["id": "c1", "op": ["c": "quoted", "p": 12, "t": "thread9"]])
        XCTAssertEqual(parsed?.thread, "thread9"); XCTAssertEqual(parsed?.length, 6)
    }
    func testPresenceParsing() {
        let updated = OverleafPresence(json: ["id": "P.1", "user_id": "u1", "name": "Ada Lovelace", "email": "ada@example.com", "row": 3, "column": 4, "doc_id": "d1"])
        XCTAssertEqual(updated?.initials, "AL"); XCTAssertEqual(updated?.row, 3); XCTAssertEqual(updated?.docID, "d1")
        let listed = OverleafPresence(json: ["client_id": "P.2", "user_id": "u2", "first_name": "", "last_name": "", "email": "bob@example.com", "cursorData": ["row": 1, "column": 0, "doc_id": "d2"]])
        XCTAssertEqual(listed?.name, "bob@example.com"); XCTAssertEqual(listed?.docID, "d2"); XCTAssertEqual(listed?.initials, "BE")
        XCTAssertEqual(updated?.hue, OverleafPresence(json: ["id": "P.9", "user_id": "u1"])?.hue)
    }

    // MARK: three-way merge
    func testMergeCombinesIndependentEdits() {
        let base = "one\ntwo\nthree\nfour\nfive"
        let ours = "one\nTWO\nthree\nfour\nfive\nsix"
        let theirs = "zero\none\ntwo\nthree\nFOUR\nfive"
        let result = Merge3.merge(base: base, ours: ours, theirs: theirs, style: .markers)
        XCTAssertEqual(result.conflicts, 0); XCTAssertEqual(result.text, "zero\none\nTWO\nthree\nFOUR\nfive\nsix")
        XCTAssertEqual(Merge3.merge(base: base, ours: base, theirs: theirs, style: .markers).text, theirs)
        XCTAssertEqual(Merge3.merge(base: base, ours: ours, theirs: base, style: .markers).text, ours)
        XCTAssertEqual(Merge3.merge(base: base, ours: ours, theirs: ours, style: .markers).conflicts, 0)
        XCTAssertEqual(Merge3.merge(base: "a\nb\nc", ours: "a\nc", theirs: "a\nb\nc\nd", style: .markers).text, "a\nc\nd")
    }
    func testMergeConflicts() {
        let marked = Merge3.merge(base: "a\nb\nc", ours: "a\nours\nc", theirs: "a\ntheirs\nc", style: .markers)
        XCTAssertEqual(marked.conflicts, 1); XCTAssertTrue(Merge3.hasMarkers(marked.text))
        XCTAssertEqual(marked.text, "a\n\(Merge3.oursMarker)\nours\n=======\ntheirs\n\(Merge3.theirsMarker)\nc")
        let preferred = Merge3.merge(base: "a\nb\nc", ours: "a\nours\nc", theirs: "a\ntheirs\nc\nd", style: .preferOurs)
        XCTAssertEqual(preferred.text, "a\nours\nc\nd"); XCTAssertFalse(Merge3.hasMarkers(preferred.text))
        // Without a common ancestor, differing files conflict as a whole instead of silently losing a side.
        XCTAssertEqual(Merge3.merge(base: "", ours: "x", theirs: "y", style: .markers).conflicts, 1)
    }
    func testMergeRandomisedAgainstIndependentEdits() {
        // Edits to disjoint, separated lines must always merge cleanly and keep both changes.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let base = (0..<30).map { "line \($0)" }
            var ours = base, theirs = base
            let a = Int.random(in: 0..<12, using: &generator), b = Int.random(in: 16..<30, using: &generator)
            ours[a] = "ours \(a)"; theirs[b] = "theirs \(b)"
            if Bool.random(using: &generator) { ours.insert("added by us", at: a) }
            if Bool.random(using: &generator) { theirs.remove(at: b - 1) }
            let result = Merge3.merge(base: base.joined(separator: "\n"), ours: ours.joined(separator: "\n"), theirs: theirs.joined(separator: "\n"), style: .markers)
            XCTAssertEqual(result.conflicts, 0)
            XCTAssertTrue(result.text.contains("ours \(a)")); XCTAssertTrue(result.text.contains("theirs \(b)"))
        }
    }

    // MARK: sync planning
    func testSyncPlan() {
        let base = ["same": "1", "localEdit": "1", "remoteEdit": "1", "both": "1", "localGone": "1", "remoteGone": "1", "bothGone": "1", "goneButRemoteEdited": "1", "converged": "1"]
        let local = ["same": "1", "localEdit": "2", "remoteEdit": "1", "both": "2", "remoteGone": "1", "newLocal": "5", "newBoth": "7", "converged": "9", "agreed": "4"]
        let remote = ["same": "1", "localEdit": "1", "remoteEdit": "3", "both": "3", "localGone": "1", "goneButRemoteEdited": "8", "newRemote": "6", "newBoth": "8", "converged": "9", "agreed": "4"]
        let plan = Dictionary(uniqueKeysWithValues: SyncPlanner.plan(local: local, remote: remote, base: base).map { ($0.path, $0) })
        XCTAssertNil(plan["same"])
        XCTAssertEqual(plan["localEdit"], .upload("localEdit")); XCTAssertEqual(plan["remoteEdit"], .download("remoteEdit"))
        XCTAssertEqual(plan["both"], .merge("both")); XCTAssertEqual(plan["newBoth"], .merge("newBoth"))
        XCTAssertEqual(plan["localGone"], .deleteRemote("localGone")); XCTAssertEqual(plan["remoteGone"], .deleteLocal("remoteGone"))
        XCTAssertEqual(plan["bothGone"], .record("bothGone")); XCTAssertEqual(plan["goneButRemoteEdited"], .download("goneButRemoteEdited"))
        XCTAssertEqual(plan["newLocal"], .upload("newLocal")); XCTAssertEqual(plan["newRemote"], .download("newRemote"))
        XCTAssertEqual(plan["converged"], .record("converged")); XCTAssertEqual(plan["agreed"], .record("agreed"))
        XCTAssertTrue(SyncPlanner.plan(local: base, remote: base, base: base).isEmpty)
    }

    // MARK: files and link
    func testScanIgnoresByproductsAndHiddenFiles() throws {
        try write("main.tex", "\\documentclass{article}"); try write("sections/intro.tex", "Intro"); try write("refs.bib", "@book{a}")
        try write("main.aux", "x"); try write("main.log", "x"); try write("main.synctex.gz", "x"); try write(".bettertex/preview/main.pdf", "x"); try write(".git/config", "x"); try write(".DS_Store", "x")
        let files = OverleafFiles.scan(directory)
        XCTAssertEqual(Set(files.keys), ["main.tex", "sections/intro.tex", "refs.bib"])
        XCTAssertEqual(files["main.tex"], OverleafFiles.hash(Data("\\documentclass{article}".utf8)))
        XCTAssertTrue(OverleafFiles.isText(path: "a.tex", data: Data("hi".utf8)))
        XCTAssertFalse(OverleafFiles.isText(path: "a.png", data: Data([0x89, 0x50, 0, 1])))
    }
    func testLinkPersistsBaseAndAncestorText() throws {
        var link = OverleafLink(host: OverleafClient.defaultHost, projectID: "0123456789abcdef01234567", name: "Paper")
        link.mode = .interval; link.intervalMinutes = 15; link.lastSync = Date(timeIntervalSince1970: 1_700_000_000)
        link.setBase(project: directory, path: "sections/intro.tex", data: Data("Intro".utf8))
        link.setBase(project: directory, path: "figure.png", data: Data([0, 1, 2]))
        try link.save(project: directory)
        let loaded = try XCTUnwrap(OverleafLink.load(project: directory))
        XCTAssertEqual(loaded, link)
        XCTAssertEqual(OverleafLink.baseText(project: directory, path: "sections/intro.tex"), "Intro")
        XCTAssertNil(OverleafLink.baseText(project: directory, path: "figure.png"))
        // The link and its ancestors live under .bettertex and therefore never sync.
        XCTAssertTrue(OverleafFiles.scan(directory).isEmpty)
        link.setBase(project: directory, path: "sections/intro.tex", data: nil)
        XCTAssertNil(link.base["sections/intro.tex"]); XCTAssertNil(OverleafLink.baseText(project: directory, path: "sections/intro.tex"))
        OverleafLink.remove(project: directory); XCTAssertNil(OverleafLink.load(project: directory))
    }
    func testZipRoundTripSkipsIgnoredFiles() throws {
        let source = directory.appendingPathComponent("source"), target = directory.appendingPathComponent("target"), archive = directory.appendingPathComponent("p.zip")
        try write("main.tex", "Main 中文", in: source); try write("figures/a b.txt", "fig", in: source); try write("main.log", "log", in: source); try write(".bettertex/overleaf.json", "{}", in: source)
        try OverleafFiles.zip(project: source, to: archive)
        try OverleafFiles.unzip(archive, to: target)
        XCTAssertEqual(OverleafFiles.scan(target), OverleafFiles.scan(source))
        XCTAssertEqual(Set(OverleafFiles.scan(target).keys), ["main.tex", "figures/a b.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("main.log").path))
    }

    // MARK: live service (opt-in)
    /// Anonymous handshake against the real service: checks the transport and framing only.
    func testLiveServiceSpeaksExpectedProtocol() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BETTERTEX_OVERLEAF_LIVE"] == "1", "设置 BETTERTEX_OVERLEAF_LIVE=1 以连接 overleaf.com")
        let client = OverleafClient(host: URL(string: OverleafClient.defaultHost)!, cookies: [])
        do { _ = try await client.projects(); XCTFail("anonymous request should be rejected") } catch OverleafError.notLoggedIn {}
        let token = try await client.token(); XCTAssertGreaterThan(token.count, 10)
        let socket = OverleafSocket(); let rejected = expectation(description: "connectionRejected")
        socket.onEvent = { name, args in print("LIVE event", name, args); if name == "connectionRejected" { rejected.fulfill() } }
        socket.onClose = { print("LIVE close", $0) }
        try await socket.connect(client: client, projectID: "0123456789abcdef01234567")
        await fulfillment(of: [rejected], timeout: 20); socket.close()
    }
}
