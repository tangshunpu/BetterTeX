import AppKit
import BetterTeXCore

extension WorkspaceController {
    /// Clones a Git repository (GitHub `owner/repo` shorthand or any Git URL) and opens it.
    func cloneRepository() {
        guard let git = tools?["git"], let environment = tools?.environment else { error("未检测到 Git，请先安装 Xcode Command Line Tools。"); return }
        let alert = NSAlert(); alert.messageText = "从 GitHub 克隆项目"
        alert.informativeText = "输入仓库地址或 owner/repo。私有仓库使用本机已有的 Git 凭据或 SSH 密钥。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); field.placeholderString = "https://github.com/owner/repo 或 owner/repo"
        alert.accessoryView = field; alert.addButton(withTitle: "选择位置并克隆"); alert.addButton(withTitle: "取消"); alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var address = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.hasPrefix("-") else { return }
        if address.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil { address = "https://github.com/\(address).git" }
        var name = (address as NSString).lastPathComponent; if name.hasSuffix(".git") { name.removeLast(4) }
        if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
        guard !name.isEmpty else { error("无法从地址中识别仓库名称。"); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "克隆到这里"; panel.message = "将在所选位置新建「\(name)」文件夹。"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let target = parent.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { error("「\(target.path)」已存在，请换一个位置。"); return }
        setStatus("正在克隆 \(name)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var env = environment; env["GIT_TERMINAL_PROMPT"] = "0"; env["GCM_INTERACTIVE"] = "never"
            let result = Result { try ProcessRunner().run(git, ["clone", "--", address, target.path], directory: parent, environment: env, timeout: 600) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let output) where output.succeeded:
                    self.ui.terminal.append("\nGit clone\n" + output.output)
                    if self.confirmSwitch() { self.loadProject(target); self.setStatus("已克隆 \(name)") } else { self.setStatus("已克隆到 \(target.path)") }
                case .success(let output): self.error("克隆失败。\n\n" + output.output + "\n\n如需登录，请先在 Shell 标签中配置 Git 凭据。")
                case .failure(let failure): self.error(failure.localizedDescription)
                }
            }
        }
    }
}
