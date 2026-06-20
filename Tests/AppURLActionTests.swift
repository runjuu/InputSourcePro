import XCTest
@testable import Input_Source_Pro

final class AppURLActionTests: XCTestCase {
    private func action(_ string: String) -> AppURLAction {
        guard let url = URL(string: string) else {
            XCTFail("Invalid test URL: \(string)")
            return .unsupported
        }
        return AppURLAction(url: url)
    }

    func testHostFormImportWithPath() {
        XCTAssertEqual(
            action("inputsourcepro://import?path=/tmp/settings.json"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: false)
        )
    }

    func testPathFormImportWithPath() {
        XCTAssertEqual(
            action("inputsourcepro:import?path=/tmp/settings.json"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: false)
        )
    }

    func testTripleSlashFormImportWithPath() {
        XCTAssertEqual(
            action("inputsourcepro:///import?path=/tmp/settings.json"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: false)
        )
    }

    func testSchemeAndActionAreCaseInsensitive() {
        XCTAssertEqual(
            action("InputSourcePro://IMPORT?path=/tmp/settings.json"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: false)
        )
    }

    func testPercentEncodedPathIsDecodedOnce() {
        guard case let .importSettings(fileURL, _) =
            action("inputsourcepro://import?path=/tmp/my%20config.json")
        else {
            return XCTFail("Expected importSettings")
        }
        XCTAssertEqual(fileURL.path, "/tmp/my config.json")
    }

    func testTildeIsExpanded() {
        guard case let .importSettings(fileURL, _) =
            action("inputsourcepro://import?path=~/settings.json")
        else {
            return XCTFail("Expected importSettings")
        }
        XCTAssertFalse(fileURL.path.contains("~"))
        XCTAssertEqual(fileURL.path, NSHomeDirectory() + "/settings.json")
    }

    func testMissingPathQueryItem() {
        XCTAssertEqual(action("inputsourcepro://import"), .importInvalidPath)
    }

    func testEmptyPathQueryItem() {
        XCTAssertEqual(action("inputsourcepro://import?path="), .importInvalidPath)
    }

    func testRelativePathIsRejected() {
        // A GUI app launched via `open` runs with CWD `/`, so a relative path
        // could never resolve to what the caller meant — reject it outright.
        XCTAssertEqual(action("inputsourcepro://import?path=settings.json"), .importInvalidPath)
        XCTAssertEqual(action("inputsourcepro://import?path=./settings.json"), .importInvalidPath)
    }

    func testHostFormTrailingPathSegmentsAreIgnored() {
        // Only the first segment is the action; trailing junk is ignored so a
        // recognized action with extra path still resolves.
        XCTAssertEqual(
            action("inputsourcepro://import/extra?path=/tmp/settings.json"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: false)
        )
    }

    func testPathFormTrailingPathSegmentsAreIgnored() {
        // Same leniency through the host-less path-form branch (`split("/").first`),
        // which the host-form case above never reaches.
        XCTAssertEqual(
            action("inputsourcepro:import/extra?path=/tmp/settings.json"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: false)
        )
    }

    func testSilentFlagOneIsParsed() {
        XCTAssertEqual(
            action("inputsourcepro://import?path=/tmp/settings.json&silent=1"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: true)
        )
    }

    func testSilentFlagTrueIsParsedCaseInsensitively() {
        XCTAssertEqual(
            action("inputsourcepro://import?path=/tmp/settings.json&silent=TRUE"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: true)
        )
    }

    func testSilentDefaultsToFalseWhenAbsent() {
        XCTAssertEqual(
            action("inputsourcepro://import?path=/tmp/settings.json"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: false)
        )
    }

    func testSilentZeroEmptyAndOtherValuesAreFalse() {
        // Only an explicit `1`/`true` enables silent; anything else keeps the
        // confirming behaviour so a typo can't silently swallow the alert.
        for value in ["0", "yes", "false", ""] {
            XCTAssertEqual(
                action("inputsourcepro://import?path=/tmp/settings.json&silent=\(value)"),
                .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: false),
                "silent=\(value) should not enable silent mode"
            )
        }
    }

    func testUnknownActionIsUnsupported() {
        XCTAssertEqual(action("inputsourcepro://export?path=/tmp/settings.json"), .unsupported)
    }

    func testForeignSchemeIsUnsupported() {
        XCTAssertEqual(action("https://import?path=/tmp/settings.json"), .unsupported)
    }
}
