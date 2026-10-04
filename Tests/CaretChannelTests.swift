import XCTest
import Security
import Darwin
@testable import Input_Source_Pro

final class CaretChannelTests: XCTestCase {
    private let activity = CaretActivity(pid: 42, uptime: 10, focusID: "field", permitsTracking: true, isInputEvent: true)

    func testFramesSurvivePartialAndCombinedSocketReads() throws {
        let first = CaretMessage.activity(activity)
        let second = CaretMessage.position(CaretPosition(session: "session", pid: 42, uptime: 10,
                                                       rect: "{{20, 30}, {1, 16}}", pending: false, focusID: "field"))
        let bytes = try CaretChannel.Decoder.frame(first) + CaretChannel.Decoder.frame(second)
        var decoder = CaretChannel.Decoder()
        XCTAssertTrue(try decoder.append(bytes.prefix(2)).isEmpty)
        XCTAssertTrue(try decoder.append(bytes.subdata(in: 2..<7)).isEmpty)
        XCTAssertEqual(try decoder.append(bytes.subdata(in: 7..<bytes.count)), [first, second])
    }

    func testMalformedAndOversizedMessagesAreRejected() throws {
        for bytes in [Data([0, 0, 0, 0]), Data([0, 0, 16, 1]), Data([0, 0, 0, 1, 255])] {
            var decoder = CaretChannel.Decoder()
            XCTAssertThrowsError(try decoder.append(bytes))
        }
        let large = CaretActivity(pid: 42, uptime: 10, focusID: String(repeating: "x", count: 5000),
                                  permitsTracking: true, isInputEvent: false)
        XCTAssertThrowsError(try CaretChannel.Decoder.frame(.activity(large)))
    }

    func testPeersCannotInvokeMessagesInTheWrongDirection() {
        XCTAssertTrue(CaretChannel.Role.application.accepts(.ready))
        XCTAssertFalse(CaretChannel.Role.helper.accepts(.ready))
        XCTAssertTrue(CaretChannel.Role.helper.accepts(.activity(activity)))
        XCTAssertFalse(CaretChannel.Role.application.accepts(.activity(activity)))
        let position = CaretMessage.position(CaretPosition(session: "s", pid: 42, uptime: 10, rect: "", pending: false, focusID: ""))
        XCTAssertTrue(CaretChannel.Role.application.accepts(position))
        XCTAssertFalse(CaretChannel.Role.helper.accepts(position))
    }

    func testTrackingRequiresFreshAuthorizationAndStopsForSecureInput() {
        XCTAssertTrue(activity.permitsQuery(pid: 42, now: 10.2, secureInput: false))
        XCTAssertFalse(activity.permitsQuery(pid: 42, now: 10.2, secureInput: true))
        XCTAssertFalse(activity.permitsQuery(pid: 43, now: 10.2, secureInput: false))
        XCTAssertFalse(activity.permitsQuery(pid: 42, now: 11, secureInput: false))
        XCTAssertFalse(activity.permitsQuery(pid: 42, now: 9, secureInput: false))
        let denied = CaretActivity(pid: 42, uptime: 10, focusID: "field", permitsTracking: false, isInputEvent: true)
        XCTAssertFalse(denied.permitsQuery(pid: 42, now: 10.2, secureInput: false))
    }

    func testSecureTextFieldsDoNotPermitCursorTracking() {
        XCTAssertFalse(CaretPalette.TextFocus(role: .textField, subrole: "AXSecureTextField").permitsCaret)
        XCTAssertTrue(CaretPalette.TextFocus(role: .textField, subrole: nil).permitsCaret)
    }

