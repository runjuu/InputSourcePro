import XCTest
@testable import Input_Source_Pro

@MainActor
final class UpdateChannelTests: XCTestCase {
    func testStableInstallPersistsStableChoiceAcrossBetaUpgrade() {
        let name = "UpdateChannelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let stable = UpdateChannelSettings(defaults: defaults, isBetaBuild: false)
        XCTAssertFalse(stable.receivesBetaUpdates)
        XCTAssertEqual(stable.feedURL, "https://inputsource.pro/stable/appcast.xml")
        XCTAssertFalse(UpdateChannelSettings(defaults: defaults, isBetaBuild: true).receivesBetaUpdates)
    }

    func testBetaInstallAndExplicitChoiceSurviveRelaunch() {
        let name = "UpdateChannelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let beta = UpdateChannelSettings(defaults: defaults, isBetaBuild: true)
        XCTAssertTrue(beta.receivesBetaUpdates)
        XCTAssertEqual(beta.feedURL, "https://inputsource.pro/beta/appcast.xml")
        beta.receivesBetaUpdates = false
        XCTAssertEqual(beta.feedURL, "https://inputsource.pro/stable/appcast.xml")
        XCTAssertFalse(UpdateChannelSettings(defaults: defaults, isBetaBuild: true).receivesBetaUpdates)
        beta.receivesBetaUpdates = true
        XCTAssertTrue(UpdateChannelSettings(defaults: defaults, isBetaBuild: false).receivesBetaUpdates)
    }
}
