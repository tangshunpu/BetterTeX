import AppKit
import BetterTeXCore

/// The document currently edited together with collaborators.
private final class LiveDoc {
    let docID: String
    let path: String
    let url: URL
    /// The text Overleaf holds at `version`, as far as we have been told.
    var shadow: String
    var version: Int
    /// Our operation awaiting the server's acknowledgement.
    var inflight: [TextOp]?
    var needsResync = false
    var comments: [CommentRange]
    init(docID: String, path: String, url: URL, shadow: String, version: Int, comments: [CommentRange]) {
        self.docID = docID; self.path = path; self.url = url; self.shadow = shadow; self.version = version; self.comments = comments
    }
}

/// Connects a workspace folder to an Overleaf project: file sync, live editing of the open
/// document, collaborator presence and comments. All state lives on the main thread.
final class OverleafController {
    private enum Status { case idle, signedOut, connecting, online, syncing, offline(String) }
    unowned let workspace: WorkspaceController
    private var ui: WorkspaceView { workspace.ui }
    private var client: OverleafClient?
    private(set) var link: OverleafLink?
    private var project: URL?
    private var socket: OverleafSocket?
    private var tree: OverleafTree?
    private var publicID = ""
    private var permissions = ""
    private var presence: [String: OverleafPresence] = [:]
    private var threads: [String: OverleafThread] = [:]
    private var live: LiveDoc?
    private var joining: String?
    private var status = Status.idle
    private var conflicts = 0
    private var syncing = false
    private var syncQueued = false
    private var lastZip = Date.distantPast
    private var generation = 0
    private var retries = 0
    private var jobs: [String: DispatchWorkItem] = [:]
    private var poll: Timer?
    private let popover = NSPopover()
    private let panel = OverleafPanel()

    private var host: URL { URL(string: link?.host ?? UserDefaults.standard.string(forKey: "overleaf.host") ?? "") ?? URL(string: OverleafClient.defaultHost)! }
    private var canWrite: Bool { permissions == "owner" || permissions == "readAndWrite" }

    init(workspace: WorkspaceController) {
        self.workspace = workspace
        popover.contentViewController = panel; popover.behavior = .transient; popover.contentSize = NSSize(width: 340, height: 440)
        panel.onJump = { [weak self] offset in
            guard let self else { return }
            let position = OverleafText.rowColumn(of: offset, in: self.ui.editor.textView.string)
            self.ui.editor.goTo(line: position.row + 1, column: position.column)
        }
        panel.onReply = { [weak self] thread, text in self?.reply(thread: thread, text: text) }
        panel.onResolve = { [weak self] in self?.resolve(thread: $0) }
        panel.onAddComment = { [weak self] in self?.addComment($0) }
        panel.onInvite = { [weak self] in self?.popover.close(); self?.invite() }
    }