    private func ownRequirement() throws -> String {
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        var staticCode: SecStaticCode?
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(code), [], &staticCode), errSecSuccess)
        var requirement: SecRequirement?
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try XCTUnwrap(staticCode), [], &requirement), errSecSuccess)
        var text: CFString?
        XCTAssertEqual(SecRequirementCopyString(try XCTUnwrap(requirement), [], &text), errSecSuccess)
        return try XCTUnwrap(text) as String
    }

    private func socketURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ipc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("s")
    }

    func testAuthenticatedPeersExchangeMessagesAndDisconnect() async throws {
        let url = try socketURL()
        let requirement = try ownRequirement()
        let received = expectation(description: "private activity received")
        let disconnected = expectation(description: "helper stops when owner disconnects")
        let ready = expectation(description: "authenticated helper acknowledges connection")
        let app = try CaretChannel(role: .application, socketURL: url, requirement: requirement,
                                   onMessage: { message in
            XCTAssertEqual(message, .ready)
            ready.fulfill()
        }, onConnectionChange: { _ in })
        let helper = try CaretChannel(role: .helper, socketURL: url, requirement: requirement,
                                     onMessage: { [activity] message in
            XCTAssertEqual(message, .activity(activity))
            received.fulfill()
        }, onConnectionChange: { [activity] connected in
            if connected { app.send(.activity(activity)) }
            else { disconnected.fulfill() }
        })
        defer { helper.stop(); app.stop() }
        try app.start()
        try helper.start()
        await fulfillment(of: [received], timeout: 5)
        helper.send(.ready)
        await fulfillment(of: [ready], timeout: 5)
        app.stop()
        await fulfillment(of: [disconnected], timeout: 5)
    }

    func testUntrustedClientCannotReceivePrivateActivity() async throws {
        let url = try socketURL()
        let own = try ownRequirement()
        let rejected = expectation(description: "untrusted client never accepted")
        rejected.isInverted = true
        let app = try CaretChannel(role: .application, socketURL: url,
                                  requirement: "identifier \"example.not-this-process\"",
                                  onMessage: { _ in rejected.fulfill() },
                                  onConnectionChange: { if $0 { rejected.fulfill() } })
        let helper = try CaretChannel(role: .helper, socketURL: url, requirement: own,
                                     onMessage: { _ in rejected.fulfill() }, onConnectionChange: { _ in })
        defer { helper.stop(); app.stop() }
        try app.start()
        try helper.start()
        app.send(.activity(activity))
        await fulfillment(of: [rejected], timeout: 1.5)
    }

    func testHelperRejectsAnImpersonatedApp() async throws {
        let url = try socketURL()
        let rejected = expectation(description: "fake application never accepted")
        rejected.isInverted = true
        let app = try CaretChannel(role: .application, socketURL: url, requirement: try ownRequirement(),
                                  onMessage: { _ in rejected.fulfill() }, onConnectionChange: { _ in })
        let helper = try CaretChannel(role: .helper, socketURL: url,
                                     requirement: "identifier \"example.not-this-process\"",
                                     onMessage: { _ in rejected.fulfill() },
                                     onConnectionChange: { if $0 { rejected.fulfill() } })
        defer { helper.stop(); app.stop() }
        try app.start()
        try helper.start()
        await fulfillment(of: [rejected], timeout: 1.5)
    }

    func testAnotherListenerCannotReplaceTheOwnersSocket() throws {
        let url = try socketURL()
        let first = try CaretChannel(role: .application, socketURL: url, onMessage: { _ in }, onConnectionChange: { _ in })
        let second = try CaretChannel(role: .application, socketURL: url, onMessage: { _ in }, onConnectionChange: { _ in })
        defer { first.stop(); second.stop() }
        try first.start()
        XCTAssertThrowsError(try second.start())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSocketDirectorySymlinkIsRejected() throws {
        let url = try socketURL()
        let link = url.deletingLastPathComponent().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url.deletingLastPathComponent())
        let app = try CaretChannel(role: .application, socketURL: link.appendingPathComponent("s"),
                                  onMessage: { _ in }, onConnectionChange: { _ in })
        XCTAssertThrowsError(try app.start())
    }

    func testCopiedBundleIdentifiersWithoutOurSignatureAreRejected() throws {
        let executable = try socketURL().deletingLastPathComponent().appendingPathComponent("impostor")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        for (identifier, role) in [("com.runjuu.Input-Source-Pro", CaretChannel.Role.helper),
                                   ("com.runjuu.Input-Source-Pro.inputmethod.PaletteControl", .application)] {
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", "--identifier", identifier, executable.path]
            try sign.run()
            sign.waitUntilExit()
            XCTAssertEqual(sign.terminationStatus, 0)
            var code: SecStaticCode?
            XCTAssertEqual(SecStaticCodeCreateWithPath(executable as CFURL, [], &code), errSecSuccess)
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(role.peerRequirement as CFString, [], &requirement), errSecSuccess)
            XCTAssertNotEqual(SecStaticCodeCheckValidity(try XCTUnwrap(code), [], try XCTUnwrap(requirement)), errSecSuccess)
        }
    }
}
