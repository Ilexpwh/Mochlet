import XCTest
@testable import Mochlet

@MainActor
final class AppSmokeTests: XCTestCase {
    func testSettingsDefaults() {
        let s = SettingsStore(defaults: UserDefaults(suiteName: "com.ilexpwh.Mochlet.tests")!)
        XCTAssertEqual(s.themeName, "rimuru")
        XCTAssertTrue(s.soundEnabled)
        XCTAssertEqual(s.autoCloseSeconds, 15, accuracy: 0.01)
    }
}
