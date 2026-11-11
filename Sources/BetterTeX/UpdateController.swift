import AppKit
import BetterTeXCore

@MainActor
final class UpdateController: NSObject {
    let currentVersion = ReleaseVersion.installed()
    private let client = AppUpdateClient()
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var panel: UpdateWindowController?
    private var available: AppRelease?
    private var prepared: PreparedAppUpdate?
    private var installer: Process?
    private var presentedVersion: String?
    private var manualCheck = false

    func start() {
        if let result = try? String(contentsOf: UpdateInstaller.resultURL, encoding: .utf8) {
            try? FileManager.default.removeItem(at: UpdateInstaller.resultURL)
            if result.trimmingCharacters(in: .whitespacesAndNewlines) == "failed" {
                showMessage(L10n.tr("更新未能完成"), L10n.tr("已保留上一版本。请重新检查更新，或从 Release 页面下载安装。"))
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkIfDue() }
    }
    func checkIfDue() {
        if UpdatePreferences.isDue() { check(userInitiated: false) }
    }
    @objc private func becameActive() {
        if UpdatePreferences.automatic(), let available, task == nil, presentedVersion != available.tagName { present(available) }
    }
    func check(userInitiated: Bool = true) {
        if userInitiated {
            manualCheck = true
            if let prepared { showReady(prepared); return }
            if task != nil { showPanel(); return }
            showMessage(L10n.tr("正在检查更新…"), L10n.tr("当前版本：\(currentVersion)"), busy: true)
        }
        guard task == nil else { return }
        UserDefaults.standard.set(Date(), forKey: UpdatePreferences.lastCheckKey)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await client.check(current: currentVersion, includePrereleases: UpdatePreferences.includesPrereleases(current: currentVersion))
                try Task.checkCancellation()
                task = nil; available = release
                if let release {
                    if manualCheck || (UpdatePreferences.automatic() && NSApp.isActive && presentedVersion != release.tagName) { present(release) }
                } else if manualCheck {
                    showMessage(L10n.tr("已是最新版本"), L10n.tr("BetterTeX \(currentVersion) 已是当前更新通道的最新版本。"))
                }
            } catch {
                task = nil
                if manualCheck && !(error is CancellationError) { showError(error) }
            }
            manualCheck = false
        }
    }
    private func present(_ release: AppRelease) {
        presentedVersion = release.tagName
        let version = release.version?.description ?? release.tagName
        let installable = release.asset() != nil
        let detail = installable
            ? L10n.tr("当前版本：\(currentVersion)。安装前会保存文件，并重新打开 BetterTeX。")
            : L10n.tr("此版本暂未提供适合当前 Mac 的自动更新安装包，请前往 Release 页面下载。")
        showPanel().configure(title: L10n.tr("发现新版本 \(version)"), detail: detail, notes: release.body ?? "",
                              primary: installable ? L10n.tr("下载并安装") : L10n.tr("打开下载页面"),
                              action: { [weak self] in
            if installable { self?.download(release) } else { NSWorkspace.shared.open(release.pageURL) }
        }, secondary: L10n.tr("稍后"), secondaryAction: { [weak self] in self?.panel?.close() },
                              releaseURL: release.pageURL)
    }
    private func download(_ release: AppRelease) {
        guard task == nil, let asset = release.asset() else { return }
        do { try UpdateInstaller.checkDestination(Bundle.main.bundleURL) }
        catch { showError(error); return }
        showMessage(L10n.tr("正在下载更新…"), L10n.tr("下载完成后将验证安装包，并保存文件、安装及重启。"), busy: true)
        panel?.setCancelAction { [weak self] in self?.task?.cancel() }
        task = Task { [weak self] in
            guard let self else { return }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeX-update-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temporary); task = nil }
            do {
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let archive = temporary.appendingPathComponent("update.zip")
                try await client.download(asset, to: archive)
                try Task.checkCancellation()
                showMessage(L10n.tr("正在验证更新…"), L10n.tr("请稍候，正在准备安装。"), busy: true)
                panel?.setCancelAction { [weak self] in self?.task?.cancel() }
                let destination = Bundle.main.bundleURL
                let update = try await Task.detached { try UpdateInstaller.prepare(archive: archive, release: release, destination: destination) }.value
                if Task.isCancelled { update.discard(); throw CancellationError() }
                prepared = update
                showReady(update)
                NSApp.terminate(nil)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    present(release)
                } else { showError(error) }
            }
        }
    }
    private func showReady(_ update: PreparedAppUpdate) {
        showPanel().configure(title: L10n.tr("更新已就绪"), detail: L10n.tr("保存文件后即可安装并重启；取消退出会保留已下载的更新。"),
                              primary: L10n.tr("安装并重启"), action: { NSApp.terminate(nil) },
                              secondary: L10n.tr("稍后"), secondaryAction: { [weak self] in self?.panel?.close() })
    }
    /// Called only after the application's save/session checks allow termination.
    func installIfReady() -> Bool {
        guard let prepared else { return true }
        do { installer = try UpdateInstaller.launch(prepared); return true }
        catch { showError(error); return false }
    }
    func stop() {
        task?.cancel(); timer?.invalidate()
        if installer == nil { prepared?.discard() }
    }
    private func showError(_ error: Error) {
        showPanel().configure(title: L10n.tr("更新失败"), detail: error.localizedDescription,
                              primary: L10n.tr("重新检查"), action: { [weak self] in self?.check() },
                              secondary: L10n.tr("关闭"), secondaryAction: { [weak self] in self?.panel?.close() },
                              releaseURL: available?.pageURL ?? AppUpdateClient.releasesURL)
    }
    private func showMessage(_ title: String, _ detail: String, busy: Bool = false) {
        showPanel().configure(title: title, detail: detail, busy: busy, secondary: L10n.tr("关闭"), secondaryAction: { [weak self] in self?.panel?.close() })
    }
    @discardableResult private func showPanel() -> UpdateWindowController {
        if panel == nil { panel = UpdateWindowController() }
        panel!.showWindow(nil); panel!.window?.makeKeyAndOrderFront(nil)
        return panel!
    }
}

