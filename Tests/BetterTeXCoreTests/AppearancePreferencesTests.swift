import XCTest
@testable import BetterTeXCore

final class AppearancePreferencesTests: XCTestCase {
    func testDefaultsRoundTripAndClamping() throws {
        let name = "BetterTeX.AppearancePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppearancePreferences.saved(in: defaults), AppearancePreferences())
        XCTAssertEqual(AppearancePreferences().lineHeight, 22)
        XCTAssertEqual(AppearancePreferences().baselineOffset, 3)
        var value = AppearancePreferences()
        value.theme = .dark; value.fontName = "Menlo"; value.fontSize = 16; value.colorScheme = .solarized
        value.save(in: defaults)
        XCTAssertEqual(AppearancePreferences.saved(in: defaults), value)
        defaults.set(200.0, forKey: AppearancePreferences.sizeKey)
        defaults.set("bogus", forKey: AppearancePreferences.themeKey)
        let clamped = AppearancePreferences.saved(in: defaults)
        XCTAssertEqual(clamped.fontSize, 36)
        XCTAssertEqual(clamped.theme, .system)
    }
}
