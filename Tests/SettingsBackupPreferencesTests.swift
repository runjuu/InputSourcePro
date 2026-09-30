import XCTest
@testable import Input_Source_Pro

@MainActor
final class SettingsBackupPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "SettingsBackupPreferencesTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    func testExportRoundTripIncludesEnabledMarkdownMode() throws {
        try assertExportRoundTrip(markdownModeEnabled: true)
    }

    func testExportRoundTripIncludesDisabledMarkdownMode() throws {
        try assertExportRoundTrip(markdownModeEnabled: false)
    }

    func testImportEnablesMarkdownMode() throws {
        try assertImport(
            json: #"{"isMarkdownModeEnabled":true}"#,
            initialValue: false,
            expectedValue: true
        )
    }

    func testImportDisablesMarkdownMode() throws {
        try assertImport(
            json: #"{"isMarkdownModeEnabled":false}"#,
            initialValue: true,
            expectedValue: false
        )
    }

    func testOlderBackupPreservesEnabledMarkdownMode() throws {
        try assertImport(json: "{}", initialValue: true, expectedValue: true)
    }

    func testOlderBackupPreservesDisabledMarkdownMode() throws {
        try assertImport(json: "{}", initialValue: false, expectedValue: false)
    }

    private func assertExportRoundTrip(
        markdownModeEnabled: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let preferences = makePreferences(markdownModeEnabled: markdownModeEnabled)
        let data = try JSONEncoder().encode(SettingsBackupPreferences(preferences))
        let decoded = try JSONDecoder().decode(SettingsBackupPreferences.self, from: data)

        XCTAssertEqual(decoded.isMarkdownModeEnabled, markdownModeEnabled, file: file, line: line)
    }

    private func assertImport(
        json: String,
        initialValue: Bool,
        expectedValue: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var preferences = makePreferences(markdownModeEnabled: initialValue)
        let backup = try JSONDecoder().decode(SettingsBackupPreferences.self, from: Data(json.utf8))

        backup.apply(to: &preferences)

        XCTAssertEqual(preferences.isMarkdownModeEnabled, expectedValue, file: file, line: line)
    }

    private func makePreferences(markdownModeEnabled: Bool) -> Preferences {
        let preferences = Preferences(markdownModeUserDefaults: defaults)
        preferences.isMarkdownModeEnabled = markdownModeEnabled
        return preferences
    }
}
