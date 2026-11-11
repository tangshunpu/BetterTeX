import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var workspace: WorkspaceController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        #if DEBUG
        // Preview either appearance without changing the user's system preference.
        if let appearance = ProcessInfo.processInfo.environment["BETTERTEX_TEST_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        #endif
        setupMenu(); workspace = WorkspaceController(); workspace.show()
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        return workspace.window.isVisible && !workspace.windowShouldClose(workspace.window) ? .terminateCancel : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { workspace?.shutdown() }
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
        add(app, "关于 BetterTeX", #selector(about)); app.addItem(.separator()); add(app, "隐藏 BetterTeX", #selector(NSApplication.hide(_:)), "h"); app.addItem(.separator()); add(app, "退出 BetterTeX", #selector(NSApplication.terminate(_:)), "q")
        let file = submenu("文件")
        let create = NSMenu(title: "新建项目"); let createItem = NSMenuItem(title: "新建项目", action: nil, keyEquivalent: ""); createItem.submenu = create; file.addItem(createItem)
        add(create, "从本地文件夹…", #selector(open)); add(create, "从 GitHub 克隆…", #selector(cloneRepository)); add(create, "从 Overleaf 导入…", #selector(importOverleaf))
        add(file, "打开文件夹…", #selector(open), "o", modifiers: [.command, .shift]); add(file, "新建文件…", #selector(newFile), "n"); add(file, "保存全部", #selector(save), "s"); add(file, "关闭标签", #selector(closeTab), "w"); add(file, "关闭项目", #selector(closeProject)); add(file, "关闭窗口", #selector(NSWindow.performClose(_:)), "w", modifiers: [.command, .shift])
        let edit = submenu("编辑")
        add(edit, "撤销", Selector(("undo:")), "z"); add(edit, "重做", Selector(("redo:")), "z", modifiers: [.command, .shift]); edit.addItem(.separator())
        add(edit, "剪切", #selector(NSText.cut(_:)), "x"); add(edit, "复制", #selector(NSText.copy(_:)), "c"); add(edit, "粘贴", #selector(NSText.paste(_:)), "v"); add(edit, "全选", #selector(NSText.selectAll(_:)), "a"); add(edit, "查找…", #selector(find), "f")
        let insert = submenu("插入")
        let shortcuts: [Snippet: (String, NSEvent.ModifierFlags)] = [.image: ("i", [.command, .shift]), .itemize: ("l", [.command, .shift]), .equation: ("m", [.command, .shift]), .bold: ("b", .command), .italic: ("i", .command)]
        for snippet in Snippet.allCases {
            let item = NSMenuItem(title: snippet == .image ? "图片…" : snippet.title, action: #selector(insertSnippet(_:)), keyEquivalent: shortcuts[snippet]?.0 ?? "")
            item.keyEquivalentModifierMask = shortcuts[snippet]?.1 ?? .command; item.tag = snippet.rawValue
            item.image = NSImage(systemSymbolName: snippet.symbol, accessibilityDescription: nil); insert.addItem(item)
            if snippet == .image || snippet == .section { insert.addItem(.separator()) }
        }
        let view = submenu("显示")
        add(view, "搜索文件或章节", #selector(focusSearch), "k"); view.addItem(.separator()); add(view, "显示 / 隐藏边栏", #selector(toggleSidebar), "s", modifiers: [.command, .control]); add(view, "PDF 预览", #selector(togglePDF), "p", modifiers: [.command, .option]); add(view, "Agent / 终端面板", #selector(toggleTerminal), "j"); view.addItem(.separator()); add(view, "恢复默认布局", #selector(resetLayout)); view.addItem(.separator()); add(view, "进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])
        let project = submenu("工作区")
        add(project, "编译 / 停止", #selector(build), "\r"); add(project, "在 PDF 中定位", #selector(sync), "j", modifiers: [.command, .shift]); project.addItem(.separator()); add(project, "与 Overleaf 同步", #selector(syncOverleaf), "y", modifiers: [.command, .shift]); add(project, "把当前项目上传到 Overleaf…", #selector(exportOverleaf)); add(project, "邀请合作者…", #selector(inviteOverleaf)); project.addItem(.separator()); add(project, "本机工具…", #selector(showTools)); add(project, "重新检测工具", #selector(detectTools))
        let window = submenu("窗口"); add(window, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m"); add(window, "缩放", #selector(NSWindow.performZoom(_:))); NSApp.windowsMenu = window
        NSApp.mainMenu = menu
    }
    @objc func open() { workspace.openFolder() }
    @objc func newFile() { workspace.newFile() }
    @objc func closeProject() { workspace.closeProject() }
    @objc func cloneRepository() { workspace.cloneRepository() }
    @objc func importOverleaf() { workspace.overleaf.importProject() }
    @objc func exportOverleaf() { if workspace.overleaf.link == nil { workspace.overleaf.exportProject() } else { workspace.setStatus("当前项目已关联 Overleaf") } }
    @objc func syncOverleaf() { if workspace.overleaf.link == nil { workspace.setStatus("当前项目尚未关联 Overleaf") } else { workspace.overleaf.sync(userInitiated: true) } }
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
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "BetterTeX", .applicationVersion: "0.1.0", .credits: NSAttributedString(string: "A quiet workspace for your next idea.\nNative LaTeX editor · PDFKit · SwiftTerm")]) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
