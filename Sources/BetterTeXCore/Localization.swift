import Foundation

public enum AppLanguage: String, CaseIterable {
    case system, simplifiedChinese = "zh-Hans", english = "en"

    public static let preferenceKey = "interface.language"

    public static func saved(in defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .system
    }

    public func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
        // Keep native AppKit panels in the same language on the next launch.
        // Removing the app override restores the system's language preferences.
        if self == .system { defaults.removeObject(forKey: "AppleLanguages") }
        else { defaults.set([rawValue], forKey: "AppleLanguages") }
    }

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        for identifier in preferredLanguages {
            let language = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first
            if language == "zh" { return .simplifiedChinese }
            if language == "en" { return .english }
        }
        return .english
    }
}

/// Keeps interpolated values out of lookup keys, and lets translations reorder them.
/// Usage: L10n.tr("第 \(page) 页，共 \(count) 页"). Values are never translated.
public struct LocalizedText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]

    public init(stringLiteral value: String) { key = value; arguments = [] }
    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount)
        }
        public mutating func appendLiteral(_ literal: String) {
            key += literal.replacingOccurrences(of: "%", with: "%%")
        }
        public mutating func appendInterpolation<T>(_ value: T) {
            arguments.append(String(describing: value)); key += "%\(arguments.count)$@"
        }
    }
}

public struct Localizer {
    public let language: AppLanguage
    public var locale: Locale { Locale(identifier: language.rawValue) }
    let bundle: Bundle

    public init(language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.init(language: language, preferredLanguages: preferredLanguages, resourceBundle: AppResources.bundle)
    }

    init(language: AppLanguage, preferredLanguages: [String], resourceBundle: Bundle?) {
        self.language = language.resolved(preferredLanguages: preferredLanguages)
        // Explicit sub-bundle lookup supports an app preference independent of the OS language.
        bundle = resourceBundle?.url(forResource: self.language.rawValue, withExtension: "lproj")
            .flatMap(Bundle.init(url:)) ?? resourceBundle ?? .main
    }

    public func string(_ text: LocalizedText) -> String {
        let format = bundle.localizedString(forKey: text.key, value: text.key, table: nil)
        guard !text.arguments.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: text.arguments.map { $0 as CVarArg })
    }
}

public enum L10n {
    // One immutable language per launch avoids mixed-language UI and does not rebuild
    // editors or interrupt running terminals when the user changes the preference.
    public static let current = Localizer(language: AppLanguage.saved())
    public static var locale: Locale { current.locale }
    public static func tr(_ text: LocalizedText) -> String { current.string(text) }
}
