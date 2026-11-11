import AppKit
import BetterTeXCore

final class SettingsWindowController: NSWindowController {
    private let languagePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let restartHint = NSTextField(wrappingLabelWithString: "")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 230),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L10n.tr("设置")
        window.isReleasedWhenClosed = false
        window.center()

        let heading = Theme.label(L10n.tr("语言"), size: 20, weight: .bold)
        let label = Theme.label(L10n.tr("界面语言"))
        languagePicker.addItems(withTitles: [L10n.tr("跟随系统"), "简体中文", "English"])
        languagePicker.selectItem(at: AppLanguage.allCases.firstIndex(of: .saved()) ?? 0)
        languagePicker.target = self; languagePicker.action = #selector(languageChanged)
        languagePicker.setAccessibilityLabel(L10n.tr("界面语言"))
        languagePicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        let row = NSStackView(views: [label, languagePicker]); row.spacing = 16; row.alignment = .centerY

        restartHint.font = .systemFont(ofSize: 12)
        restartHint.textColor = .secondaryLabelColor
        restartHint.stringValue = L10n.tr("更改语言后，重新打开 BetterTeX 即可生效。")
        let content = NSStackView(views: [heading, row, restartHint])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 20
        content.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(); window.contentView = root; root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            restartHint.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func languageChanged() {
        let index = languagePicker.indexOfSelectedItem
        guard AppLanguage.allCases.indices.contains(index) else { return }
        AppLanguage.allCases[index].save()
    }
}
