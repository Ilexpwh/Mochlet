import XCTest
@testable import Mochlet

@MainActor
final class AppSmokeTests: XCTestCase {
    func testSettingsDefaults() {
        let d = UserDefaults(suiteName: "com.ilexpwh.Mochlet.tests")!
        d.removePersistentDomain(forName: "com.ilexpwh.Mochlet.tests")
        let s = SettingsStore(defaults: d)
        XCTAssertEqual(s.character.paletteName, "rimuru")
        XCTAssertEqual(s.character.appearance, .rimuru)
        XCTAssertTrue(s.soundEnabled)
        XCTAssertEqual(s.autoCloseSeconds, 15, accuracy: 0.01)
    }

    func testCharacterPersistsAndMigrates() {
        let name = "com.ilexpwh.Mochlet.tests.character"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        // 2.0 kept only a palette name.
        d.set("ruby", forKey: "themeName")
        let s = SettingsStore(defaults: d)
        XCTAssertEqual(s.character.paletteName, "ruby")
        XCTAssertEqual(s.character.palette, .ruby)
        // Edits round-trip through the JSON blob.
        s.character.setCustom(hue: 120, saturation: 0.6, lightness: 0.5)
        s.character.selectLook("cat")
        s.character.lighterMinis = true
        let again = SettingsStore(defaults: d)
        XCTAssertEqual(again.character, s.character)
        XCTAssertEqual(again.character.appearance.look, .cat)
        XCTAssertEqual(again.character.paletteName, "custom")
        XCTAssertTrue(again.character.appearance.forMini.palette.mid.luminance > again.character.palette.mid.luminance)
        d.removePersistentDomain(forName: name)
    }
}
