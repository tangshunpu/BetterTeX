import XCTest
@testable import BetterTeXCore

final class LocalizationTests: XCTestCase {
    func testSystemLanguageResolutionAndExplicitOverride() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-CN", "en-US"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh_Hant_TW"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en-SG", "zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "zh-Hans"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: []), .english)
        XCTAssertEqual(AppLanguage.english.resolved(preferredLanguages: ["zh-CN"]), .english)
        XCTAssertEqual(AppLanguage.simplifiedChinese.resolved(preferredLanguages: ["en-US"]), .simplifiedChinese)
    }

    func testPreferencePersistsForNextLaunchAndSystemClearsNativeOverride() throws {
        let name = "BetterTeX.LocalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppLanguage.saved(in: defaults), .system)
        let currentLaunch = Localizer(language: .simplifiedChinese)
        AppLanguage.english.save(in: defaults)
        let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: name))
        XCTAssertEqual(AppLanguage.saved(in: reopenedDefaults), .english)
        XCTAssertEqual(reopenedDefaults.stringArray(forKey: "AppleLanguages"), ["en"])
        let nextLaunch = Localizer(language: .saved(in: reopenedDefaults))
        XCTAssertEqual(nextLaunch.string("设置"), "Settings")
        XCTAssertEqual(currentLaunch.string("设置"), "设置")
        AppLanguage.simplifiedChinese.save(in: defaults)
        XCTAssertEqual(AppLanguage.saved(in: defaults), .simplifiedChinese)
        AppLanguage.system.save(in: defaults)
        XCTAssertEqual(AppLanguage.saved(in: defaults), .system)
        XCTAssertNil(defaults.persistentDomain(forName: name)?["AppleLanguages"])
        defaults.set("unsupported-language", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.saved(in: defaults), .system)
    }

    func testBothLanguagesAndInterpolatedValues() {
        let english = Localizer(language: .english)
        let chinese = Localizer(language: .simplifiedChinese)
        XCTAssertEqual(english.string("全部项目"), "All Projects")
        XCTAssertEqual(chinese.string("全部项目"), "全部项目")
        XCTAssertEqual(english.string("第 \(2) 页，共 \(10) 页"), "Page 2 of 10")
        XCTAssertEqual(chinese.string("第 \(2) 页，共 \(10) 页"), "第 2 页，共 10 页")
        let path = "中文 project/50% %@ \"paper\" 📝.tex"
        XCTAssertEqual(english.string("已导出 \(path)"), "Exported " + path)
        XCTAssertEqual(chinese.string("已导出 \(path)"), "已导出 " + path)
        XCTAssertEqual(english.string("未知错误"), "Unknown error")
        XCTAssertEqual(english.string("Overleaf 未能创建项目：\(english.string("未知错误"))"), "Overleaf could not create the project: Unknown error")
    }

    func testFallbackAndLiteralPercentSigns() {
        let localizer = Localizer(language: .english)
        XCTAssertEqual(localizer.string("Untranslated key"), "Untranslated key")
        XCTAssertEqual(localizer.string("Progress 50%: \("a %@ file")"), "Progress 50%: a %@ file")
        XCTAssertEqual(localizer.string("100%"), "100%")
        XCTAssertEqual(localizer.string("检测到循环的 % !TeX root 指令。"), "Circular % !TeX root directives detected.")
    }

    func testCatalogsHaveMatchingKeysAndFormatSpecifiers() throws {
        func catalog(_ language: AppLanguage) throws -> [String: String] {
            let url = try XCTUnwrap(Localizer(language: language).bundle.url(forResource: "Localizable", withExtension: "strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        }
        let english = try catalog(.english), chinese = try catalog(.simplifiedChinese)
        XCTAssertGreaterThan(english.count, 500)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        let placeholders = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:\.\d+)?[@df]"#)
        func formats(_ value: String) -> [String] {
            placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value))
                .map { (value as NSString).substring(with: $0.range) }.sorted()
        }
        for (key, translation) in english {
            XCTAssertFalse(translation.isEmpty, key)
            XCTAssertEqual(formats(key), formats(translation), key)
            XCTAssertEqual(chinese[key], key)
        }
        // Language preferences must never alter on-disk conflict markers.
        XCTAssertEqual(Merge3.oursMarker, "<<<<<<< BetterTeX（本地）")
    }
}
