import AppKit
import BetterTeXCore

final class WorkspaceController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let ui = WorkspaceView()
    var project: URL?
    var buffers: [EditorBuffer] = []
    var active: EditorBuffer?
    var tools: Toolchain?
    var compiler = TeXCompiler()
    private var mainPromptedFor: String?
    var building = false
    var buildPending = false
    /// Fingerprint of the inputs of the last build, so automatic triggers never repeat it.
    var lastBuildSignature: String?
    /// Per-file digests reused between fingerprints, so only changed files are read again.
    let signatureCache = BuildSignatureCache()
    /// How long the last build took; slow documents wait a little longer before building automatically.
    var lastBuildSeconds: TimeInterval?
    /// The fingerprint is being computed off the main thread; a build is about to start.
    var preparingBuild = false
    /// Brace and environment balance of each open TeX file when it last built (or was opened).
    /// While an edit leaves a file unbalanced compared to that, the user is mid-construct and
    /// automatic builds wait instead of failing on a half-typed `\begin{…}` or `{`.
    var settledBalance: [URL: TeXBalance] = [:]
    /// Problems of the most recent build, shown in the editor of whichever file they belong to.
    var buildErrors: [TeXDiagnostic] = []
    /// Labels, citation keys, macros and paths offered by the editor's completion list.
    var completionIndex = ProjectIndex()
    private var indexJob: DispatchWorkItem?
    var buildWarnings: [TeXWarning] = []
    /// Every warning line of the most recent build, listed when the status bar count is clicked.
    var buildWarningMessages: [String] = []
    var gitBusy = false
    var compiledPDF: URL?
    var compiledRoot: URL?
    /// The sources as the last successful build read them; edits since then are diffed against it so SyncTeX lines still land.
    var compiledSnapshot: SourceSnapshot?
    /// Tabs closed most recently first, offered again once every tab is closed.
    var recentlyClosed: [URL] = []
    var generation = UUID()
    var saveJob: DispatchWorkItem?
    var compileJob: DispatchWorkItem?
    let watcher = ProjectWatcher()
    var conflicts = Set<URL>()
    var resolvingConflict = false
    private(set) lazy var overleaf = OverleafController(workspace: self)

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "BetterTeX"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden; window.backgroundColor = Theme.base
        // An empty unified toolbar gives the title bar its taller height and centres the traffic lights.
        let toolbar = NSToolbar(identifier: "BetterTeXChrome"); toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar; window.toolbarStyle = .unified
        window.minSize = NSSize(width: 820, height: 560); window.isReleasedWhenClosed = false
        let contentController = NSViewController(); contentController.view = ui; contentController.addChild(ui.mainSplit)
        window.contentViewController = contentController; window.delegate = self; window.center(); window.setFrameAutosaveName("BetterTeXWorkspace")
        ui.onBuild = { [weak self] in self?.buildClicked() }
        ui.onPush = { [weak self] in self?.git(push: true) }
        ui.onPull = { [weak self] in self?.git(push: false) }
        ui.onOverleaf = { [weak self] in self?.overleaf.showMenu(from: $0) }
        ui.onAuto = { [weak self] enabled in
            UserDefaults.standard.set(enabled, forKey: "autoBuild")
            if enabled { self?.scheduleBuild() } else { self?.compileJob?.cancel(); self?.buildPending = false }
        }
        if UserDefaults.standard.object(forKey: "autoBuild") != nil { ui.autoBuildEnabled = UserDefaults.standard.bool(forKey: "autoBuild") }
        ui.explorer.onOpen = { [weak self] in self?.openFile($0) }
        ui.explorer.onNew = { [weak self] in self?.newFile() }
        ui.explorer.onCloseProject = { [weak self] in self?.closeProject() }
        ui.editor.completions = { [weak self] request in
            guard let self else { return [] }
            var index = self.completionIndex
            // Labels typed since the last save come straight from the editor.
            if request.kind == .reference, let active = self.active {
                let name = active.url.lastPathComponent
                index.labels = index.labels.filter { $0.detail != name } + ProjectIndex.labels(in: active.text, file: name)
            }
            return Completer.items(for: request, index: index)
        }
        ui.welcome.onOpen = { [weak self] in self?.openFolder() }
        ui.welcome.onClone = { [weak self] in self?.cloneRepository() }
        ui.welcome.onSample = { [weak self] in
            guard let self else { return }
            do { self.loadProject(try SampleProject.create()) } catch { self.error(error.localizedDescription) }
        }
        ui.welcome.onRecent = { [weak self] url in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: url.path) { self.loadProject(url) }
            else { self.forgetRecent(url); self.refreshDashboard(); self.error(L10n.tr("找不到「\(url.path)」，它可能已被移动或删除。")) }
        }
        ui.welcome.onForget = { [weak self] url in self?.forgetRecent(url); self?.refreshDashboard() }
        ui.welcome.onRefresh = { [weak self] in self?.refreshDashboard() }
        ui.welcome.onSignIn = { [weak self] in self?.loadOverleafProjects(interactive: true) }
        ui.welcome.onSignOut = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.overleaf.forgetSession(); self.ui.welcome.setOverleaf(.signedOut); self.setStatus(L10n.tr("已退出 Overleaf 登录")) }
        }
        ui.welcome.onDownload = { [weak self] in self?.downloadOverleaf($0) }
        ui.onHome = { [weak self] in self?.closeProject() }
        ui.explorer.onJump = { [weak self] in self?.ui.editor.goTo(line: $0) }
        ui.onOpenFile = { [weak self] in self?.openFile($0) }
        ui.editor.onOutline = { [weak self] items in
            guard let self else { return }
            self.ui.explorer.setOutline(items, cursorLine: self.ui.editor.lineColumn.0)
            self.ui.editor.setBreadcrumb(section: self.ui.explorer.currentOutlineTitle)
        }
        ui.editor.onChange = { [weak self] in self?.edited($0) }
        NotificationCenter.default.addObserver(forName: GrammarPreferences.changed, object: nil, queue: .main) { [weak self] _ in self?.updateGrammar() }
        updateGrammar()
        ui.editor.onSelectTab = { [weak self] in self?.openFile($0) }
        ui.editor.onCloseTab = { [weak self] in self?.closeTab($0) }
        ui.editor.onSelection = { [weak self] line, col in
            guard let self else { return }
            self.ui.position.stringValue = "Ln \(line), Col \(col)"
            self.overleaf.selectionChanged()
            self.ui.explorer.updateOutline(cursorLine: line); self.ui.editor.setBreadcrumb(section: self.ui.explorer.currentOutlineTitle)
            // Mirror the selection in the Agent composer's context chip.
            let text = self.ui.editor.textView.string as NSString; let range = self.ui.editor.textView.selectedRange()
            if range.length > 0, NSMaxRange(range) <= text.length {
                let selected = text.substring(with: range)
                let breaks = selected.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } - (selected.hasSuffix("\n") ? 1 : 0)
                self.ui.terminal.contextLines = line...(line + max(0, breaks))
            } else { self.ui.terminal.contextLines = nil }
        }
        ui.editor.textView.onSync = { [weak self] in self?.forwardSync() }
        ui.editor.emptyState.onOpen = { [weak self] in self?.openFile($0) }
        ui.editor.emptyState.onNew = { [weak self] in self?.newFile() }
        ui.editor.emptyState.onSearch = { [weak self] in self?.ui.search.focus() }
        ui.editor.onInsertImage = { [weak self] in self?.pickImage() }
        ui.editor.textView.onDropImages = { [weak self] in self?.insertImages($0) }
        ui.editor.textView.onPasteImage = { [weak self] in self?.insertPastedImage($0) }
        ui.editor.textView.sourceContext = { [weak self] in self?.editorContext() }
        ui.editor.textView.onAttachContext = { [weak self] context in
            guard let self else { return }
            self.ui.showAgent(); self.ui.terminal.attach(context)
        }
        ui.editor.textView.onProofread = { [weak self] context in
            guard let self else { return }
            self.ui.showAgent(); self.ui.terminal.proofread(context)
        }
        ui.preview.pdfView.onInverse = { [weak self] in self?.inverseSync(page: $0, x: $1, y: $2) }
        ui.preview.onExport = { [weak self] in self?.exportPDF() }
        ui.preview.onReveal = { [weak self] in self?.forwardSync() }
        ui.editor.textView.onRevealInPDF = { [weak self] in self?.forwardSync() }
        ui.onShowTools = { [weak self] in self?.showTools() }
        ui.onDetectTools = { [weak self] in self?.detectTools() }
        ui.onShowProblems = { [weak self] errors, anchor in self?.showProblems(errors: errors, anchor: anchor) }
        ui.terminal.onError = { [weak self] in self?.error($0) }
        ui.terminal.onOpenFile = { [weak self] in self?.openFile($0) }
        ui.terminal.onOpenLocation = { [weak self] in self?.open($0) }
        ui.terminal.currentContext = { [weak self] in self?.editorContext() }
        ui.terminal.onDiagnostic = { [weak self] path, line in
            guard let self, let root = self.compiledRoot ?? self.active?.url else { return }
            self.openFile(URL(fileURLWithPath: path, relativeTo: root.deletingLastPathComponent()).standardizedFileURL, line: line)
        }
        watcher.onChange = { [weak self] in self?.externalChanges() }
    }
    private func editorContext() -> AgentSourceContext? {
        guard let file = active?.url else { return nil }
        let filePath = file.resolvingSymlinksInPath().path
        let prefix = (project?.resolvingSymlinksInPath().path ?? "") + "/"
        let path = filePath.hasPrefix(prefix) ? String(filePath.dropFirst(prefix.count)) : filePath
        return AgentSourceContext(file: path, source: ui.editor.textView.string, range: ui.editor.textView.selectedRange())
    }
    /// Keeps the title bar content clear of the traffic lights, which hide in full screen.
    func positionTrafficLights() {
        let fullScreen = window.styleMask.contains(.fullScreen); ui.setFullScreen(fullScreen)
    }
    func windowDidResize(_ notification: Notification) { positionTrafficLights() }
    // In full screen the system draws the (empty) toolbar as an opaque strip over the custom
    // title bar, so it is hidden there and restored when leaving.
    func windowWillEnterFullScreen(_ notification: Notification) { window.toolbar?.isVisible = false }
    func windowDidEnterFullScreen(_ notification: Notification) { window.toolbar?.isVisible = false; positionTrafficLights() }
    func windowWillExitFullScreen(_ notification: Notification) { window.toolbar?.isVisible = true }
    func windowDidExitFullScreen(_ notification: Notification) { window.toolbar?.isVisible = true; positionTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { positionTrafficLights(); refreshGitMarkers() }
    // MARK: Images
    func pickImage() {
        guard active != nil else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.directoryURL = project
        panel.allowedFileTypes = Array(CodeTextView.imageExtensions); panel.prompt = L10n.tr("插入"); panel.message = L10n.tr("选择要插入的图片；项目外的文件会拷贝到 figures/。")
        panel.beginSheetModal(for: window) { [weak self] response in if response == .OK { self?.insertImages(panel.urls) } }
    }
    /// Inserts a figure for each image, copying files from outside the project into `figures/`.
    func insertImages(_ urls: [URL]) {
        guard let project, let active else { return }
        let manager = FileManager.default; var copied = 0
        let rootDirectory = ((try? TeXProject.root(active: active.url, project: project))?.deletingLastPathComponent() ?? project).standardizedFileURL
        do {
            for url in urls {
                var file = url.standardizedFileURL
                if !file.path.hasPrefix(project.path + "/") {
                    let folder = project.appendingPathComponent("figures", isDirectory: true)
                    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                    var target = folder.appendingPathComponent(file.lastPathComponent); var suffix = 1
                    while manager.fileExists(atPath: target.path) {
                        suffix += 1; target = folder.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent)-\(suffix).\(file.pathExtension)")
                    }
                    try manager.copyItem(at: file, to: target); file = target; copied += 1
                }
                let base = file.path.hasPrefix(rootDirectory.path + "/") ? rootDirectory : project
                let relative = String(file.path.dropFirst(base.path.count + 1))
                let label = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "[^A-Za-z0-9-]+", with: "-", options: .regularExpression)
                ui.editor.insertFigure(path: relative, label: label)
            }
        } catch { self.error(error.localizedDescription); return }
        let package = ui.editor.ensureGraphicx()
        setStatus(L10n.tr("已插入 \(urls.count) 张图片") + (copied > 0 ? L10n.tr(" · 已拷贝到 figures/") : "") + (package == true ? L10n.tr(" · 已添加 graphicx 宏包") : package == nil ? L10n.tr(" · 请在主文档加入 \\usepackage{graphicx}") : ""))
        ui.explorer.refresh()
    }
    func insertPastedImage(_ data: Data) {
        guard let project else { return }
        let folder = project.appendingPathComponent("figures", isDirectory: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let target = folder.appendingPathComponent("pasted-\(formatter.string(from: Date())).png")
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); try data.write(to: target); insertImages([target]) }
        catch { self.error(error.localizedDescription) }
    }
    func exportPDF() {
        guard let pdf = compiledPDF else { setStatus(L10n.tr("请先编译文档，再导出 PDF")); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = pdf.lastPathComponent; panel.directoryURL = project; panel.title = L10n.tr("导出 PDF")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let target = panel.url else { return }
            do { if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }; try FileManager.default.copyItem(at: pdf, to: target); self?.setStatus(L10n.tr("已导出 \(target.lastPathComponent)")) }
            catch { self?.error(error.localizedDescription) }
        }
    }
    func show() {
        window.makeKeyAndOrderFront(nil); positionTrafficLights()
        DispatchQueue.main.async { [weak self] in self?.ui.initialLayout() }
        #if DEBUG
        // Open straight to the dashboard without touching the saved state (for interface checks).
        if ProcessInfo.processInfo.environment["BETTERTEX_START"] == "dashboard" { showStartPage(); detectTools(); return }
        #endif
        // Reopen the last project; on first launch, or after closing a project, show the dashboard.
        if let last = UserDefaults.standard.string(forKey: "lastProject"), FileManager.default.fileExists(atPath: last) { loadProject(URL(fileURLWithPath: last)) }
        else { showStartPage() }
        detectTools()
    }
    func detectTools() {
        setStatus(L10n.tr("正在检测本机工具…"))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tools = Toolchain.discover()
            DispatchQueue.main.async {
                guard let self else { return }; self.tools = tools
                if let project = self.project { self.ui.terminal.configure(project: project, tools: tools) }
                let engines = ["pdflatex", "xelatex", "lualatex"].filter { tools[$0] != nil }
                self.ui.setTools(engines: engines.count, syncTeX: tools["synctex"] != nil)
                self.setStatus(engines.isEmpty ? L10n.tr("请安装本机 TeX 发行版") : L10n.tr("本机工具就绪"))
                self.refreshGit(); if self.ui.autoBuildEnabled { self.scheduleBuild() }
            }
        }
    }
    func updateGrammar() { ui.editor.grammarEnabled = GrammarPreferences.enabled() }
    // MARK: Opening and closing projects
    var recentProjects: [URL] { (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []).map { URL(fileURLWithPath: $0) } }
    /// When each known project was last opened, by path.
    private var recentDates: [String: Double] { UserDefaults.standard.dictionary(forKey: "recentProjectDates") as? [String: Double] ?? [:] }
    private func rememberRecent(_ url: URL) {
        let paths = Array(([url.path] + recentProjects.map(\.path).filter { $0 != url.path }).prefix(200))
        var dates = recentDates.filter { paths.contains($0.key) }; dates[url.path] = Date().timeIntervalSince1970
        UserDefaults.standard.set(paths, forKey: "recentProjects"); UserDefaults.standard.set(dates, forKey: "recentProjectDates")
    }
    private func forgetRecent(_ url: URL) { UserDefaults.standard.set(recentProjects.map(\.path).filter { $0 != url.path }, forKey: "recentProjects") }
    /// Where projects downloaded from the dashboard are kept.
    var projectsFolder: URL {
        UserDefaults.standard.string(forKey: "projectsFolder").map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BetterTeX", isDirectory: true)
    }

    // MARK: Project dashboard
    /// Reloads the dashboard: local projects at once, Overleaf projects when a saved login exists.
    func refreshDashboard() {
        let dates = recentDates
        let known = recentProjects.filter { FileManager.default.fileExists(atPath: $0.path) }
        let entries = known.map { LocalProject(url: $0, opened: dates[$0.path].map(Date.init(timeIntervalSince1970:)), link: OverleafLink.load(project: $0)) }
        ui.welcome.setLocal(entries)
        // Modification times need a walk through each folder, so they arrive a moment later.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let dated = entries.map { entry -> LocalProject in var copy = entry; copy.modified = Self.lastModified(entry.url); return copy }
            DispatchQueue.main.async { guard let self, self.project == nil else { return }; self.ui.welcome.setLocal(dated) }
        }
        loadOverleafProjects(interactive: false)
    }
    /// The newest modification time among a project's own files; build output and hidden files are ignored.
    static func lastModified(_ project: URL) -> Date? {
        let skipped: Set<String> = [".bettertex", "node_modules", "build", "dist", "__pycache__"]
        guard let walker = FileManager.default.enumerator(at: project, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        var newest: Date?; var visited = 0
        while let url = walker.nextObject() as? URL {
            visited += 1; if visited > 5000 { break }
            if skipped.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]), values.isDirectory != true, let date = values.contentModificationDate else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        return newest
    }
    private func loadOverleafProjects(interactive: Bool) {
        ui.welcome.setOverleaf(.loading)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { self.ui.welcome.setOverleaf(.signedIn(try await self.overleaf.projects(interactive: interactive))); if interactive { self.setStatus(L10n.tr("已登录 Overleaf")) } }
            catch OverleafError.notLoggedIn { self.ui.welcome.setOverleaf(.signedOut) }
            catch { self.ui.welcome.setOverleaf(interactive ? .signedOut : .failed(error.localizedDescription)); if interactive { self.setStatus(error.localizedDescription) } }
        }
    }
    /// Downloads an Overleaf project into the projects folder and opens it.
    private func downloadOverleaf(_ chosen: OverleafProject) {
        ui.welcome.setProgress(L10n.tr("正在下载「\(chosen.name)」…"))
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.overleaf.download(chosen, into: self.projectsFolder) }
            catch { self.error(L10n.tr("下载失败：\(error.localizedDescription)")) }
            self.ui.welcome.setProgress(nil)
        }
    }
    /// Several files have `\\documentclass`: let the user pick which one this project builds, and remember it.
    private func chooseMain(from candidates: [URL], project: URL) {
        guard let window = ui.window, window.attachedSheet == nil else { return }
        mainPromptedFor = project.path
        let base = project.standardizedFileURL.path + "/"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        for url in candidates {
            popup.addItem(withTitle: url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.path)
        }
        let alert = NSAlert(); alert.messageText = L10n.tr("选择要编译的主文件")
        alert.informativeText = L10n.tr("此项目有多个含 \\documentclass 的文件。BetterTeX 会记住你的选择；打开其他主文件再编译，或在子文件首行添加 % !TeX root，可以编译别的文件。")
        alert.accessoryView = popup; alert.addButton(withTitle: L10n.tr("编译")); alert.addButton(withTitle: L10n.tr("取消"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.project?.path == project.path else { return }
            guard response == .alertFirstButtonReturn, candidates.indices.contains(popup.indexOfSelectedItem) else {
                self.setStatus(AmbiguousMainError(candidates: candidates).localizedDescription); return
            }
            TeXProject.setChosenMain(candidates[popup.indexOfSelectedItem], for: project)
            self.build()
        }
    }
    /// Stops everything tied to the open project: builds, timers, the watcher, terminals and buffers.
    private func resetWorkspace() {
        generation = UUID(); saveJob?.cancel(); compileJob?.cancel(); compiler.runner.cancel(); compiler = TeXCompiler()
        building = false; buildPending = false; preparingBuild = false; gitBusy = false; ui.setBuilding(false); ui.activity = .idle
        lastBuildSeconds = nil; settledBalance = [:]; signatureCache.reset(); recentlyClosed = []
        watcher.stop(); ui.terminal.stopAll(); buffers.removeAll(); active = nil; conflicts.removeAll()
    }
    /// Closes the project and returns to the start page. Files are saved first; nothing is deleted.
    func closeProject() {
        guard project != nil else { return }
        guard saveAll() else { return }
        if !ui.terminal.terminals.isEmpty {
            let alert = NSAlert(); alert.messageText = L10n.tr("关闭项目并结束终端会话？"); alert.informativeText = L10n.tr("运行中的 Codex、Claude 和 Shell 会话将停止。文件修改已经保存。"); alert.addButton(withTitle: L10n.tr("关闭项目")); alert.addButton(withTitle: L10n.tr("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        resetWorkspace(); showStartPage()
        UserDefaults.standard.set("", forKey: "lastProject")
    }
    private func showStartPage() {
        project = nil; compiledPDF = nil; compiledRoot = nil; compiledSnapshot = nil; lastBuildSignature = nil; buildErrors = []; buildWarnings = []; buildWarningMessages = []; ui.preview.clear()
        window.title = "BetterTeX"; ui.setTitle(project: L10n.tr("未打开项目"), file: nil); ui.projectURL = nil; ui.setBranch(""); ui.terminal.contextFile = nil; ui.terminal.project = nil
        ui.explorer.unload(); ui.editor.clear(); ui.editor.textView.isEditable = false; refreshTabs()
        overleaf.projectChanged(); setStatus(L10n.tr("未打开项目"))
        ui.welcome.isHidden = false; refreshDashboard()
    }
    func loadProject(_ url: URL) {
        resetWorkspace(); ui.welcome.isHidden = true; rememberRecent(url.standardizedFileURL)
        project = url.standardizedFileURL; compiledPDF = nil; compiledRoot = nil; compiledSnapshot = nil; lastBuildSignature = nil; buildErrors = []; buildWarnings = []; buildWarningMessages = []; ui.preview.clear()
        window.title = url.lastPathComponent; ui.setTitle(project: url.lastPathComponent, file: nil); ui.projectURL = url.standardizedFileURL; ui.setBranch(""); ui.terminal.contextFile = nil
        ui.explorer.load(url); ui.editor.clear(); ui.editor.textView.isEditable = false; refreshTabs()
        if let tools { ui.terminal.configure(project: url, tools: tools) }
        UserDefaults.standard.set(url.path, forKey: "lastProject")
        let files = TeXProject.sourceFiles(in: url)
        if let main = files.first(where: { $0.lastPathComponent == "main.tex" }) ?? files.first { openFile(main) } else { showEmptyEditor() }
        watcher.start(url); refreshGit()
        if tools != nil, ui.autoBuildEnabled { scheduleBuild() }
        overleaf.projectChanged(); completionIndex = ProjectIndex(); refreshCompletionIndex()
    }
    /// Asks before replacing a workspace that still has terminal sessions running.
    func confirmSwitch() -> Bool {
        guard saveAll() else { return false }
        guard !ui.terminal.terminals.isEmpty else { return true }
        let alert = NSAlert(); alert.messageText = L10n.tr("切换工作区并结束当前终端会话？"); alert.informativeText = L10n.tr("Codex、Claude 和 Shell 会话会关闭，新会话将在新目录启动。"); alert.addButton(withTitle: L10n.tr("切换")); alert.addButton(withTitle: L10n.tr("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    @objc func openFolder() {
        guard saveAll() else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = L10n.tr("打开工作区"); panel.directoryURL = project
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if !self.ui.terminal.terminals.isEmpty {
                let alert = NSAlert(); alert.messageText = L10n.tr("切换工作区并结束当前终端会话？"); alert.informativeText = L10n.tr("Codex、Claude 和 Shell 会话会关闭，新会话将在新目录启动。"); alert.addButton(withTitle: L10n.tr("切换")); alert.addButton(withTitle: L10n.tr("取消"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            self.loadProject(url)
        }
    }
    func openFile(_ url: URL, line: Int? = nil, column: Int = 0) {
        if url.pathExtension.lowercased() == "pdf" { compiledPDF = nil; compiledRoot = nil; ui.preview.load(url); return }
        if let active { active.selection = ui.editor.textView.selectedRange() }
        do {
            let buffer: EditorBuffer
            if let existing = buffers.first(where: { $0.url == url }) { buffer = existing }
            else { buffer = try EditorBuffer(url: url); buffers.append(buffer); settle(buffer) }
            active = buffer; ui.editor.textView.isEditable = true
            ui.editor.load(buffer, project: project ?? url.deletingLastPathComponent()); refreshTabs(); ui.explorer.reveal(url)
            let root = project ?? url.deletingLastPathComponent()
            ui.setTitle(project: root.lastPathComponent, file: url.lastPathComponent)
            ui.terminal.contextFile = editorContext()?.file
            if let line { ui.editor.goTo(line: line, column: column) }
            overleaf.attachActiveDoc(); ui.editor.setGitChanges([]); refreshGitMarkers(); refreshProblems()
        } catch { self.error(error.localizedDescription) }
    }
    func closeTab(_ url: URL) {
        guard let buffer = buffers.first(where: { $0.url == url }) else { return }
        do { try buffer.save() } catch { self.error(error.localizedDescription); return }
        buffers.removeAll { $0 === buffer }
        recentlyClosed.removeAll { $0 == url }; recentlyClosed.insert(url, at: 0); recentlyClosed = Array(recentlyClosed.prefix(8))
        if active === buffer {
            if let next = buffers.last { openFile(next.url) }
            else { active = nil; ui.editor.clear(); ui.editor.textView.isEditable = false; ui.explorer.reveal(url.appendingPathComponent("\u{0}")); ui.setTitle(project: project?.lastPathComponent ?? "BetterTeX", file: nil); ui.terminal.contextFile = nil; showEmptyEditor() }
        }
        refreshTabs(); overleaf.attachActiveDoc()
    }
    /// With every tab closed, the editor offers the main file, then recently closed and other source files.
    func showEmptyEditor() {
        guard let project, active == nil else { return }
        let sources = TeXProject.sourceFiles(in: project)
        let main = mainFile(among: sources)
        var files: [URL] = []
        for url in recentlyClosed + sources where url != main && !files.contains(url) && FileManager.default.fileExists(atPath: url.path) { files.append(url) }
        ui.editor.showEmpty(main: main, files: files, project: project)
    }
    /// The file that is compiled: the last build's root, the main file chosen for the project, else a file with \documentclass (main.tex first).
    private func mainFile(among sources: [URL]) -> URL? {
        if let compiledRoot, sources.contains(compiledRoot) { return compiledRoot }
        if let project, let chosen = TeXProject.chosenMain(for: project), FileManager.default.fileExists(atPath: chosen.path) { return chosen }
        func declaresDocument(_ url: URL) -> Bool {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            let head = String(decoding: handle.readData(ofLength: 8192), as: UTF8.self)
            return head.contains("\\documentclass")
        }
        let roots = sources.filter(declaresDocument)
        return roots.first { $0.lastPathComponent == "main.tex" } ?? roots.first ?? sources.first { $0.lastPathComponent == "main.tex" } ?? sources.first
    }
    func refreshTabs() { ui.editor.updateTabs(buffers, active: active?.url); ui.explorer.dirty = Set(buffers.filter(\.dirty).map(\.url)); window.isDocumentEdited = buffers.contains { $0.dirty } }
    func edited(_ text: String) {
        guard let active else { return }; active.text = text; active.dirty = true; refreshTabs(); overleaf.localEdited()
        saveJob?.cancel(); compileJob?.cancel()
        let job = DispatchWorkItem { [weak self] in
            guard let self, self.conflicts.isEmpty else { return }
            if self.saveAll(), !self.building, !self.preparingBuild { self.setStatus(L10n.tr("已自动保存")) }
        }
        saveJob = job; DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: job)
        // Building is timed apart from saving: it waits for a pause in typing that fits what was just typed.
        if ui.autoBuildEnabled { scheduleBuild(after: AutoBuildTiming.delay(previousCharacter: characterBeforeCursor(), lastBuildSeconds: lastBuildSeconds)) }
    }
    private func characterBeforeCursor() -> Character? {
        let text = ui.editor.textView.string as NSString; let location = ui.editor.textView.selectedRange().location
        guard location > 0, location <= text.length else { return nil }
        return text.substring(with: text.rangeOfComposedCharacterSequence(at: location - 1)).first
    }
    private func settle(_ buffer: EditorBuffer) {
        guard ["tex", "ltx", "sty", "cls"].contains(buffer.url.pathExtension.lowercased()) else { return }
        settledBalance[buffer.url] = TeXSource.balance(of: buffer.text)
    }
    /// The open file whose edits look half-finished: a group or environment opened or closed
    /// that was balanced at the last build. Automatic builds wait for it; manual ones do not.
    private func unfinishedEdit() -> EditorBuffer? {
        buffers.first { buffer in
            guard buffer.dirty || buffer === active, let settled = settledBalance[buffer.url] else { return false }
            let current = TeXSource.balance(of: buffer.text)
            return current != settled && current != TeXBalance()
        }
    }
    @discardableResult func saveAll() -> Bool {
        for buffer in buffers where buffer.dirty {
            if !buffer.snapshot.isCurrent(at: buffer.url) { conflicts.insert(buffer.url); if !resolveConflict(buffer) { return false } }
            do { try buffer.save() } catch { self.error(error.localizedDescription); return false }
        }
        refreshTabs(); return true
    }
    func externalChanges() {
        ui.explorer.refresh()
        for buffer in buffers where !buffer.snapshot.isCurrent(at: buffer.url) {
            if buffer.dirty {
                if !conflicts.contains(buffer.url) { conflicts.insert(buffer.url); _ = resolveConflict(buffer) }
            } else {
                do {
                    if buffer === active { buffer.selection = ui.editor.textView.selectedRange() }
                    try buffer.reload(); settle(buffer); if buffer === active, let project { ui.editor.load(buffer, project: project) }
                    setStatus(L10n.tr("已载入外部修改：\(buffer.url.lastPathComponent)"))
                } catch { setStatus(L10n.tr("文件已移动或无法读取：\(buffer.url.lastPathComponent)")) }
            }
        }
        refreshTabs(); refreshGit(); overleaf.localEdited(); overleaf.localFilesChanged(); refreshCompletionIndex(after: 1.5)
        if ui.autoBuildEnabled, conflicts.isEmpty { scheduleBuild() }
    }
    func resolveConflict(_ buffer: EditorBuffer) -> Bool {
        guard !resolvingConflict else { return false }; resolvingConflict = true; defer { resolvingConflict = false }
        let alert = NSAlert(); alert.messageText = L10n.tr("\(buffer.url.lastPathComponent) 存在外部修改")
        alert.informativeText = L10n.tr("本地编辑尚未保存，磁盘内容也已变化。请选择保留哪个版本；稍后处理会暂停自动保存和编译。")
        alert.addButton(withTitle: L10n.tr("载入磁盘版本")); alert.addButton(withTitle: L10n.tr("用编辑器版本覆盖")); alert.addButton(withTitle: L10n.tr("稍后处理"))
        let result = alert.runModal()
        do {
            if result == .alertFirstButtonReturn { try buffer.reload(); if active === buffer, let project { ui.editor.load(buffer, project: project) } }
            else if result == .alertSecondButtonReturn { try buffer.save(overwrite: true) }
            else { setStatus(L10n.tr("外部修改冲突 · ⌘S 处理")); return false }
            conflicts.remove(buffer.url); return true
        } catch { self.error(error.localizedDescription); return false }
    }
    func scheduleBuild(after delay: TimeInterval = 0.6) {
        compileJob?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.build(automatic: true) }; compileJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: job)
    }
    @objc func buildClicked() {
        if building { buildPending = false; compileJob?.cancel(); compiler.runner.cancel(); setStatus(L10n.tr("正在停止编译…")) }
        else { compileJob?.cancel(); build() }
    }
    /// `automatic` builds (after saving, on file changes, when opening a project) are skipped
    /// when nothing the build reads has changed since the previous one.
    func build(automatic: Bool = false) {
        guard let project, let active, let tools, conflicts.isEmpty else { return }
        if building || preparingBuild { buildPending = true; return }
        if automatic {
            // Never build in the middle of an input-method composition (pinyin, kana, …).
            if ui.editor.textView.hasMarkedText() { scheduleBuild(after: 0.8); return }
            if let unfinished = unfinishedEdit() {
                setStatus(L10n.tr("\(unfinished.url.lastPathComponent) 中有未闭合的括号或环境 · 补全后自动编译")); return
            }
        }
        guard saveAll() else { return }
        let selected = TeXEngine(rawValue: ui.selectedEngine) ?? .automatic
        let resolved = Result { try TeXProject.root(active: active.url, project: project) }
        if case .failure(let error as AmbiguousMainError) = resolved {
            // Ask once per project for automatic builds; pressing Build always asks again.
            if !automatic || mainPromptedFor != project.path { chooseMain(from: error.candidates, project: project); return }
        }
        let rootPath = (try? resolved.get())?.path ?? active.url.path
        // Fingerprinting reads the project's files, so it runs off the main thread.
        preparingBuild = true
        let token = generation; let cache = signatureCache
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let signature = BuildSignature.compute(project: project, root: rootPath, engine: selected.rawValue, cache: cache)
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.preparingBuild = false
                if automatic, signature == self.lastBuildSignature {
                    // Only comments or spacing changed: the PDF would be identical.
                    if self.buildPending { self.buildPending = false; self.scheduleBuild() }
                    return
                }
                self.lastBuildSignature = signature
                self.startBuild(automatic: automatic, project: project, source: active.url, selected: selected, tools: tools)
            }
        }
    }
    private func startBuild(automatic: Bool, project: URL, source: URL, selected: TeXEngine, tools: Toolchain) {
        // What is on screen now is what this build sees; if it succeeds, later edits are compared against it.
        let balances = buffers.filter { settledBalance[$0.url] != nil }.map { ($0.url, TeXSource.balance(of: $0.text)) }
        building = true; buildPending = false; compiler.runner.reset()
        ui.setBuilding(true)
        setStatus(L10n.tr("正在编译…"))
        let token = generation; let compiler = compiler
        ui.terminal.append("\n── \(Date().formatted(date: .omitted, time: .standard)) · Build \(source.lastPathComponent) ──\n")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = SourceSnapshot.capture(directory: project)
            let result = Result { try compiler.build(active: source, project: project, selected: selected, tools: tools, onStage: { stage in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token, self.building else { return }
                    self.ui.setBuildStage(stage); self.setStatus(L10n.tr("正在编译 · \(stage.title)"))
                }
            }, onOutput: { text in
                DispatchQueue.main.async { [weak self] in if self?.generation == token { self?.ui.terminal.append(text) } }
            }) }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.building = false; self.ui.setBuilding(false)
                switch result {
                case .success(let build):
                    self.compiledRoot = build.root; self.lastBuildSeconds = build.seconds
                    self.buildErrors = build.succeeded ? [] : build.diagnostics; self.buildWarnings = TeXWarning.parse(build.log); self.refreshProblems()
                    self.buildWarningMessages = TeXWarning.messages(build.log)
                    self.ui.setDiagnostics(errors: build.succeeded ? 0 : max(1, build.diagnostics.count), warnings: self.buildWarningMessages.count)
                    if build.succeeded {
                        for (url, balance) in balances { self.settledBalance[url] = balance }
                        self.compiledPDF = build.pdf; self.compiledSnapshot = snapshot; self.ui.preview.load(build.pdf); self.ui.activity = .idle
                        self.setStatus(String(format: L10n.tr("编译完成 · %@ · %.1f s"), build.engine.rawValue, build.seconds))
                    } else {
                        // A failed automatic build marks the errors in place; only an explicit build opens the log.
                        self.setStatus(L10n.tr("编译失败 · 保留上次预览")); self.ui.activity = .failed; if !automatic { self.ui.showOutput() }
                        if let first = build.diagnostics.first { self.ui.terminal.append(L10n.tr("\n错误：\(first.message)\n双击上方文件:行号可定位源码。\n")) }
                    }
                case .failure(let error): self.setStatus(error.localizedDescription); self.ui.activity = .failed; self.ui.terminal.append("\n\(error.localizedDescription)\n"); if !automatic { self.ui.showOutput() }
                }
                if self.buildPending { self.buildPending = false; self.scheduleBuild() }
            }
        }
    }
    @objc func forwardSync() {
        guard let active, compiledPDF != nil, tools != nil else { setStatus(L10n.tr("请先成功编译文档，再使用双向定位")); return }
        let (line, _) = ui.editor.lineColumn
        forwardSync(file: active.url, line: line, cursor: ui.editor.textView.selectedRange().location, text: ui.editor.textView.string)
    }
    /// Follows a link from an agent reply: a source line opens in the editor and, when the document
    /// has been compiled, the PDF scrolls to it; a page number turns the PDF to that page.
    func open(_ location: AgentLocation) {
        switch location {
        case .pdfPage(let page):
            guard let document = ui.preview.pdfView.document, let target = document.page(at: min(page, document.pageCount) - 1) else { setStatus(L10n.tr("请先编译文档")); return }
            ui.pdfItem.isCollapsed = false; ui.preview.pdfView.go(to: target); setStatus(L10n.tr("PDF · 第 \(page) 页"))
        case .source(let url, let line):
            openFile(url, line: line)
            guard let line, ["tex", "ltx"].contains(url.pathExtension.lowercased()), compiledPDF != nil, tools != nil else { return }
            forwardSync(file: url, line: line, cursor: nil, text: currentText(of: url))
        }
    }
    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
    /// What a source file holds now: the editor's text for open files, otherwise the file on disk.
    private func currentText(of url: URL) -> String? {
        if let active, Self.samePath(active.url, url) { return ui.editor.textView.string }
        if let buffer = buffers.first(where: { Self.samePath($0.url, url) }) { return buffer.text }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Source → PDF. SyncTeX (with the line corrected for edits since the build) names the boxes of the line;
    /// the words around the caret are then found in the page text, so the PDF lands on the same word and
    /// marks the sentence, even inside a paragraph written on one long line.
    private func forwardSync(file: URL, line: Int, cursor: Int?, text: String?) {
        guard let pdf = compiledPDF, let tools else { return }
        let token = generation; let snapshot = compiledSnapshot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = text ?? (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let starts = TextSync.lineStarts(text)
            let lineStart = starts[min(max(0, line - 1), starts.count - 1)]
            let lineEnd = line < starts.count ? starts[line] : (text as NSString).length
            // Without a caret (a link to a line), start at the line's first word.
            let caret = cursor ?? lineStart
            let compiledLine = snapshot?.lineMap(for: file, current: text)?.compiled(forCurrent: line) ?? line
            var boxes: [SyncBox] = []
            for candidate in stride(from: compiledLine, through: max(1, compiledLine - 6), by: -1) {
                boxes = SyncTeX.boxes(file: file, line: candidate, pdf: pdf, tools: tools)
                if !boxes.isEmpty { break }
            }
            let stream = TextSync.texStream(text)
            // Only follow the text when the caret's own line has printed words (not a display equation or a figure).
            var index = stream.index(atOrAfter: caret)
            if index >= stream.count || stream.offset(at: index) >= lineEnd {
                let before = index - 1
                index = before >= 0 && stream.offset(at: before) >= lineStart ? before : -1
            }
            var sentence: ClosedRange<Int>?
            if index >= 0 {
                let range = TextSync.sentenceRange(in: text, at: stream.offset(at: index))
                let first = stream.index(atOrAfter: range.location), last = stream.index(atOrAfter: NSMaxRange(range)) - 1
                if first <= index, last >= index { sentence = first...last }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.ui.pdfItem.isCollapsed = false
                if index >= 0, let page = self.ui.preview.reveal(source: stream, cursor: index, sentence: sentence, boxes: boxes) {
                    self.setStatus(L10n.tr("源码 → PDF · 第 \(page) 页"))
                } else if let box = boxes.first {
                    self.ui.preview.goTo(boxes: boxes); self.setStatus(L10n.tr("源码 → PDF · 第 \(box.page) 页"))
                } else {
                    self.setStatus(L10n.tr("该位置没有 PDF 映射。请先成功编译，并选择正文所在行。"))
                }
            }
        }
    }

    /// PDF → source. The clicked words are found in the source near the line SyncTeX names (corrected for edits
    /// since the build), so the caret lands on the clicked word and its sentence is marked.
    func inverseSync(page: Int, x: Double, y: Double) {
        guard let pdf = compiledPDF, let root = compiledRoot, let tools else { setStatus(L10n.tr("请先编译当前文档以生成 SyncTeX 映射")); return }
        var clicked: (stream: TextStream, index: Int)?
        if let pdfPage = ui.preview.pdfView.document?.page(at: page - 1) {
            let media = pdfPage.bounds(for: .mediaBox)
            clicked = ui.preview.textPosition(page: page - 1, point: CGPoint(x: media.minX + x, y: media.maxY - y))
        }
        let token = generation; let snapshot = compiledSnapshot
        let candidates = ([active?.url].compactMap { $0 } + buffers.map(\.url)).filter { ["tex", "ltx"].contains($0.pathExtension.lowercased()) }
        let texts = Dictionary(candidates.map { ($0, currentText(of: $0) ?? "") }, uniquingKeysWith: { first, _ in first })
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let synced = try? SyncTeX.inverse(page: page, x: x, y: y, pdf: pdf, root: root, tools: tools)
            func text(of url: URL) -> String? {
                texts.first { Self.samePath($0.key, url) }?.value ?? (try? String(contentsOf: url, encoding: .utf8))
            }
            var result: (file: URL, offset: Int?, line: Int, text: String)?
            if let synced, let source = text(of: synced.file) {
                // Reuse an open tab's URL so the same file is not opened twice under another spelling.
                let file = candidates.first { Self.samePath($0, synced.file) } ?? synced.file
                let line = snapshot?.lineMap(for: file, current: source)?.current(forCompiled: synced.line) ?? synced.line
                result = (file, nil, line, source)
            }
            if let clicked {
                // Search the file SyncTeX named, near its line; without SyncTeX, every open source file.
                let files: [(URL, String, Int?)] = result.map { [($0.file, $0.text, $0.line)] } ?? candidates.map { ($0, texts[$0] ?? "", nil) }
                var best: (file: URL, offset: Int, line: Int, text: String, score: Double)?
                for (file, source, hint) in files where !source.isEmpty {
                    let stream = TextSync.texStream(source); let starts = TextSync.lineStarts(source)
                    let penalty: ((Int) -> Double)? = hint.map { hint in { Double(abs(TextSync.line(of: stream.offset(at: $0), starts: starts) - hint)) / 12 } }
                    guard let match = TextSync.correspond(clicked.index, from: clicked.stream, to: stream, penalty: penalty) else { continue }
                    let offset = stream.offset(at: match.index)
                    let score = match.weight / (1 + (penalty?(match.index) ?? 0))
                    if best == nil || score > best!.score { best = (file, offset, TextSync.line(of: offset, starts: starts), source, score) }
                }
                if let best { result = (best.file, best.offset, best.line, best.text) }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                guard let result else { self.setStatus(L10n.tr("此处没有对应的 TeX 源码。")); return }
                if let offset = result.offset {
                    self.openFile(result.file)
                    self.ui.editor.reveal(offset: offset, sentence: TextSync.sentenceRange(in: result.text, at: offset))
                } else {
                    self.openFile(result.file, line: result.line)
                }
                self.setStatus("PDF → \(result.file.lastPathComponent):\(result.line)")
            }
        }
    }
    @objc func newFile() {
        guard let project else { return }
        let panel = NSSavePanel(); panel.directoryURL = project; panel.nameFieldStringValue = "section.tex"; panel.title = L10n.tr("新建文件"); panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { guard !FileManager.default.fileExists(atPath: url.path) else { throw BetterTeXError.message(L10n.tr("文件已存在，请使用其他名称。")) }; try "".write(to: url, atomically: true, encoding: .utf8); self?.openFile(url); self?.ui.explorer.refresh() }
            catch { self?.error(error.localizedDescription) }
        }
    }
    /// Rescans the project for completion candidates, off the main thread.
    func refreshCompletionIndex(after delay: TimeInterval = 0) {
        indexJob?.cancel()
        let job = DispatchWorkItem { [weak self] in
            guard let self, let project = self.project else { return }
            let token = self.generation
            let base = self.active.flatMap { try? TeXProject.root(active: $0.url, project: project) }?.deletingLastPathComponent() ?? project
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let index = ProjectIndex.scan(project: project, base: base)
                DispatchQueue.main.async { if let self, self.generation == token { self.completionIndex = index } }
            }
        }
        indexJob = job; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: job)
    }
    /// Lists the last build's errors or warnings under the status bar count. An entry with a known
    /// source location opens it; the rest are found in the build log.
    func showProblems(errors: Bool, anchor: NSView) {
        let menu = NSMenu(); menu.autoenablesItems = false
        let limit = 40
        func short(_ text: String) -> String { text.count > 110 ? String(text.prefix(110)) + "…" : text }
        if errors {
            for diagnostic in buildErrors.prefix(limit) {
                let title = "\(URL(fileURLWithPath: diagnostic.file).lastPathComponent):\(diagnostic.line)  \(short(diagnostic.message))"
                menu.addItem(ClosureMenuItem(title, symbol: "xmark.octagon") { [weak self] in self?.ui.terminal.onDiagnostic?(diagnostic.file, diagnostic.line) })
            }
            if buildErrors.isEmpty, ui.activity == .failed {
                menu.addItem(ClosureMenuItem(L10n.tr("编译失败，日志中未找到带行号的错误"), enabled: false) {})
            }
            if buildErrors.count > limit { menu.addItem(ClosureMenuItem(L10n.tr("还有 \(buildErrors.count - limit) 条…"), enabled: false) {}) }
        } else {
            for message in buildWarningMessages.prefix(limit) {
                let location = warningLocation(message)
                let title = (location.map { "\($0.url.lastPathComponent):\($0.line)  " } ?? "") + short(message)
                menu.addItem(ClosureMenuItem(title, symbol: "exclamationmark.triangle") { [weak self] in
                    guard let self else { return }
                    if let location { self.openFile(location.url, line: location.line) }
                    else { self.ui.showOutput(); self.ui.terminal.revealInLog(String(message.prefix(60))) }
                })
            }
            if buildWarningMessages.count > limit { menu.addItem(ClosureMenuItem(L10n.tr("还有 \(buildWarningMessages.count - limit) 条…"), enabled: false) {}) }
        }
        if menu.items.isEmpty { menu.addItem(ClosureMenuItem(errors ? L10n.tr("没有错误") : L10n.tr("没有警告"), enabled: false) {}) }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L10n.tr("显示编译日志"), symbol: "doc.plaintext") { [weak self] in self?.ui.showOutput() })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }
    /// The source line an undefined-reference warning points at: the log names only the line, so the
    /// file is the one whose line mentions the key (the active file first).
    private func warningLocation(_ message: String) -> (url: URL, line: Int)? {
        guard let warning = TeXWarning.parse(message).first else { return nil }
        var candidates: [(URL, String?)] = []
        if let active { candidates.append((active.url, active.text)) }
        for buffer in buffers where buffer !== active { candidates.append((buffer.url, buffer.text)) }
        if let project { for url in TeXProject.sourceFiles(in: project) where url.pathExtension.lowercased() == "tex" && !candidates.contains(where: { $0.0.standardizedFileURL == url.standardizedFileURL }) { candidates.append((url, nil)) } }
        for (url, text) in candidates {
            guard let lines = (text ?? (try? String(contentsOf: url, encoding: .utf8)))?.components(separatedBy: "\n") else { continue }
            if lines.indices.contains(warning.line - 1), lines[warning.line - 1].contains(warning.key) { return (url, warning.line) }
        }
        return nil
    }
    /// Shows the last build's errors and undefined references that fall in the active file.
    func refreshProblems() {
        guard let active else { ui.editor.setProblems(errors: [], warnings: []); return }
        let base = (compiledRoot ?? active.url).deletingLastPathComponent()
        let errors = buildErrors.filter { URL(fileURLWithPath: $0.file, relativeTo: base).standardizedFileURL.path == active.url.standardizedFileURL.path }.map(\.line)
        // The log gives a warning's line but not its file: it belongs here if that line mentions the key.
        let lines = active.text.components(separatedBy: "\n")
        let warnings = buildWarnings.filter { lines.indices.contains($0.line - 1) && lines[$0.line - 1].contains($0.key) }.map(\.line)
        ui.editor.setProblems(errors: Set(errors), warnings: Set(warnings))
    }
    /// Recomputes the change strip in the editor gutter for the active file (as saved on disk).
    func refreshGitMarkers() {
        guard let project, let tools, let file = active?.url else { ui.editor.setGitChanges([]); return }
        let token = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let changes = GitService(directory: project, tools: tools).lineChanges(file: file)
            DispatchQueue.main.async { guard let self, self.generation == token, self.active?.url == file else { return }; self.ui.editor.setGitChanges(changes) }
        }
    }
    func refreshGit() {
        refreshGitMarkers()
        guard let project, let tools else { return }; let token = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let service = GitService(directory: project, tools: tools)
            let state = try? service.state()
            let remotes = (try? service.checked(["remote", "-v"])) ?? ""
            let host = remotes.isEmpty || remotes.lowercased().contains("github.com") ? "GitHub" : "Git"
            DispatchQueue.main.async { guard let self, self.generation == token else { return }; self.ui.setGitHost(host); self.ui.setBranch(state.map { $0.branch + ($0.changes.isEmpty ? "" : L10n.tr(" · \($0.changes.count) 项更改")) } ?? "") }
        }
    }
    func git(push: Bool) {
        guard !gitBusy, saveAll(), let project, let tools else { return }
        gitBusy = true; let token = generation; let service = GitService(directory: project, tools: tools)
        setStatus(L10n.tr("正在检查 Git 状态…"))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let state = Result { try service.state() }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.gitBusy = false
                switch state {
                case .failure(let error): self.error(L10n.tr("当前目录无法执行 Git 操作。请先在 Shell 中初始化仓库并配置远端。\n\n") + error.localizedDescription)
                case .success(let state):
                    guard state.hasRemote else { self.error(L10n.tr("仓库尚未配置远端。请在 Shell 中运行 git remote add origin <URL>，然后设置上游分支。")); return }
                    if push && !state.changes.isEmpty { self.reviewCommit(state, service: service) }
                    else { self.runGit(push ? "Push" : "Pull") { push ? try service.push() : try service.pull() } }
                }
            }
        }
    }
    func reviewCommit(_ state: GitState, service: GitService) {
        let alert = NSAlert(); alert.messageText = L10n.tr("提交并 Push 到远端")
        alert.informativeText = L10n.tr("选择本次提交文件。未跟踪文件默认不勾选；已有提交也可以直接推送。GPT Luna 会自动总结提交说明，改动勾选后可点「AI 生成」重写。Git 认证使用本机凭据。")
        alert.addButton(withTitle: L10n.tr("提交并 Push")); alert.addButton(withTitle: L10n.tr("仅 Push 已有提交")); alert.addButton(withTitle: L10n.tr("取消"))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 280))
        let message = NSTextField(frame: NSRect(x: 0, y: 244, width: 400, height: 26)); message.placeholderString = L10n.tr("提交说明，例如：完善方法章节"); container.addSubview(message)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 230)); scroll.hasVerticalScroller = true
        let rows = NSStackView(); rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 7
        var checks: [(NSButton, GitChange)] = []
        for change in state.changes where !change.path.contains(".bettertex/") && change.path != ".DS_Store" {
            let checkbox = NSButton(checkboxWithTitle: "[\(change.status)] \(change.path)", target: nil, action: nil)
            checkbox.font = .monospacedSystemFont(ofSize: 11, weight: .regular); checkbox.state = change.isUntracked ? .off : .on
            rows.addArrangedSubview(checkbox); checks.append((checkbox, change))
        }
        // Drafts the message from the ticked files with GPT Luna; the user can still edit it.
        // A first draft starts as the sheet opens so it is usually there by the time they look.
        let writer = ProcessRunner(); let tools = self.tools; let terminal = ui.terminal
        let placeholder = message.placeholderString
        var generate: ActionButton!
        let draft: (Bool) -> Void = { [weak alert] automatic in
            guard let tools, generate.isEnabled else { return }
            let selected = checks.filter { $0.0.state == .on }.map { $0.1 }
            if automatic { guard tools["codex"] != nil, !selected.isEmpty else { return }; message.placeholderString = L10n.tr("GPT Luna 正在总结提交说明…") }
            generate.isEnabled = false; generate.title = L10n.tr("生成中…")
            DispatchQueue.global(qos: .userInitiated).async {
                let model = CommitMessageWriter.lunaModel(tools: tools)
                let result = Result { try CommitMessageWriter.generate(changes: try service.changeSummary(selected), recentSubjects: service.recentSubjects(), model: model, tools: tools, runner: writer) }
                DispatchQueue.main.async {
                    generate.isEnabled = true; generate.title = L10n.tr("AI 生成"); message.placeholderString = placeholder
                    guard alert?.window.isVisible == true else { return }
                    switch result {
                    case .success(let text):
                        // Never replace what the user typed while the automatic draft was on its way.
                        guard !automatic || message.stringValue.isEmpty else { return }
                        message.stringValue = text; message.toolTip = L10n.tr("由 \(model) 生成，可继续修改")
                    case .failure(let error):
                        let reason = error.localizedDescription
                        if !automatic { message.placeholderString = L10n.tr("生成失败：") + (reason.components(separatedBy: .newlines).first ?? reason) }
                        terminal.append(L10n.tr("\n提交说明生成\n") + reason + "\n")
                    }
                }
            }
        }
        generate = ActionButton(L10n.tr("AI 生成"), style: .push) { draft(false) }
        generate.frame = NSRect(x: 406, y: 241, width: 98, height: 32); generate.toolTip = L10n.tr("用 GPT Luna 根据勾选的更改总结提交说明"); container.addSubview(generate)
        rows.frame = NSRect(x: 0, y: 0, width: 480, height: max(220, checks.count * 25)); scroll.documentView = rows; container.addSubview(scroll); alert.accessoryView = container
        draft(true)
        alert.beginSheetModal(for: window) { [weak self] result in
            writer.cancel()
            guard let self else { return }
            if result == .alertSecondButtonReturn { self.runGit("Push") { try service.push() } }
            else if result == .alertFirstButtonReturn {
                let paths = checks.filter { $0.0.state == .on }.flatMap { $0.1.commitPaths }
                guard !message.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !paths.isEmpty else { self.error(L10n.tr("提交说明和已选文件不能为空，请重新点击 Push。")); return }
                let text = message.stringValue
                self.runGit("Commit + Push") { try service.commitAndPush(message: text, paths: paths) }
            }
        }
    }
    func runGit(_ label: String, operation: @escaping () throws -> String) {
        guard !gitBusy else { return }; gitBusy = true; setStatus("Git \(label)…"); let token = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try operation() }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }; self.gitBusy = false
                switch result {
                case .success(let log): self.setStatus(L10n.tr("Git \(label) 完成")); self.ui.terminal.append("\nGit \(label)\n" + log); self.externalChanges()
                case .failure(let error): self.setStatus(L10n.tr("Git \(label) 失败")); self.ui.terminal.append("\nGit \(label)\n" + error.localizedDescription); self.ui.showOutput(); self.error(error.localizedDescription + L10n.tr("\n\n如需交互式登录、设置上游分支或处理冲突，请使用 Shell 标签。"))
                }
            }
        }
    }
    @objc func showTools() {
        let alert = NSAlert(); alert.messageText = L10n.tr("本机工具")
        alert.informativeText = ["latexmk", "pdflatex", "xelatex", "lualatex", "synctex", "codex", "claude", "git"].map { "\($0)\n  \(tools?[$0] ?? L10n.tr("未检测到"))" }.joined(separator: "\n\n")
        alert.addButton(withTitle: L10n.tr("完成")); alert.addButton(withTitle: L10n.tr("重新检测"))
        alert.beginSheetModal(for: window) { [weak self] result in if result == .alertSecondButtonReturn { self?.detectTools() } }
    }
    func setStatus(_ message: String) { ui.status.stringValue = message; ui.status.toolTip = message }
    func error(_ message: String) {
        setStatus(message.components(separatedBy: .newlines).first ?? message)
        let alert = NSAlert(); alert.messageText = "BetterTeX"; alert.informativeText = message; alert.addButton(withTitle: L10n.tr("好"))
        if window.attachedSheet == nil { alert.beginSheetModal(for: window) }
        else { ui.terminal.append("\n" + message + "\n") }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard prepareToClose() else { return false }
        shutdown(); return true
    }
    func prepareToClose() -> Bool {
        guard saveAll() else { return false }
        if !ui.terminal.terminals.isEmpty {
            let alert = NSAlert(); alert.messageText = L10n.tr("关闭工作区并结束终端会话？"); alert.informativeText = L10n.tr("运行中的 Codex、Claude 和 Shell 会话将停止。文件修改已经保存。"); alert.addButton(withTitle: L10n.tr("关闭")); alert.addButton(withTitle: L10n.tr("取消"))
            if alert.runModal() != .alertFirstButtonReturn { return false }
        }
        return true
    }
    func shutdown() { overleaf.shutdown(); saveJob?.cancel(); compileJob?.cancel(); compiler.runner.cancel(); ui.terminal.stopAll(); watcher.stop() }
}