    // MARK: Plumbing
    private func after(_ key: String, _ delay: TimeInterval, _ work: @escaping () -> Void) {
        jobs[key]?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.jobs[key] = nil; work() }
        jobs[key] = job; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: job)
    }
    /// Runs asynchronous work on the main actor and reports failures.
    private func run(_ label: String, alert: Bool = false, _ operation: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor [weak self] in
            do { try await operation() }
            catch {
                guard let self else { return }
                if case OverleafError.notLoggedIn = error { self.client = nil; if self.link != nil { self.set(.signedOut) } }
                let message = "\(label)：\(error.localizedDescription)"
                self.ui.terminal.append("\nOverleaf · \(message)\n")
                if alert { self.workspace.error(message) } else { self.workspace.setStatus(message) }
            }
        }
    }
    private func background<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }
    private func relativePath(_ url: URL) -> String? {
        guard let project else { return nil }
        let path = url.standardizedFileURL.path, root = project.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1)).precomposedStringWithCanonicalMapping
    }
    private func isDirty(_ path: String) -> Bool { workspace.buffers.contains { $0.dirty && relativePath($0.url) == path } }

    // MARK: Account
    /// Builds a client from saved cookies, showing the sign-in window only when asked to.
    @MainActor private func ensureClient(interactive: Bool) async throws -> OverleafClient {
        if let client { return client }
        var cookies = await OverleafLogin.storedCookies(host: host)
        if cookies.isEmpty {
            guard interactive else { throw OverleafError.notLoggedIn }
            cookies = try await OverleafLogin.present(host: host)
        }
        let created = OverleafClient(host: host, cookies: cookies); client = created; return created
    }
    /// Runs a request, asking the user to sign in again if the session has expired.
    @MainActor private func withLogin<T>(_ operation: (OverleafClient) async throws -> T) async throws -> T {
        do { return try await operation(try await ensureClient(interactive: true)) }
        catch OverleafError.notLoggedIn {
            client = nil
            let created = OverleafClient(host: host, cookies: try await OverleafLogin.present(host: host)); client = created
            return try await operation(created)
        }
    }
    /// The account's projects. Without `interactive`, a missing or expired login throws instead of
    /// showing the sign-in window, so the dashboard can check quietly.
    @MainActor func projects(interactive: Bool) async throws -> [OverleafProject] {
        if interactive { return try await withLogin { try await $0.projects() } }
        do { return try await ensureClient(interactive: false).projects() }
        catch OverleafError.notLoggedIn { client = nil; throw OverleafError.notLoggedIn }
    }
    /// Forgets the saved session without touching the open project's link.
    @MainActor func forgetSession() async { teardown(); client = nil; await OverleafLogin.clear(host: host); set(link == nil ? .idle : .signedOut) }
    func signIn() {
        run("登录", alert: true) { [self] in
            _ = try await withLogin { try await $0.projects() }
            workspace.setStatus("已登录 Overleaf")
            if link != nil { connect() } else { refreshChip() }
        }
    }
    func signOut() {
        run("退出登录") { [self] in
            teardown(); client = nil
            await OverleafLogin.clear(host: host)
            set(link == nil ? .idle : .signedOut); workspace.setStatus("已退出 Overleaf 登录")
        }
    }

    // MARK: Lifecycle
    /// Called whenever the workspace opens a folder.
    func projectChanged() {
        teardown(); project = workspace.project
        link = project.flatMap { OverleafLink.load(project: $0) }
        conflicts = 0; set(.idle)
        if link != nil { connect() }
    }
    private func teardown() {
        generation += 1; jobs.values.forEach { $0.cancel() }; jobs.removeAll(); poll?.invalidate(); poll = nil
        socket?.close(); socket = nil; tree = nil; live = nil; joining = nil; presence.removeAll(); threads.removeAll()
        syncing = false; syncQueued = false; retries = 0; popover.close(); refreshOverlays()
    }
    func shutdown() {
        if let live, live.inflight == nil, !live.needsResync, let buffer = workspace.active, buffer.url == live.url, canWrite {
            let ops = OverleafText.splice(from: live.shadow, to: buffer.text)
            if !ops.isEmpty { socket?.emit("applyOtUpdate", [live.docID, ["doc": live.docID, "op": ops.map(\.json), "v": live.version]]) }
        }
        if let link, let project { try? link.save(project: project) }
        teardown()
    }

    private func set(_ status: Status) { self.status = status; refreshChip() }
    private func refreshChip() {
        let others = presence.values.filter { $0.clientID != publicID }.sorted { $0.name < $1.name }
        guard let link else { ui.overleaf.set(title: "Overleaf", color: nil, people: [], tip: "导入、上传或同步 Overleaf 项目"); return }
        let title: String, color: NSColor, tip: String
        switch status {
        case .signedOut: (title, color, tip) = ("未登录", Theme.orange, "点击登录 Overleaf 以继续同步")
        case .connecting: (title, color, tip) = ("连接中", Theme.orange, "正在连接 Overleaf…")
        case .syncing: (title, color, tip) = ("同步中", Theme.orange, "正在与 Overleaf 同步…")
        case .offline(let reason): (title, color, tip) = ("离线", Theme.red, "未连接 Overleaf：\(reason)")
        case .idle, .online:
            if conflicts > 0 { (title, color, tip) = ("\(conflicts) 个冲突", Theme.red, "有文件同时在本地和 Overleaf 被修改，请处理冲突标记后再同步") }
            else {
                let mode = link.mode == .realtime ? "实时同步" : link.mode == .interval ? "每 \(link.intervalMinutes) 分钟同步" : "手动同步"
                let last = link.lastSync.map { " · 上次同步 " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
                (title, color, tip) = (link.mode == .realtime ? "实时" : "已连接", Theme.green, "\(link.name) · \(mode)\(last)" + (canWrite ? "" : " · 只读"))
            }
        }
        ui.overleaf.set(title: title, color: color, people: others, tip: tip)
        if popover.isShown { panel.show(panelModel()) }
    }

    // MARK: Connection
    private func connect() {
        guard let link, socket == nil else { return }
        let token = generation; set(.connecting)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let created = OverleafSocket()
            do {
                let client = try await self.ensureClient(interactive: false)
                created.onEvent = { [weak self, weak created] name, args in if let self, self.socket === created { self.handle(name, args) } }
                created.onClose = { [weak self, weak created] reason in if let self, self.socket === created { self.disconnected(reason) } }
                try await created.connect(client: client, projectID: link.projectID)
                guard self.generation == token, self.socket == nil else { created.close(); return }
                self.socket = created
                // The server answers the connection with `joinProjectResponse`.
                self.after("join", 20) { [weak self] in if self?.tree == nil { self?.disconnected("加入项目超时") } }
            } catch {
                guard self.generation == token else { return }
                if case OverleafError.notLoggedIn = error { self.client = nil; self.set(.signedOut) }
                else { self.set(.offline(error.localizedDescription)); self.scheduleReconnect() }
            }
        }
    }
    private func disconnected(_ reason: String) {
        socket?.close(); socket = nil; tree = nil; live = nil; joining = nil; presence.removeAll(); refreshOverlays()
        set(.offline(reason)); scheduleReconnect()
    }
    private func scheduleReconnect() {
        guard link != nil else { return }
        retries += 1
        after("reconnect", min(120, 4 * pow(2, Double(min(retries, 5))))) { [weak self] in self?.connect() }
    }

    private func handle(_ name: String, _ args: [Any]) {
        func string(_ index: Int) -> String? { args.indices.contains(index) ? args[index] as? String : nil }
        func object(_ index: Int) -> [String: Any]? { args.indices.contains(index) ? args[index] as? [String: Any] : nil }
        switch name {
        case "joinProjectResponse":
            guard let response = object(0), let projectJSON = response["project"] as? [String: Any], let parsed = OverleafTree(project: projectJSON) else { disconnected("无法读取项目结构"); return }
            jobs["join"]?.cancel(); tree = parsed; retries = 0
            publicID = response["publicId"] as? String ?? ""; permissions = response["permissionsLevel"] as? String ?? ""
            if let name = projectJSON["name"] as? String, name != link?.name { link?.name = name; saveLink() }
            if let client { OverleafLogin.store(client.cookies) }
            set(.online)
            socket?.emit("clientTracking.getConnectedUsers") { [weak self] result in
                guard let self, let users = result.dropFirst().first as? [[String: Any]] else { return }
                for user in users { if let person = OverleafPresence(json: user) { self.presence[person.clientID] = person } }
                self.refreshOverlays(); self.refreshChip()
            }
            refreshThreads(); attachActiveDoc(); schedule()
            if link?.mode != .manual { requestSync(after: 0.5) }
        case "connectionRejected":
            let message = object(0)?["message"] as? String ?? "连接被拒绝"
            socket?.close(); socket = nil
            if message.contains("session") || message.contains("not authorized") { client = nil; set(.signedOut) } else { disconnected(message) }
        case "project:access:revoked":
            socket?.close(); socket = nil; tree = nil; live = nil; set(.offline("你对该项目的访问权限已被移除"))
        case "forceDisconnect", "reconnectGracefully": disconnected("服务器要求重新连接")
        case "clientTracking.clientUpdated":
            if let json = object(0), let person = OverleafPresence(json: json) { presence[person.clientID] = person; refreshOverlays(); refreshChip() }
        case "clientTracking.clientDisconnected":
            if let id = string(0) { presence[id] = nil; refreshOverlays(); refreshChip() }
        case "otUpdateApplied": if let update = object(0) { received(update) }
        case "otUpdateError": resync()
        case "reciveNewDoc": if let parent = string(0), let doc = object(1) { tree?.add(doc, kind: .doc, parent: parent); treeChanged() }
        case "reciveNewFile": if let parent = string(0), let file = object(1) { tree?.add(file, kind: .file, parent: parent); treeChanged() }
        case "reciveNewFolder": if let parent = string(0), let folder = object(1) { tree?.add(folder, kind: .folder, parent: parent) }
        case "reciveEntityRename": if let id = string(0), let name = string(1) { tree?.rename(id, to: name); treeChanged() }
        case "reciveEntityMove": if let id = string(0), let folder = string(1) { tree?.move(id, to: folder); treeChanged() }
        case "removeEntity": if let id = string(0) { tree?.remove(id); treeChanged() }
        case "new-comment", "new-comment-thread", "resolve-thread", "reopen-thread", "delete-thread", "edit-message", "delete-message":
            after("threads", 0.6) { [weak self] in self?.refreshThreads() }
        default: break
        }
    }
    private func treeChanged() {
        if let live, tree?.path(of: live.docID) != live.path { detachLive() }
        attachActiveDoc(); remoteChanged()
    }
    private func saveLink() { after("saveLink", 1.5) { [weak self] in if let self, let link = self.link, let project = self.project { try? link.save(project: project) } } }

    // MARK: File sync
    /// (Re)starts the timer behind interval mode and the safety poll of real-time mode.
    private func schedule() {
        poll?.invalidate(); poll = nil
        guard let link, link.mode != .manual else { return }
        let seconds = link.mode == .realtime ? 180 : TimeInterval(max(1, link.intervalMinutes) * 60)
        poll = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in self?.sync(userInitiated: false) }
    }
    private func requestSync(after delay: TimeInterval) {
        // Whole-project downloads are rate limited, so bursts of changes share one sync.
        let wait = max(delay, 10 - Date().timeIntervalSince(lastZip))
        after("sync", wait) { [weak self] in self?.sync(userInitiated: false) }
    }
    /// Another collaborator changed something outside the live document.
    private func remoteChanged() { if link?.mode == .realtime { requestSync(after: 4) } }
    /// The folder changed on disk (editor saves, the agent, Git…).
    func localFilesChanged() {
        guard let link, link.mode == .realtime, let project, socket != nil, !syncing else { return }
        let token = generation, base = link.base, skip = live?.path
        after("localScan", 2.5) { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let local = OverleafFiles.scan(project)
                let changed = Set(local.keys).union(base.keys).contains { $0 != skip && local[$0] != base[$0] }
                DispatchQueue.main.async { if let self, self.generation == token, changed { self.requestSync(after: 0.5) } }
            }
        }
    }
    func sync(userInitiated: Bool) {
        guard link != nil, project != nil else { return }
        if syncing { syncQueued = true; return }
        guard socket != nil, tree != nil else { if userInitiated { workspace.setStatus("正在连接 Overleaf，连接后自动同步"); retries = 0; connect() }; return }
        guard workspace.saveAll() else { return }
        syncing = true; let token = generation
        run("同步失败", alert: userInitiated) { [self] in
            defer { if generation == token { syncing = false; set(socket == nil ? status : .online); if syncQueued { syncQueued = false; requestSync(after: 1) } } }
            set(.syncing)
            try await performSync(token: token, interactive: userInitiated)
        }
    }

    @MainActor private func performSync(token: Int, interactive: Bool) async throws {
        guard let project, let projectID = link?.projectID else { return }
        let client = try await ensureClient(interactive: interactive)
        let archive = try await client.downloadZip(projectID: projectID); lastZip = Date()
        let manager = FileManager.default
        let remoteRoot = manager.temporaryDirectory.appendingPathComponent("BetterTeX-remote-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: remoteRoot); try? manager.removeItem(at: archive) }
        let (remote, local) = try await background { try OverleafFiles.unzip(archive, to: remoteRoot); return (OverleafFiles.scan(remoteRoot), OverleafFiles.scan(project)) }
        guard generation == token, var link, let rootID = tree?.rootID else { return }
        let livePath = live?.path
        let actions = SyncPlanner.plan(local: local, remote: remote, base: link.base).filter { $0.path != livePath }
        var down = 0, up = 0, merged = 0, unresolved = 0, marked = 0, removals: [String] = [], notes: [String] = []
        func localURL(_ path: String) -> URL { project.appendingPathComponent(path) }
        func write(_ data: Data, to path: String) throws {
            try manager.createDirectory(at: localURL(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: localURL(path), options: .atomic)
        }
        func push(_ path: String, _ data: Data) async throws -> Bool {
            guard canWrite else { notes.append("只读权限，未上传 \(path)"); return false }
            if let text = String(data: data, encoding: .utf8), OverleafFiles.isText(path: path, data: data), Merge3.hasMarkers(text) { unresolved += 1; return false }
            try await client.upload(projectID: projectID, rootFolderID: rootID, path: path, data: data); return true
        }
        for action in actions {
            guard generation == token else { return }
            do {
                switch action {
                case .record(let path): link.setBase(project: project, path: path, data: try? Data(contentsOf: localURL(path)))
                case .download(let path):
                    if isDirty(path) { continue }
                    let data = try Data(contentsOf: remoteRoot.appendingPathComponent(path))
                    try write(data, to: path); link.setBase(project: project, path: path, data: data); down += 1
                case .upload(let path):
                    let data = try Data(contentsOf: localURL(path))
                    if try await push(path, data) { link.setBase(project: project, path: path, data: data); up += 1 }
                case .merge(let path):
                    if isDirty(path) { continue }
                    let ours = try Data(contentsOf: localURL(path)), theirs = try Data(contentsOf: remoteRoot.appendingPathComponent(path))
                    guard OverleafFiles.isText(path: path, data: ours), OverleafFiles.isText(path: path, data: theirs),
                          let oursText = String(data: ours, encoding: .utf8), let theirsText = String(data: theirs, encoding: .utf8) else {
                        // Binary files cannot be merged: the local copy wins, Overleaf's history keeps the other.
                        if try await push(path, ours) { link.setBase(project: project, path: path, data: ours); up += 1 }
                        continue
                    }
                    if Merge3.hasMarkers(oursText) { unresolved += 1; continue }
                    let result = Merge3.merge(base: OverleafLink.baseText(project: project, path: path) ?? "", ours: oursText, theirs: theirsText, style: .markers)
                    let data = Data(result.text.utf8)
                    try write(data, to: path)
                    if result.conflicts == 0 { if try await push(path, data) { link.setBase(project: project, path: path, data: data); merged += 1 } }
                    else { link.setBase(project: project, path: path, data: theirs); unresolved += 1; marked += 1; notes.append("\(path) 有 \(result.conflicts) 处冲突，已写入冲突标记") }
                case .deleteLocal(let path):
                    if isDirty(path) { continue }
                    try manager.trashItem(at: localURL(path), resultingItemURL: nil); link.setBase(project: project, path: path, data: nil); down += 1
                case .deleteRemote(let path): removals.append(path)
                }
            } catch OverleafError.notLoggedIn { throw OverleafError.notLoggedIn }
            catch { notes.append("\(action.path)：\(error.localizedDescription)") }
        }
        if !removals.isEmpty, canWrite {
            let alert = NSAlert(); alert.messageText = "从 Overleaf 删除 \(removals.count) 个文件？"
            alert.informativeText = "这些文件已在本地删除，Overleaf 上仍然存在：\n\n" + removals.prefix(12).joined(separator: "\n") + (removals.count > 12 ? "\n…" : "") + "\n\n删除后协作者也将看不到它们（可在 Overleaf 历史记录中找回）。"
            alert.addButton(withTitle: "恢复到本地"); alert.addButton(withTitle: "从 Overleaf 删除"); alert.addButton(withTitle: "暂不处理")
            let choice = alert.runModal()
            for path in removals {
                do {
                    if choice == .alertFirstButtonReturn {
                        let data = try Data(contentsOf: remoteRoot.appendingPathComponent(path)); try write(data, to: path); link.setBase(project: project, path: path, data: data); down += 1
                    } else if choice == .alertSecondButtonReturn, let entity = tree?.entity(atPath: path) {
                        try await client.delete(projectID: projectID, entity: entity); link.setBase(project: project, path: path, data: nil); up += 1
                    }
                } catch { notes.append("\(path)：\(error.localizedDescription)") }
            }
        }
        guard generation == token else { return }
        link.lastSync = Date(); link.mode = self.link?.mode ?? link.mode; link.intervalMinutes = self.link?.intervalMinutes ?? link.intervalMinutes
        self.link = link; try link.save(project: project); conflicts = unresolved
        if !notes.isEmpty { ui.terminal.append("\nOverleaf 同步\n" + notes.joined(separator: "\n") + "\n") }
        if down + merged + marked > 0 { workspace.externalChanges() }
        let parts = [down > 0 ? "↓\(down)" : nil, up > 0 ? "↑\(up)" : nil, merged > 0 ? "合并 \(merged)" : nil, unresolved > 0 ? "\(unresolved) 个冲突待处理" : nil].compactMap { $0 }
        if !parts.isEmpty || interactive { workspace.setStatus("Overleaf 同步完成" + (parts.isEmpty ? " · 已是最新" : " · " + parts.joined(separator: " "))) }
        if unresolved > 0, interactive { ui.showOutput() }
    }

    // MARK: Live document
    /// Joins the document in the active tab so edits flow both ways as they are typed.
    func attachActiveDoc() {
        guard let link, link.mode == .realtime, let socket, socket.isOpen, let tree, let buffer = workspace.active,
              let path = relativePath(buffer.url), let entity = tree.entity(atPath: path), entity.kind == .doc else { detachLive(); refreshOverlays(); return }
        if live?.docID == entity.id || joining == entity.id { return }
        detachLive(); join(docID: entity.id, path: path, url: buffer.url, base: OverleafLink.baseText(project: project!, path: path))
    }
    private func detachLive() {
        joining = nil; jobs["ack"]?.cancel()
        guard let old = live else { return }
        live = nil; socket?.emit("leaveDoc", [old.docID]) { _ in }
    }
    /// `base` is the common ancestor used to reconcile the editor's text with Overleaf's.
    private func join(docID: String, path: String, url: URL, base: String?) {
        joining = docID
        socket?.emit("joinDoc", [docID, ["encodeRanges": true]]) { [weak self] result in
            guard let self, self.joining == docID else { return }
            self.joining = nil
            // (error, lines, version, updates, ranges, type)
            guard result.first == nil || result.first is NSNull, result.count > 2, let lines = result[1] as? [String], let version = result[2] as? Int,
                  (result.count > 5 ? result[5] as? String : nil) ?? "sharejs-text-ot" == "sharejs-text-ot",
                  let buffer = self.workspace.active, buffer.url == url else { self.live = nil; self.refreshOverlays(); return }
            let remote = lines.map(OverleafText.decode).joined(separator: "\n")
            let ranges = (result.count > 4 ? result[4] as? [String: Any] : nil)?["comments"] as? [[String: Any]] ?? []
            self.live = LiveDoc(docID: docID, path: path, url: url, shadow: remote, version: version, comments: ranges.compactMap(CommentRange.init))
            let merged = Merge3.merge(base: base ?? remote, ours: buffer.text, theirs: remote, style: .preferOurs).text
            if merged != buffer.text { self.ui.editor.applyRemote(merged) }
            self.refreshOverlays(); self.flush()
        }
    }
    /// Throws away operation bookkeeping and reconciles against a fresh copy from the server.
    private func resync() {
        guard let old = live, joining == nil else { return }
        jobs["ack"]?.cancel(); old.needsResync = true
        join(docID: old.docID, path: old.path, url: old.url, base: old.shadow)
    }
    /// Called on every local edit of the active document.
    func localEdited() {
        guard live != nil else { return }
        after("flush", 0.25) { [weak self] in self?.flush() }
        refreshOverlays()
    }
    /// Sends the difference between Overleaf's text and the editor's as one operation.
    private func flush() {
        guard let live, live.inflight == nil, !live.needsResync, joining == nil, let buffer = workspace.active, buffer.url == live.url else { return }
        let ops = canWrite ? OverleafText.splice(from: live.shadow, to: buffer.text) : []
        guard !ops.isEmpty else { recordLiveBase(); return }
        send(ops, live)
    }
    private func send(_ ops: [TextOp], _ live: LiveDoc) {
        live.inflight = ops
        socket?.emit("applyOtUpdate", [live.docID, ["doc": live.docID, "op": ops.map(\.json), "v": live.version]]) { [weak self] result in
            if let error = result.first, !(error is NSNull) { self?.resync() }
        }
        after("ack", 10) { [weak self] in if self?.live === live, live.inflight != nil { self?.resync() } }
    }
    private func received(_ update: [String: Any]) {
        guard let doc = update["doc"] as? String else { return }
        guard let live, live.docID == doc else { remoteChanged(); return }
        let version = update["v"] as? Int
        guard let raw = update["op"] as? [[String: Any]] else {
            // The server acknowledged our own operation.
            guard let inflight = live.inflight else { return }
            jobs["ack"]?.cancel()
            guard !live.needsResync, version == live.version, let applied = try? OverleafText.apply(inflight, to: live.shadow) else { resync(); return }
            live.shadow = applied; live.version += 1; live.comments = OverleafText.shift(live.comments, by: inflight); live.inflight = nil
            refreshOverlays(); flush(); return
        }
        // A collaborator's edit. While one of ours is in flight the server reorders them, so reconcile afterwards.
        guard live.inflight == nil else { live.needsResync = true; return }
        let ops = raw.compactMap(TextOp.init)
        guard !live.needsResync, version == live.version, ops.count == raw.count, let next = try? OverleafText.apply(ops, to: live.shadow) else { resync(); return }
        let previous = live.shadow
        live.shadow = next; live.version += 1; live.comments = OverleafText.shift(live.comments, by: ops)
        if let buffer = workspace.active, buffer.url == live.url {
            let target = buffer.text == previous ? next : Merge3.merge(base: previous, ours: buffer.text, theirs: next, style: .preferOurs).text
            if target != buffer.text { ui.editor.applyRemote(target) }
        }
        refreshOverlays(); recordLiveBase()
    }
    /// Once editor, disk and Overleaf agree, remember that state as the file's sync base.
    private func recordLiveBase() {
        guard let live, live.inflight == nil, let project, let buffer = workspace.active, buffer.url == live.url, buffer.text == live.shadow else { return }
        if buffer.dirty { after("liveBase", 1.5) { [weak self] in self?.recordLiveBase() }; return }
        let data = Data(live.shadow.utf8)
        if link?.base[live.path] != OverleafFiles.hash(data) { link?.setBase(project: project, path: live.path, data: data); saveLink() }
    }

    // MARK: Presence and comments
    func selectionChanged() {
        guard socket?.isOpen == true, let buffer = workspace.active, let path = relativePath(buffer.url), let id = live?.docID ?? tree?.entity(atPath: path)?.id else { return }
        after("cursor", 0.35) { [weak self] in
            guard let self, self.workspace.active === buffer else { return }
            let position = OverleafText.rowColumn(of: self.ui.editor.textView.selectedRange().location, in: self.ui.editor.textView.string)
            self.socket?.emit("clientTracking.updatePosition", [["row": position.row, "column": position.column, "doc_id": id]])
        }
    }
    private var activeDocID: String? {
        if let live { return live.docID }
        guard let buffer = workspace.active, let path = relativePath(buffer.url) else { return nil }
        return tree?.entity(atPath: path)?.id
    }
    /// Where open comment threads sit in the editor's current text.
    private func openComments() -> [(range: CommentRange, offset: Int)] {
        guard let live, let buffer = workspace.active, buffer.url == live.url else { return [] }
        let pending = OverleafText.splice(from: live.shadow, to: buffer.text)
        return OverleafText.shift(live.comments.filter { threads[$0.thread]?.resolved != true }, by: pending).sorted { $0.position < $1.position }.map { ($0, $0.position) }
    }
    private func refreshOverlays() {
        let text = ui.editor.textView.string, doc = activeDocID
        ui.editor.textView.remoteCursors = doc == nil ? [] : presence.values.filter { $0.clientID != publicID && $0.docID == doc }.map {
            CodeTextView.RemoteCursor(offset: OverleafText.offset(row: $0.row, column: $0.column, in: text), color: AvatarView.color($0), name: $0.name)
        }
        ui.editor.textView.commentRanges = openComments().map { NSRange(location: $0.range.position, length: $0.range.length) }
        if popover.isShown { panel.show(panelModel()) }
    }
    private func refreshThreads() {
        guard let link, let client else { return }
        let token = generation
        Task { @MainActor [weak self] in
            guard let fetched = try? await client.threads(projectID: link.projectID), let self, self.generation == token else { return }
            self.threads = fetched; self.refreshOverlays()
        }
    }
    private func reply(thread: String, text: String) {
        guard let link else { return }
        run("回复评论", alert: true) { [self] in
            try await withLogin { try await $0.reply(projectID: link.projectID, thread: thread, content: text) }
            refreshThreads()
        }
    }
    private func resolve(thread: String) {
        guard let link, let doc = live?.docID else { return }
        run("解决评论", alert: true) { [self] in
            try await withLogin { try await $0.setResolved(true, projectID: link.projectID, docID: doc, thread: thread) }
            threads[thread]?.resolved = true; refreshOverlays()
        }
    }
    private func addComment(_ text: String) {
        guard let link, let live, canWrite, let buffer = workspace.active, buffer.url == live.url else { return }
        let selection = ui.editor.textView.selectedRange(), content = buffer.text as NSString
        guard selection.length > 0, NSMaxRange(selection) <= content.length else { workspace.setStatus("请先在编辑器中选中要评论的文字"); return }
        guard live.inflight == nil, !live.needsResync, buffer.text == live.shadow else { flush(); workspace.setStatus("正在同步刚才的修改，请稍后再添加评论"); return }
        let thread = OverleafText.newObjectID(), quoted = content.substring(with: selection)
        run("添加评论", alert: true) { [self] in
            try await withLogin { try await $0.reply(projectID: link.projectID, thread: thread, content: text) }
            guard self.live === live, live.inflight == nil, buffer.text == live.shadow else { throw OverleafError.message("文档在提交评论时发生了变化，请重试。") }
            send([TextOp(.comment, at: selection.location, quoted, thread: thread)], live)
            refreshThreads()
        }
    }
    private func panelModel() -> OverleafPanelModel {
        var model = OverleafPanelModel()
        model.title = link?.name ?? "Overleaf"; model.status = ui.overleaf.toolTip ?? ""
        model.people = presence.values.sorted { $0.name < $1.name }.map { person in
            let path = person.docID.flatMap { tree?.path(of: $0) }
            return .init(presence: person, place: path.map { "\(($0 as NSString).lastPathComponent):\(person.row + 1)" } ?? "", isSelf: person.clientID == publicID)
        }
        model.comments = openComments().compactMap { item in threads[item.range.thread].map { .init(thread: $0, quote: item.range.text, offset: item.offset) } }
        model.canComment = live != nil && canWrite
        model.commentHint = live == nil ? (link?.mode == .realtime ? "当前文件不是 Overleaf 文档，或尚未连接。" : "切换到实时同步后可查看和回复评论。") : "这个文件还没有未解决的评论。"
        return model
    }

    // MARK: Menu
    func showMenu(from view: NSView) {
        let menu = NSMenu(); menu.autoenablesItems = false
        if let link {
            let header = NSMenuItem(title: link.name, action: nil, keyEquivalent: ""); header.isEnabled = false; menu.addItem(header)
            if case .signedOut = status { menu.addItem(ClosureMenuItem("登录 Overleaf…", symbol: "person.crop.circle") { [weak self] in self?.signIn() }) }
            menu.addItem(ClosureMenuItem("立即同步", symbol: "arrow.triangle.2.circlepath") { [weak self] in self?.sync(userInitiated: true) })
            menu.addItem(ClosureMenuItem("协作者与评论", symbol: "bubble.left.and.bubble.right") { [weak self] in self?.showPanel(from: view) })
            menu.addItem(ClosureMenuItem("邀请合作者…", symbol: "person.badge.plus") { [weak self] in self?.invite() })
            menu.addItem(.separator())
            let modes = NSMenu()
            modes.addItem(ClosureMenuItem("实时同步", checked: link.mode == .realtime) { [weak self] in self?.setMode(.realtime, minutes: link.intervalMinutes) })
            for minutes in [1, 5, 15, 60] {
                modes.addItem(ClosureMenuItem(minutes == 60 ? "每小时" : "每 \(minutes) 分钟", checked: link.mode == .interval && link.intervalMinutes == minutes) { [weak self] in self?.setMode(.interval, minutes: minutes) })
            }
            modes.addItem(ClosureMenuItem("仅手动同步", checked: link.mode == .manual) { [weak self] in self?.setMode(.manual, minutes: link.intervalMinutes) })
            let mode = NSMenuItem(title: "同步方式", action: nil, keyEquivalent: ""); mode.submenu = modes; mode.image = NSImage(systemSymbolName: "clock.arrow.2.circlepath", accessibilityDescription: nil); menu.addItem(mode)
            menu.addItem(ClosureMenuItem("在浏览器中打开项目", symbol: "safari") { [weak self] in
                if let self, let url = URL(string: self.host.absoluteString + "/project/" + link.projectID) { NSWorkspace.shared.open(url) }
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("取消与 Overleaf 的关联", symbol: "link.badge.plus") { [weak self] in self?.unlink() })
        } else {
            menu.addItem(ClosureMenuItem("从 Overleaf 导入项目…", symbol: "square.and.arrow.down") { [weak self] in self?.importProject() })
            menu.addItem(ClosureMenuItem("把当前项目上传到 Overleaf…", symbol: "square.and.arrow.up", enabled: project != nil) { [weak self] in self?.exportProject() })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("退出 Overleaf 登录", symbol: "rectangle.portrait.and.arrow.right") { [weak self] in self?.signOut() })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 6), in: view)
    }
    private func showPanel(from view: NSView) {
        refreshThreads(); panel.show(panelModel())
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }
    private func setMode(_ mode: OverleafLink.Mode, minutes: Int) {
        guard let project else { return }
        link?.mode = mode; link?.intervalMinutes = minutes; try? link?.save(project: project)
        schedule(); attachActiveDoc(); refreshChip()
        if mode != .manual { sync(userInitiated: false) }
    }
    private func unlink() {
        guard let project, let link else { return }
        let alert = NSAlert(); alert.messageText = "取消与「\(link.name)」的关联？"
        alert.informativeText = "本地文件和 Overleaf 上的项目都会保留，只是不再同步。"
        alert.addButton(withTitle: "取消关联"); alert.addButton(withTitle: "保留")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        teardown(); OverleafLink.remove(project: project); self.link = nil; set(.idle)
    }

    // MARK: Import, export, invitations
    /// Downloads an Overleaf project into a new local folder and opens it, linked.
    func importProject() {
        run("导入失败", alert: true) { [self] in
            let projects = try await withLogin { try await $0.projects() }
            guard let chosen = ProjectPicker.choose(projects, title: "从 Overleaf 导入项目", confirm: "导入") else { return }
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.prompt = "导入到这里"; panel.message = "选择存放「\(chosen.name)」的位置，将在其中新建同名文件夹。"
            guard panel.runModal() == .OK, let parent = panel.url else { return }
            try await download(chosen, into: parent)
        }
    }
    /// Downloads one Overleaf project into a new folder under `parent`, links it and opens it.
    @MainActor func download(_ chosen: OverleafProject, into parent: URL) async throws {
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let name = chosen.name.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
            var target = parent.appendingPathComponent(name, isDirectory: true); var suffix = 1
            while FileManager.default.fileExists(atPath: target.path) { suffix += 1; target = parent.appendingPathComponent("\(name) \(suffix)", isDirectory: true) }
            workspace.setStatus("正在从 Overleaf 下载「\(chosen.name)」…")
            let archive = try await withLogin { try await $0.downloadZip(projectID: chosen.id) }
            defer { try? FileManager.default.removeItem(at: archive) }
            let files = try await background { () -> [String] in try OverleafFiles.unzip(archive, to: target); return Array(OverleafFiles.scan(target).keys) }
            var link = OverleafLink(host: host.absoluteString, projectID: chosen.id, name: chosen.name)
            for path in files { link.setBase(project: target, path: path, data: try? Data(contentsOf: target.appendingPathComponent(path))) }
            link.lastSync = Date(); try link.save(project: target)
            guard workspace.confirmSwitch() else { workspace.setStatus("已导入到 \(target.path)"); return }
            workspace.loadProject(target); workspace.setStatus("已从 Overleaf 导入「\(chosen.name)」")
        }
    }
    /// Uploads the open folder as a new Overleaf project and keeps the two linked.
    func exportProject() {
        guard let project, link == nil else { return }
        let alert = NSAlert(); alert.messageText = "把当前项目上传到 Overleaf"
        alert.informativeText = "源文件会作为一个新项目上传到你的 Overleaf 账户并保持同步。隐藏文件、.bettertex 和编译产物不会上传。"
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); name.stringValue = project.lastPathComponent; name.placeholderString = "Overleaf 项目名称"
        alert.accessoryView = name; alert.addButton(withTitle: "上传"); alert.addButton(withTitle: "取消"); alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, workspace.saveAll() else { return }
        run("上传失败", alert: true) { [self] in
            workspace.setStatus("正在上传到 Overleaf…")
            let archive = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeX-upload-\(UUID().uuidString).zip")
            defer { try? FileManager.default.removeItem(at: archive) }
            let files = try await background { () -> [String] in try OverleafFiles.zip(project: project, to: archive); return Array(OverleafFiles.scan(project).keys) }
            let id = try await withLogin { try await $0.createProject(name: title, archive: archive) }
            guard self.project == project else { return }
            var link = OverleafLink(host: host.absoluteString, projectID: id, name: title)
            for path in files { link.setBase(project: project, path: path, data: try? Data(contentsOf: project.appendingPathComponent(path))) }
            link.lastSync = Date(); try link.save(project: project)
            projectChanged(); workspace.setStatus("已上传到 Overleaf「\(title)」并建立关联")
        }
    }
    func invite() {
        guard let link else { workspace.setStatus("请先把项目上传到 Overleaf 或从 Overleaf 导入"); return }
        run("邀请失败", alert: true) { [self] in
            let members = (try? await withLogin { try await $0.members(projectID: link.projectID) }) ?? []
            let roles = [("可编辑", "readAndWrite"), ("仅查看", "readOnly"), ("审阅（仅评论与修订）", "review")]
            let labels = ["owner": "所有者", "readAndWrite": "可编辑", "readOnly": "仅查看", "review": "审阅"]
            let alert = NSAlert(); alert.messageText = "邀请合作者加入「\(link.name)」"
            let current = members.map { member -> String in
                let pending = member.role.hasPrefix("pending:"); let role = pending ? String(member.role.dropFirst(8)) : member.role
                return "· \(member.name) — \(labels[role] ?? role)" + (pending ? "（等待接受）" : "")
            }
            alert.informativeText = "Overleaf 会向对方发送邀请邮件。" + (current.isEmpty ? "" : "\n\n当前成员：\n" + current.joined(separator: "\n"))
            let email = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24)); email.placeholderString = "对方的邮箱地址"
            let role = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26)); role.addItems(withTitles: roles.map(\.0))
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56)); box.addSubview(email); box.addSubview(role)
            alert.accessoryView = box; alert.addButton(withTitle: "发送邀请"); alert.addButton(withTitle: "取消"); alert.window.initialFirstResponder = email
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let address = email.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard address.contains("@") else { throw OverleafError.message("请输入有效的邮箱地址。") }
            try await withLogin { try await $0.invite(projectID: link.projectID, email: address, privileges: roles[max(0, role.indexOfSelectedItem)].1) }
            workspace.setStatus("已向 \(address) 发送 Overleaf 邀请")
        }
    }
}
