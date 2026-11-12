import AppKit
import BetterTeXCore

final class SettingsWindowController: NSWindowController {
    private let languagePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let restartHint = NSTextField(wrappingLabelWithString: "")
    private let themePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let schemePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let automatic = NSButton(checkboxWithTitle: L10n.tr("自动检查更新"), target: nil, action: nil)
    private let prereleases = NSButton(checkboxWithTitle: L10n.tr("接收预发布版本（alpha / beta）"), target: nil, action: nil)
    private let onCheckForUpdates: @MainActor () -> Void
    private var fontFamilies: [String] = []

    init(onCheckForUpdates: @escaping @MainActor () -> Void) {
        self.onCheckForUpdates = onCheckForUpdates
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L10n.tr("设置")
        window.isReleasedWhenClosed = false

        let preferences = AppearancePreferences.saved()
        let heading = Theme.label(L10n.tr("语言"), size: 20, weight: .bold)
        languagePicker.addItems(withTitles: [L10n.tr("跟随系统"), "简体中文", "English"])
        languagePicker.selectItem(at: AppLanguage.allCases.firstIndex(of: .saved()) ?? 0)
        languagePicker.target = self; languagePicker.action = #selector(languageChanged)
        let row = Self.row(L10n.tr("界面语言"), languagePicker)

        restartHint.font = .systemFont(ofSize: 12)
        restartHint.textColor = .secondaryLabelColor
        restartHint.stringValue = L10n.tr("更改语言后，重新打开 BetterTeX 即可生效。")

        let appearanceHeading = Theme.label(L10n.tr("外观"), size: 20, weight: .bold)
        themePicker.addItems(withTitles: [L10n.tr("跟随系统"), L10n.tr("浅色"), L10n.tr("深色")])
        themePicker.selectItem(at: AppTheme.allCases.firstIndex(of: preferences.theme) ?? 0)
        themePicker.target = self; themePicker.action = #selector(appearanceChanged)

        fontFamilies = Theme.monospacedFamilies()
        if !preferences.fontName.isEmpty, !fontFamilies.contains(preferences.fontName) { fontFamilies.insert(preferences.fontName, at: 0) }
        fontPicker.addItem(withTitle: L10n.tr("系统等宽字体"))
        fontPicker.menu?.addItem(.separator())
        for family in fontFamilies {
            fontPicker.addItem(withTitle: family)
            if let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13) {
                fontPicker.lastItem?.attributedTitle = NSAttributedString(string: family, attributes: [.font: font])
            }
        }
        if let index = fontFamilies.firstIndex(of: preferences.fontName) { fontPicker.selectItem(at: index + 2) } else { fontPicker.selectItem(at: 0) }
        fontPicker.target = self; fontPicker.action = #selector(appearanceChanged)

        let sizes = AppearancePreferences.sizes.contains(preferences.fontSize) ? AppearancePreferences.sizes : (AppearancePreferences.sizes + [preferences.fontSize]).sorted()
        for size in sizes { sizePicker.addItem(withTitle: Self.format(size)); sizePicker.lastItem?.representedObject = size }
        sizePicker.selectItem(withTitle: Self.format(preferences.fontSize))
        sizePicker.target = self; sizePicker.action = #selector(appearanceChanged)

        schemePicker.addItems(withTitles: EditorColorScheme.allCases.map(Self.title))
        schemePicker.selectItem(at: EditorColorScheme.allCases.firstIndex(of: preferences.colorScheme) ?? 0)
        schemePicker.target = self; schemePicker.action = #selector(appearanceChanged)

        let updateHeading = Theme.label(L10n.tr("软件更新"), size: 20, weight: .bold)
        let version = Theme.label(L10n.tr("当前版本：\(ReleaseVersion.installed())"), size: 12)
        automatic.state = UpdatePreferences.automatic() ? .on : .off
        automatic.target = self; automatic.action = #selector(automaticChanged)
        prereleases.state = UpdatePreferences.includesPrereleases(current: ReleaseVersion.installed()) ? .on : .off
        prereleases.target = self; prereleases.action = #selector(prereleasesChanged)
        let check = NSButton(title: L10n.tr("检查更新…"), target: self, action: #selector(checkForUpdates)); check.bezelStyle = .rounded
        let updateRow = NSStackView(views: [version, check]); updateRow.spacing = 20
        let content = NSStackView(views: [
            heading, row, restartHint,
            appearanceHeading, Self.row(L10n.tr("应用主题"), themePicker), Self.row(L10n.tr("编辑器字体"), fontPicker),
            Self.row(L10n.tr("字号"), sizePicker), Self.row(L10n.tr("配色方案"), schemePicker),
            updateHeading, automatic, prereleases, updateRow
        ])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 16
        content.setCustomSpacing(28, after: restartHint); content.setCustomSpacing(28, after: content.views[7])
        content.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(); window.contentView = root; root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            restartHint.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A label of fixed width beside a picker, so the pickers line up in a column.
    private static func row(_ title: String, _ picker: NSPopUpButton) -> NSStackView {
        let label = Theme.label(title); label.lineBreakMode = .byClipping; label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        picker.setAccessibilityLabel(title)
        picker.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let row = NSStackView(views: [label, picker]); row.spacing = 16; row.alignment = .centerY
        return row
    }
    private static func format(_ size: Double) -> String { size == size.rounded() ? "\(Int(size)) pt" : "\(size) pt" }
    private static func title(_ scheme: EditorColorScheme) -> String {
        switch scheme {
        case .standard: return L10n.tr("默认")
        case .github: return "GitHub"
        case .solarized: return "Solarized"
        case .tomorrow: return "Tomorrow"
        }
    }

    @objc private func checkForUpdates() { onCheckForUpdates() }
    @objc private func automaticChanged() { UpdatePreferences.setAutomatic(automatic.state == .on) }
    @objc private func prereleasesChanged() { UpdatePreferences.setIncludesPrereleases(prereleases.state == .on) }

    @objc private func appearanceChanged() {
        var preferences = AppearancePreferences.saved()
        if AppTheme.allCases.indices.contains(themePicker.indexOfSelectedItem) { preferences.theme = AppTheme.allCases[themePicker.indexOfSelectedItem] }
        let fontIndex = fontPicker.indexOfSelectedItem - 2
        preferences.fontName = fontFamilies.indices.contains(fontIndex) ? fontFamilies[fontIndex] : ""
        if let size = sizePicker.selectedItem?.representedObject as? Double { preferences.fontSize = size }
        if EditorColorScheme.allCases.indices.contains(schemePicker.indexOfSelectedItem) { preferences.colorScheme = EditorColorScheme.allCases[schemePicker.indexOfSelectedItem] }
        preferences.save()
        Theme.applyAppTheme(preferences.theme)
    }

    @objc private func languageChanged() {
        let index = languagePicker.indexOfSelectedItem
        guard AppLanguage.allCases.indices.contains(index) else { return }
        AppLanguage.allCases[index].save()
    }
}
