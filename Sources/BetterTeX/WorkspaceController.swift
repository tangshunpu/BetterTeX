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
    var building = false
    var buildPending = false
    /// Fingerprint of the inputs of the last build, so automatic triggers never repeat it.
    var lastBuildSignature: String?
    /// Problems of the most recent build, shown in the editor of whichever file they belong to.
    var buildErrors: [TeXDiagnostic] = []
    var buildWarnings: [TeXWarning] = []
    var gitBusy = false
    var compiledPDF: URL?
    var compiledRoot: URL?
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
        window.minSize = NSSize(width: 1120, height: 680); window.isReleasedWhenClosed = false
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
        ui.explorer.onJump = { [weak self] in self?.ui.editor.goTo(line: $0) }
        ui.onOpenFile = { [weak self] in self?.openFile($0) }
        ui.editor.onOutline = { [weak self] items in
            guard let self else { return }
            self.ui.explorer.setOutline(items, cursorLine: self.ui.editor.lineColumn.0)
            self.ui.editor.setBreadcrumb(section: self.ui.explorer.currentOutlineTitle)
        }
        ui.editor.onChange = { [weak self] in self?.edited($0) }
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
        ui.editor.onInsertImage = { [weak self] in self?.pickImage() }
        ui.editor.textView.onDropImages = { [weak self] in self?.insertImages($0) }
        ui.editor.textView.onPasteImage = { [weak self] in self?.insertPastedImage($0) }
        ui.preview.pdfView.onInverse = { [weak self] in self?.inverseSync(page: $0, x: $1, y: $2) }
        ui.preview.onExport = { [weak self] in self?.exportPDF() }
        ui.terminal.onError = { [weak self] in self?.error($0) }
        ui.terminal.currentContext = { [weak self] in
            guard let self, let file = self.active?.url else { return nil }
            let text = self.ui.editor.textView.string as NSString
            let range = self.ui.editor.textView.selectedRange()
            let path = file.path.replacingOccurrences(of: (self.project?.path ?? "") + "/", with: "")
            let selection = range.length > 0 && NSMaxRange(range) <= text.length ? "\n```tex\n" + text.substring(with: range) + "\n```" : ""
            return "@\(path)" + selection
        }
        ui.terminal.onDiagnostic = { [weak self] path, line in
            guard let self, let root = self.compiledRoot ?? self.active?.url else { return }
            self.openFile(URL(fileURLWithPath: path, relativeTo: root.deletingLastPathComponent()).standardizedFileURL, line: line)
        }
        watcher.onChange = { [weak self] in self?.externalChanges() }
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
        panel.allowedFileTypes = Array(CodeTextView.imageExtensions); panel.prompt = "插入"; panel.message = "选择要插入的图片；项目外的文件会拷贝到 figures/。"
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
        setStatus("已插入 \(urls.count) 张图片" + (copied > 0 ? " · 已拷贝到 figures/" : "") + (package == true ? " · 已添加 graphicx 宏包" : package == nil ? " · 请在主文档加入 \\usepackage{graphicx}" : ""))
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
        guard let pdf = compiledPDF else { setStatus("请先编译文档，再导出 PDF"); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = pdf.lastPathComponent; panel.directoryURL = project; panel.title = "导出 PDF"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let target = panel.url else { return }
            do { if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }; try FileManager.default.copyItem(at: pdf, to: target); self?.setStatus("已导出 \(target.lastPathComponent)") }
            catch { self?.error(error.localizedDescription) }
        }
    }
    func show() {
        window.makeKeyAndOrderFront(nil); positionTrafficLights()
        DispatchQueue.main.async { [weak self] in self?.ui.initialLayout() }
        do {
            if let path = UserDefaults.standard.string(forKey: "lastProject"), FileManager.default.fileExists(atPath: path) { loadProject(URL(fileURLWithPath: path)) }
            else { loadProject(try SampleProject.create()) }
        } catch { self.error(error.localizedDescription) }
        detectTools()
    }
    func detectTools() {
        setStatus("正在检测本机工具…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tools = Toolchain.discover()
            DispatchQueue.main.async {
                guard let self else { return }; self.tools = tools
                if let project = self.project { self.ui.terminal.configure(project: project, tools: tools) }
                let engines = ["pdflatex", "xelatex", "lualatex"].filter { tools[$0] != nil }
                self.ui.setTools(engines: engines.count, syncTeX: tools["synctex"] != nil)
                self.setStatus(engines.isEmpty ? "请安装本机 TeX 发行版" : "本机工具就绪")
                self.refreshGit(); if self.ui.autoBuildEnabled { self.scheduleBuild() }
            }
        }
    }
    func loadProject(_ url: URL) {
        generation = UUID(); saveJob?.cancel(); compileJob?.cancel(); compiler.runner.cancel(); compiler = TeXCompiler()
        building = false; buildPending = false; gitBusy = false; ui.setBuilding(false); ui.activity = .idle
        watcher.stop(); ui.terminal.stopAll(); buffers.removeAll(); active = nil; conflicts.removeAll()
        project = url.standardizedFileURL; compiledPDF = nil; compiledRoot = nil; lastBuildSignature = nil; buildErrors = []; buildWarnings = []; ui.preview.clear()
        window.title = url.lastPathComponent; ui.setTitle(project: url.lastPathComponent, file: nil); ui.projectURL = url.standardizedFileURL; ui.setBranch(""); ui.terminal.contextFile = nil
        ui.explorer.load(url); ui.editor.clear(); ui.editor.textView.isEditable = false; refreshTabs()
        if let tools { ui.terminal.configure(project: url, tools: tools) }
        UserDefaults.standard.set(url.path, forKey: "lastProject")
        let files = TeXProject.sourceFiles(in: url)
        if let main = files.first(where: { $0.lastPathComponent == "main.tex" }) ?? files.first { openFile(main) }
        watcher.start(url); refreshGit()
        if tools != nil, ui.autoBuildEnabled { scheduleBuild() }
        overleaf.projectChanged()
    }
    /// Asks before replacing a workspace that still has terminal sessions running.
    func confirmSwitch() -> Bool {
        guard saveAll() else { return false }
        guard !ui.terminal.terminals.isEmpty else { return true }
        let alert = NSAlert(); alert.messageText = "切换工作区并结束当前终端会话？"; alert.informativeText = "Codex、Claude 和 Shell 会话会关闭，新会话将在新目录启动。"; alert.addButton(withTitle: "切换"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    @objc func openFolder() {
        guard saveAll() else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "打开工作区"; panel.directoryURL = project
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if !self.ui.terminal.terminals.isEmpty {
                let alert = NSAlert(); alert.messageText = "切换工作区并结束当前终端会话？"; alert.informativeText = "Codex、Claude 和 Shell 会话会关闭，新会话将在新目录启动。"; alert.addButton(withTitle: "切换"); alert.addButton(withTitle: "取消")
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
            else { buffer = try EditorBuffer(url: url); buffers.append(buffer) }
            active = buffer; ui.editor.textView.isEditable = true
            ui.editor.load(buffer, project: project ?? url.deletingLastPathComponent()); refreshTabs(); ui.explorer.reveal(url)
            let root = project ?? url.deletingLastPathComponent()
            ui.setTitle(project: root.lastPathComponent, file: url.lastPathComponent)
            ui.terminal.contextFile = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if let line { ui.editor.goTo(line: line, column: column) }
            overleaf.attachActiveDoc(); ui.editor.setGitChanges([]); refreshGitMarkers(); refreshProblems()
        } catch { self.error(error.localizedDescription) }
    }
    func closeTab(_ url: URL) {
        guard let buffer = buffers.first(where: { $0.url == url }) else { return }
        do { try buffer.save() } catch { self.error(error.localizedDescription); return }
        buffers.removeAll { $0 === buffer }
        if active === buffer {
            if let next = buffers.last { openFile(next.url) }
            else { active = nil; ui.editor.clear(); ui.editor.textView.isEditable = false; ui.explorer.reveal(url.appendingPathComponent("\u{0}")); ui.setTitle(project: project?.lastPathComponent ?? "BetterTeX", file: nil); ui.terminal.contextFile = nil }
        }
        refreshTabs(); overleaf.attachActiveDoc()
    }
    func refreshTabs() { ui.editor.updateTabs(buffers, active: active?.url); ui.explorer.dirty = Set(buffers.filter(\.dirty).map(\.url)); window.isDocumentEdited = buffers.contains { $0.dirty } }
    func edited(_ text: String) {
        guard let active else { return }; active.text = text; active.dirty = true; refreshTabs(); overleaf.localEdited()
        saveJob?.cancel(); compileJob?.cancel()
        let job = DispatchWorkItem { [weak self] in
            guard let self, self.conflicts.isEmpty else { return }
            if self.saveAll() { self.setStatus("已自动保存"); if self.ui.autoBuildEnabled { self.scheduleBuild() } }
        }
        saveJob = job; DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: job)
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
                    try buffer.reload(); if buffer === active, let project { ui.editor.load(buffer, project: project) }
                    setStatus("已载入外部修改：\(buffer.url.lastPathComponent)")
                } catch { setStatus("文件已移动或无法读取：\(buffer.url.lastPathComponent)") }
            }
        }
        refreshTabs(); refreshGit(); overleaf.localEdited(); overleaf.localFilesChanged()
        if ui.autoBuildEnabled, conflicts.isEmpty { scheduleBuild() }
    }
    func resolveConflict(_ buffer: EditorBuffer) -> Bool {
        guard !resolvingConflict else { return false }; resolvingConflict = true; defer { resolvingConflict = false }
        let alert = NSAlert(); alert.messageText = "\(buffer.url.lastPathComponent) 存在外部修改"
        alert.informativeText = "本地编辑尚未保存，磁盘内容也已变化。请选择保留哪个版本；稍后处理会暂停自动保存和编译。"
        alert.addButton(withTitle: "载入磁盘版本"); alert.addButton(withTitle: "用编辑器版本覆盖"); alert.addButton(withTitle: "稍后处理")
        let result = alert.runModal()
        do {
            if result == .alertFirstButtonReturn { try buffer.reload(); if active === buffer, let project { ui.editor.load(buffer, project: project) } }
            else if result == .alertSecondButtonReturn { try buffer.save(overwrite: true) }
            else { setStatus("外部修改冲突 · ⌘S 处理"); return false }
            conflicts.remove(buffer.url); return true
        } catch { self.error(error.localizedDescription); return false }
    }
    func scheduleBuild() {
        compileJob?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.build(automatic: true) }; compileJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: job)
    }
    @objc func buildClicked() {
        if building { buildPending = false; compileJob?.cancel(); compiler.runner.cancel(); setStatus("正在停止编译…") }
        else { compileJob?.cancel(); build() }
    }
    /// `automatic` builds (after saving, on file changes, when opening a project) are skipped
    /// when nothing the build reads has changed since the previous one.
    func build(automatic: Bool = false) {
        guard let project, let active, let tools, conflicts.isEmpty else { return }
        if building { buildPending = true; return }
        guard saveAll() else { return }
        let selected = TeXEngine(rawValue: ui.selectedEngine) ?? .automatic
        let rootPath = (try? TeXProject.root(active: active.url, project: project))?.path ?? active.url.path
        let signature = BuildSignature.compute(project: project, root: rootPath, engine: selected.rawValue)
        if automatic, signature == lastBuildSignature { return }
        lastBuildSignature = signature
        building = true; buildPending = false; compiler.runner.reset()
        ui.setBuilding(true)
        setStatus("正在编译…")
        let token = generation; let compiler = compiler; let source = active.url
        ui.terminal.append("\n── \(Date().formatted(date: .omitted, time: .standard)) · Build \(source.lastPathComponent) ──\n")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try compiler.build(active: source, project: project, selected: selected, tools: tools, onStage: { stage in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token, self.building else { return }
                    self.ui.setBuildStage(stage); self.setStatus("正在编译 · \(stage.title)")
                }
            }, onOutput: { text in
                DispatchQueue.main.async { [weak self] in if self?.generation == token { self?.ui.terminal.append(text) } }
            }) }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.building = false; self.ui.setBuilding(false)
                switch result {
                case .success(let build):
                    self.compiledRoot = build.root
                    self.buildErrors = build.succeeded ? [] : build.diagnostics; self.buildWarnings = TeXWarning.parse(build.log); self.refreshProblems()
                    let warnings = build.log.components(separatedBy: .newlines).filter { $0.contains("Warning:") }.count
                    self.ui.setDiagnostics(errors: build.succeeded ? 0 : max(1, build.diagnostics.count), warnings: warnings)
                    if build.succeeded {
                        self.compiledPDF = build.pdf; self.ui.preview.load(build.pdf); self.ui.activity = .idle
                        self.setStatus(String(format: "编译完成 · %@ · %.1f s", build.engine.rawValue, build.seconds))
                    } else {
                        self.setStatus("编译失败 · 保留上次预览"); self.ui.activity = .failed; self.ui.showOutput()
                        if let first = build.diagnostics.first { self.ui.terminal.append("\n错误：\(first.message)\n双击上方文件:行号可定位源码。\n") }
                    }
                case .failure(let error): self.setStatus(error.localizedDescription); self.ui.activity = .failed; self.ui.terminal.append("\n\(error.localizedDescription)\n"); self.ui.showOutput()
                }
                if self.buildPending { self.buildPending = false; self.scheduleBuild() }
            }
        }
    }
    @objc func forwardSync() {
        guard let active, let pdf = compiledPDF, let tools else { setStatus("请先成功编译文档，再使用双向定位"); return }
        let (line, col) = ui.editor.lineColumn; let file = active.url; let token = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SyncTeX.forward(file: file, line: line, column: col, pdf: pdf, tools: tools) }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                switch result { case .success(let location): self.ui.pdfItem.isCollapsed = false; self.ui.preview.goTo(location); self.setStatus("源码 → PDF · 第 \(location.page) 页")
                case .failure(let error): self.setStatus(error.localizedDescription) }
            }
        }
    }
    func inverseSync(page: Int, x: Double, y: Double) {
        guard let pdf = compiledPDF, let root = compiledRoot, let tools else { setStatus("请先编译当前文档以生成 SyncTeX 映射"); return }
        let token = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SyncTeX.inverse(page: page, x: x, y: y, pdf: pdf, root: root, tools: tools) }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                switch result { case .success(let source): self.openFile(source.file, line: source.line, column: source.column); self.setStatus("PDF → \(source.file.lastPathComponent):\(source.line)")
                case .failure(let error): self.setStatus(error.localizedDescription) }
            }
        }
    }
    @objc func newFile() {
        guard let project else { return }
        let panel = NSSavePanel(); panel.directoryURL = project; panel.nameFieldStringValue = "section.tex"; panel.title = "新建文件"; panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { guard !FileManager.default.fileExists(atPath: url.path) else { throw BetterTeXError.message("文件已存在，请使用其他名称。") }; try "".write(to: url, atomically: true, encoding: .utf8); self?.openFile(url); self?.ui.explorer.refresh() }
            catch { self?.error(error.localizedDescription) }
        }
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
            DispatchQueue.main.async { guard let self, self.generation == token else { return }; self.ui.setGitHost(host); self.ui.setBranch(state.map { $0.branch + ($0.changes.isEmpty ? "" : " · \($0.changes.count) 项更改") } ?? "") }
        }
    }
    func git(push: Bool) {
        guard !gitBusy, saveAll(), let project, let tools else { return }
        gitBusy = true; let token = generation; let service = GitService(directory: project, tools: tools)
        setStatus("正在检查 Git 状态…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let state = Result { try service.state() }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.gitBusy = false
                switch state {
                case .failure(let error): self.error("当前目录无法执行 Git 操作。请先在 Shell 中初始化仓库并配置远端。\n\n" + error.localizedDescription)
                case .success(let state):
                    guard state.hasRemote else { self.error("仓库尚未配置远端。请在 Shell 中运行 git remote add origin <URL>，然后设置上游分支。"); return }
                    if push && !state.changes.isEmpty { self.reviewCommit(state, service: service) }
                    else { self.runGit(push ? "Push" : "Pull") { push ? try service.push() : try service.pull() } }
                }
            }
        }
    }
    func reviewCommit(_ state: GitState, service: GitService) {
        let alert = NSAlert(); alert.messageText = "提交并 Push 到远端"
        alert.informativeText = "选择本次提交文件。未跟踪文件默认不勾选；已有提交也可以直接推送。Git 认证使用本机凭据。"
        alert.addButton(withTitle: "提交并 Push"); alert.addButton(withTitle: "仅 Push 已有提交"); alert.addButton(withTitle: "取消")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 280))
        let message = NSTextField(frame: NSRect(x: 0, y: 244, width: 500, height: 26)); message.placeholderString = "提交说明，例如：完善方法章节"; container.addSubview(message)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 230)); scroll.hasVerticalScroller = true
        let rows = NSStackView(); rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 7
        var checks: [(NSButton, [String])] = []
        for change in state.changes where !change.path.contains(".bettertex/") && change.path != ".DS_Store" {
            let checkbox = NSButton(checkboxWithTitle: "[\(change.status)] \(change.path)", target: nil, action: nil)
            checkbox.font = .monospacedSystemFont(ofSize: 11, weight: .regular); checkbox.state = change.isUntracked ? .off : .on
            rows.addArrangedSubview(checkbox); checks.append((checkbox, change.commitPaths))
        }
        rows.frame = NSRect(x: 0, y: 0, width: 480, height: max(220, checks.count * 25)); scroll.documentView = rows; container.addSubview(scroll); alert.accessoryView = container
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self else { return }
            if result == .alertSecondButtonReturn { self.runGit("Push") { try service.push() } }
            else if result == .alertFirstButtonReturn {
                let paths = checks.filter { $0.0.state == .on }.flatMap { $0.1 }
                guard !message.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !paths.isEmpty else { self.error("提交说明和已选文件不能为空，请重新点击 Push。"); return }
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
                case .success(let log): self.setStatus("Git \(label) 完成"); self.ui.terminal.append("\nGit \(label)\n" + log); self.externalChanges()
                case .failure(let error): self.setStatus("Git \(label) 失败"); self.ui.terminal.append("\nGit \(label)\n" + error.localizedDescription); self.ui.showOutput(); self.error(error.localizedDescription + "\n\n如需交互式登录、设置上游分支或处理冲突，请使用 Shell 标签。")
                }
            }
        }
    }
    @objc func showTools() {
        let alert = NSAlert(); alert.messageText = "本机工具"
        alert.informativeText = ["latexmk", "pdflatex", "xelatex", "lualatex", "synctex", "codex", "claude", "git"].map { "\($0)\n  \(tools?[$0] ?? "未检测到")" }.joined(separator: "\n\n")
        alert.addButton(withTitle: "完成"); alert.addButton(withTitle: "重新检测")
        alert.beginSheetModal(for: window) { [weak self] result in if result == .alertSecondButtonReturn { self?.detectTools() } }
    }
    func setStatus(_ message: String) { ui.status.stringValue = message; ui.status.toolTip = message }
    func error(_ message: String) {
        setStatus(message.components(separatedBy: .newlines).first ?? message)
        let alert = NSAlert(); alert.messageText = "BetterTeX"; alert.informativeText = message; alert.addButton(withTitle: "好")
        if window.attachedSheet == nil { alert.beginSheetModal(for: window) }
        else { ui.terminal.append("\n" + message + "\n") }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard saveAll() else { return false }
        if !ui.terminal.terminals.isEmpty {
            let alert = NSAlert(); alert.messageText = "关闭工作区并结束终端会话？"; alert.informativeText = "运行中的 Codex、Claude 和 Shell 会话将停止。文件修改已经保存。"; alert.addButton(withTitle: "关闭"); alert.addButton(withTitle: "取消")
            if alert.runModal() != .alertFirstButtonReturn { return false }
        }
        overleaf.shutdown(); compiler.runner.cancel(); ui.terminal.stopAll(); watcher.stop(); return true
    }
    func shutdown() { overleaf.shutdown(); saveJob?.cancel(); compileJob?.cancel(); compiler.runner.cancel(); ui.terminal.stopAll(); watcher.stop() }
}
