import AppKit
import BetterTeXCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var workspace: WorkspaceController!
    private var settings: SettingsWindowController?
    private let updates = UpdateController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        #if DEBUG
        // Preview either appearance without changing the user's system preference.
        if let appearance = ProcessInfo.processInfo.environment["BETTERTEX_TEST_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        #endif
        setupMenu(); workspace = WorkspaceController(); workspace.show()
        #if DEBUG
        // Render the window to a PNG and quit, so the interface can be checked without a visible screen.
        if let path = ProcessInfo.processInfo.environment["BETTERTEX_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [workspace] in
                guard let view = workspace?.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)); exit(0)
            }
        }
        #endif
        NSApp.activate(ignoringOtherApps: true)
        updates.start()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        guard !workspace.window.isVisible || workspace.prepareToClose() else {
            updates.cancelInstallationRequest(); return .terminateCancel
        }
        return updates.installIfRequested() ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { updates.stop(); workspace?.shutdown() }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard let first = filenames.first, let workspace else { sender.reply(toOpenOrPrint: .failure); return }
        let url = URL(fileURLWithPath: first); var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: first, isDirectory: &isDirectory)
        guard workspace.saveAll() else { sender.reply(toOpenOrPrint: .cancel); return }
        workspace.loadProject(isDirectory.boolValue ? url : url.deletingLastPathComponent())
        if !isDirectory.boolValue { workspace.openFile(url) }
        sender.reply(toOpenOrPrint: .success)
    }
    func setupMenu() {
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu { let item = NSMenuItem(); let sub = NSMenu(title: title); item.submenu = sub; menu.addItem(item); return sub }
        func add(_ menu: NSMenu, _ title: String, _ selector: Selector, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.keyEquivalentModifierMask = modifiers; menu.addItem(item)
        }
        let app = submenu("BetterTeX")
        add(app, L10n.tr("设置…"), #selector(showSettings), ","); app.addItem(.separator())
        add(app, L10n.tr("检查更新…"), #selector(checkForUpdates))
        add(app, L10n.tr("关于 BetterTeX"), #selector(about)); app.addItem(.separator()); add(app, L10n.tr("隐藏 BetterTeX"), #selector(NSApplication.hide(_:)), "h"); app.addItem(.separator()); add(app, L10n.tr("退出 BetterTeX"), #selector(NSApplication.terminate(_:)), "q")
        let file = submenu(L10n.tr("文件"))
        let create = NSMenu(title: L10n.tr("新建项目")); let createItem = NSMenuItem(title: L10n.tr("新建项目"), action: nil, keyEquivalent: ""); createItem.submenu = create; file.addItem(createItem)
        add(create, L10n.tr("从本地文件夹…"), #selector(open)); add(create, L10n.tr("从 GitHub 克隆…"), #selector(cloneRepository)); add(create, L10n.tr("从 Overleaf 导入…"), #selector(importOverleaf))
        add(file, L10n.tr("所有项目"), #selector(closeProject), "p", modifiers: [.command, .shift]); add(file, L10n.tr("打开文件夹…"), #selector(open), "o", modifiers: [.command, .shift]); add(file, L10n.tr("新建文件…"), #selector(newFile), "n"); add(file, L10n.tr("保存全部"), #selector(save), "s"); add(file, L10n.tr("关闭标签"), #selector(closeTab), "w"); add(file, L10n.tr("关闭项目"), #selector(closeProject)); add(file, L10n.tr("关闭窗口"), #selector(NSWindow.performClose(_:)), "w", modifiers: [.command, .shift])
        let edit = submenu(L10n.tr("编辑"))
        add(edit, L10n.tr("撤销"), Selector(("undo:")), "z"); add(edit, L10n.tr("重做"), Selector(("redo:")), "z", modifiers: [.command, .shift]); edit.addItem(.separator())
        add(edit, L10n.tr("剪切"), #selector(NSText.cut(_:)), "x"); add(edit, L10n.tr("复制"), #selector(NSText.copy(_:)), "c"); add(edit, L10n.tr("粘贴"), #selector(NSText.paste(_:)), "v"); add(edit, L10n.tr("全选"), #selector(NSText.selectAll(_:)), "a"); add(edit, L10n.tr("查找…"), #selector(find), "f")
        let insert = submenu(L10n.tr("插入"))
        let shortcuts: [Snippet: (String, NSEvent.ModifierFlags)] = [.image: ("i", [.command, .shift]), .itemize: ("l", [.command, .shift]), .equation: ("m", [.command, .shift]), .bold: ("b", .command), .italic: ("i", .command)]
        for snippet in Snippet.allCases {
            let item = NSMenuItem(title: snippet == .image ? L10n.tr("图片…") : snippet.title, action: #selector(insertSnippet(_:)), keyEquivalent: shortcuts[snippet]?.0 ?? "")
            item.keyEquivalentModifierMask = shortcuts[snippet]?.1 ?? .command; item.tag = snippet.rawValue
            item.image = NSImage(systemSymbolName: snippet.symbol, accessibilityDescription: nil); insert.addItem(item)
            if snippet == .image || snippet == .section { insert.addItem(.separator()) }
        }
        let view = submenu(L10n.tr("显示"))
        add(view, L10n.tr("搜索文件或章节"), #selector(focusSearch), "k"); view.addItem(.separator()); add(view, L10n.tr("显示 / 隐藏边栏"), #selector(toggleSidebar), "s", modifiers: [.command, .control]); add(view, L10n.tr("PDF 预览"), #selector(togglePDF), "p", modifiers: [.command, .option]); add(view, L10n.tr("Agent / 终端面板"), #selector(toggleTerminal), "j"); view.addItem(.separator()); add(view, L10n.tr("恢复默认布局"), #selector(resetLayout)); view.addItem(.separator()); add(view, L10n.tr("进入全屏幕"), #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])
        let project = submenu(L10n.tr("工作区"))
        add(project, L10n.tr("编译 / 停止"), #selector(build), "\r"); add(project, L10n.tr("在 PDF 中定位"), #selector(sync), "j", modifiers: [.command, .shift]); project.addItem(.separator()); add(project, L10n.tr("与 Overleaf 同步"), #selector(syncOverleaf), "y", modifiers: [.command, .shift]); add(project, L10n.tr("把当前项目上传到 Overleaf…"), #selector(exportOverleaf)); add(project, L10n.tr("邀请合作者…"), #selector(inviteOverleaf)); project.addItem(.separator()); add(project, L10n.tr("本机工具…"), #selector(showTools)); add(project, L10n.tr("重新检测工具"), #selector(detectTools))
        let window = submenu(L10n.tr("窗口")); add(window, L10n.tr("最小化"), #selector(NSWindow.performMiniaturize(_:)), "m"); add(window, L10n.tr("缩放"), #selector(NSWindow.performZoom(_:))); NSApp.windowsMenu = window
        NSApp.mainMenu = menu
    }
    @objc func showSettings() {
        if settings == nil { settings = SettingsWindowController(onCheckForUpdates: { [weak self] in self?.updates.check() }) }
        settings?.showWindow(nil); settings?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func checkForUpdates() { updates.check() }
    @objc func open() { workspace.openFolder() }
    @objc func newFile() { workspace.newFile() }
    @objc func closeProject() { workspace.closeProject() }
    @objc func cloneRepository() { workspace.cloneRepository() }
    @objc func importOverleaf() { workspace.overleaf.importProject() }
    @objc func exportOverleaf() { if workspace.overleaf.link == nil { workspace.overleaf.exportProject() } else { workspace.setStatus(L10n.tr("当前项目已关联 Overleaf")) } }
    @objc func syncOverleaf() { if workspace.overleaf.link == nil { workspace.setStatus(L10n.tr("当前项目尚未关联 Overleaf")) } else { workspace.overleaf.sync(userInitiated: true) } }
    @objc func inviteOverleaf() { workspace.overleaf.invite() }
    @objc func save() { if workspace.saveAll(), workspace.ui.autoBuildEnabled { workspace.scheduleBuild() } }
    @objc func closeTab() { if let active = workspace.active { workspace.closeTab(active.url) } }
    @objc func build() { workspace.buildClicked() }
    @objc func sync() { workspace.forwardSync() }
    @objc func toggleTerminal() { workspace.ui.toggleTerminal() }
    @objc func insertSnippet(_ sender: NSMenuItem) { if let snippet = Snippet(rawValue: sender.tag) { workspace.ui.editor.insert(snippet) } }
    @objc func togglePDF() { workspace.ui.togglePDF() }
    @objc func toggleSidebar() { workspace.ui.toggleSidebar() }
    @objc func focusSearch() { workspace.ui.search.focus() }
    @objc func resetLayout() { workspace.ui.resetLayout() }
    @objc func showTools() { workspace.showTools() }
    @objc func detectTools() { workspace.detectTools() }
    @objc func find() { let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue; workspace.window.makeFirstResponder(workspace.ui.editor.textView); workspace.ui.editor.textView.performFindPanelAction(item) }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "BetterTeX", .applicationVersion: ReleaseVersion.installed(), .credits: NSAttributedString(string: "A quiet workspace for your next idea.\nNative LaTeX editor · PDFKit · SwiftTerm")]) }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
