import Foundation

/// Light, dark or follow the system.
public enum AppTheme: String, CaseIterable {
    case system, light, dark
}

/// Syntax-colour palettes for the editor; each has light and dark variants.
public enum EditorColorScheme: String, CaseIterable {
    case standard = "default", github, solarized, tomorrow
}

/// Interface theme and editor font, size and colour scheme, persisted in user defaults.
public struct AppearancePreferences: Equatable {
    public static let changed = Notification.Name("BetterTeX.AppearancePreferencesChanged")
    public static let sizes: [Double] = [10, 11, 12, 12.5, 13, 14, 15, 16, 18, 20, 22, 24]
    public static let defaultFontSize = 12.5
    static let themeKey = "appearance.theme", fontKey = "editor.fontName", sizeKey = "editor.fontSize", schemeKey = "editor.colorScheme"

    public var theme: AppTheme = .system
    /// A font family name; empty means the system monospaced font.
    public var fontName = ""
    public var fontSize = AppearancePreferences.defaultFontSize
    public var colorScheme: EditorColorScheme = .standard

    public init() {}

    public static func saved(in defaults: UserDefaults = .standard) -> AppearancePreferences {
        var value = AppearancePreferences()
        value.theme = AppTheme(rawValue: defaults.string(forKey: themeKey) ?? "") ?? .system
        value.fontName = defaults.string(forKey: fontKey) ?? ""
        let size = defaults.double(forKey: sizeKey)
        value.fontSize = size > 0 ? min(max(size, 8), 36) : defaultFontSize
        value.colorScheme = EditorColorScheme(rawValue: defaults.string(forKey: schemeKey) ?? "") ?? .standard
        return value
    }

    public func save(in defaults: UserDefaults = .standard) {
        defaults.set(theme.rawValue, forKey: Self.themeKey)
        defaults.set(fontName, forKey: Self.fontKey)
        defaults.set(fontSize, forKey: Self.sizeKey)
        defaults.set(colorScheme.rawValue, forKey: Self.schemeKey)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Line height that keeps the default 12.5 pt / 22 pt rhythm at other sizes.
    public var lineHeight: Double { (fontSize * 1.76).rounded() }
    public var baselineOffset: Double { (fontSize * 0.24).rounded() }
}