@MainActor
private final class UpdateWindowController: NSWindowController {
    private let heading = Theme.label("", size: 20, weight: .bold)
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let notes = NSTextView()
    private let scroll = NSScrollView()
    private let spinner = NSProgressIndicator()
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let secondary = NSButton(title: "", target: nil, action: nil)
    private let release = NSButton(title: L10n.tr("查看发行说明"), target: nil, action: nil)
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?
    private var releaseURL: URL?
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L10n.tr("软件更新"); window.isReleasedWhenClosed = false; window.center()
        detail.font = .systemFont(ofSize: 13); detail.textColor = .secondaryLabelColor
        heading.setContentCompressionResistancePriority(.required, for: .vertical)
        detail.setContentCompressionResistancePriority(.required, for: .vertical)
        spinner.style = .spinning; spinner.controlSize = .small
        notes.isEditable = false; notes.isSelectable = true; notes.isRichText = false
        notes.font = .systemFont(ofSize: 12); notes.textColor = .labelColor
        notes.drawsBackground = false; notes.textContainerInset = NSSize(width: 8, height: 8)
        notes.autoresizingMask = [.width]; notes.textContainer?.widthTracksTextView = true
        scroll.documentView = notes; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 210).isActive = true
        for button in [primary, secondary, release] { button.bezelStyle = .rounded; button.target = self }
        primary.action = #selector(primaryClicked); secondary.action = #selector(secondaryClicked); release.action = #selector(releaseClicked)
        primary.keyEquivalent = "\r"; secondary.keyEquivalent = "\u{1b}"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [release, spacer, secondary, primary]); buttons.spacing = 8
        let titleRow = NSStackView(views: [spinner, heading]); titleRow.spacing = 10
        let content = NSStackView(views: [titleRow, detail, scroll, buttons])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 16; content.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(); window.contentView = root; root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 24), content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
            detail.widthAnchor.constraint(equalTo: content.widthAnchor), scroll.widthAnchor.constraint(equalTo: content.widthAnchor), buttons.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(title: String, detail: String, notes: String = "", busy: Bool = false, primary: String? = nil, action: (() -> Void)? = nil,
                   secondary: String, secondaryAction: (() -> Void)?, releaseURL: URL? = nil) {
        heading.stringValue = title; self.detail.stringValue = detail; self.notes.string = notes
        self.primary.title = primary ?? ""; self.primary.isHidden = primary == nil; primaryAction = action
        self.secondary.title = secondary; self.secondaryAction = secondaryAction
        self.releaseURL = releaseURL; release.isHidden = releaseURL == nil
        scroll.isHidden = notes.isEmpty; spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        window?.setContentSize(NSSize(width: 560, height: notes.isEmpty ? 200 : 440))
    }
    func setCancelAction(_ action: @escaping () -> Void) { secondary.title = L10n.tr("取消"); secondaryAction = action }
    @objc private func primaryClicked() { primaryAction?() }
    @objc private func secondaryClicked() { secondaryAction?() }
    @objc private func releaseClicked() { if let releaseURL { NSWorkspace.shared.open(releaseURL) } }
}
