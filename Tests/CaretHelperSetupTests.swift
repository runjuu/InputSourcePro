import XCTest
@testable import Input_Source_Pro

final class CaretHelperSetupTests: XCTestCase {
    private var root: URL!
    private var destination: URL { root.appendingPathComponent("Input Methods/ISP Palette Control.app") }
    private var backups: URL { root.appendingPathComponent("Backups") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func bundle(at url: URL, id: String = CaretHelperFiles.sourceID, version: String? = nil) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = ["CFBundleIdentifier": id]
        info["ISPCaretBuild"] = version
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    func testUninstallIncludesOnlyInstalledHelperAndOwnedBackups() throws {
        try bundle(at: destination)
        let backup = backups.appendingPathComponent(UUID().uuidString).appendingPathComponent(destination.lastPathComponent)
        try bundle(at: backup)
        let unrelated = backups.appendingPathComponent("User files")
        try bundle(at: unrelated)
        XCTAssertEqual(Set(try CaretHelperFiles.removalCandidates(destination: destination, backups: backups).map { $0.resolvingSymlinksInPath().path }), Set([destination, backup].map { $0.resolvingSymlinksInPath().path }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testUninstallRefusesAnUnrelatedBundleBeforeDeletingAnything() throws {
        try bundle(at: destination, id: "example.unrelated")
        XCTAssertThrowsError(try CaretHelperFiles.removalCandidates(destination: destination, backups: backups))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testUninstallRefusesBackupSymlinkAndPreservesInstalledHelper() throws {
        try bundle(at: destination)
        let outside = root.appendingPathComponent("Unrelated")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: backups, withDestinationURL: outside)
        XCTAssertThrowsError(try CaretHelperFiles.removalCandidates(destination: destination, backups: backups))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testUninstallCanResumeAfterInstalledBundleHasAlreadyBeenRemoved() throws {
        let backup = backups.appendingPathComponent(UUID().uuidString).appendingPathComponent(destination.lastPathComponent)
        try bundle(at: backup)
        XCTAssertEqual(try CaretHelperFiles.removalCandidates(destination: destination, backups: backups).map { $0.resolvingSymlinksInPath().path }, [backup.resolvingSymlinksInPath().path])
    }

    func testMissingInputSourceReturnsNilInsteadOfCrashing() {
        XCTAssertNil(CaretInputSource.find("dev.inputsourcepro.tests.missing.\(UUID().uuidString)"))
    }

    func testUninstallAlsoFindsVerifiedLegacyHelpersWithoutCurrentInstallation() throws {
        var expected: [String] = []
        for helper in CaretHelperFiles.legacyHelpers {
            let url = destination.deletingLastPathComponent().appendingPathComponent(helper.name)
            try bundle(at: url, id: helper.identifier)
            expected.append(url.resolvingSymlinksInPath().path)
        }
        XCTAssertTrue(CaretHelperFiles.hasLegacyHelpers(beside: destination))
        let result = try CaretHelperFiles.removalCandidates(destination: destination, backups: backups)
        XCTAssertEqual(Set(result.map { $0.resolvingSymlinksInPath().path }), Set(expected))
    }

    func testLegacyNameDoesNotPermitDeletingAnUnrelatedBundle() throws {
        let url = destination.deletingLastPathComponent().appendingPathComponent(CaretHelperFiles.legacyHelpers[0].name)
        try bundle(at: url, id: "example.unrelated")
        XCTAssertThrowsError(try CaretHelperFiles.removalCandidates(destination: destination, backups: backups))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testLegacyHelpersRemainManageableAfterCurrentHelperIsUninstalled() throws {
        let status = try JSONDecoder().decode(CaretHelperManager.Status.self, from: Data(
            #"{"installed":false,"registered":false,"enabled":false,"selected":false,"legacyInstalled":true}"#.utf8
        ))
        XCTAssertFalse(status.isReady)
        XCTAssertTrue(status.hasRemovableHelpers)
    }

    func testRegistrationFailureRestoresPreviousHelper() throws {
        try bundle(at: destination, version: "old")
        let staged = root.appendingPathComponent("Staged.app")
        try bundle(at: staged, version: "new")
        let backup = backups.appendingPathComponent(UUID().uuidString).appendingPathComponent(destination.lastPathComponent)
        var registrations = 0
        XCTAssertThrowsError(try CaretHelperFiles.install(staged: staged, destination: destination, backup: backup) { _ in
            registrations += 1
            if registrations == 1 { throw CocoaError(.fileReadUnknown) }
        })
        let info = NSDictionary(contentsOf: destination.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(info?["ISPCaretBuild"] as? String, "old")
        XCTAssertEqual(registrations, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    @MainActor
    func testOldPrototypeWithoutBuildFingerprintRequiresUpdate() throws {
        let bundled = root.appendingPathComponent("Bundled.app")
        try bundle(at: bundled, version: "new")
        try bundle(at: destination)
        XCTAssertFalse(CaretHelperManager.sameVersion(bundled, destination))
    }

    @MainActor
    func testSameAppVersionWithChangedHelperRequiresUpdate() throws {
        let bundled = root.appendingPathComponent("Bundled.app")
        try bundle(at: bundled, version: "new-source")
        try bundle(at: destination, version: "old-source")
        XCTAssertFalse(CaretHelperManager.sameVersion(bundled, destination))
    }

    @MainActor
    func testRevokedPermissionAndMissingRegistrationAreNotReady() {
        XCTAssertFalse(CaretHelperManager.Status(installed: true, registered: true, enabled: false, selected: false).isReady)
        XCTAssertFalse(CaretHelperManager.Status(installed: true, registered: false, enabled: true, selected: true).isReady)
        XCTAssertTrue(CaretHelperManager.Status(installed: true, registered: true, enabled: true, selected: false).isReady)
    }

    @MainActor
    private func makeManager(command: @escaping ([String]) async throws -> String,
                             start: @escaping () -> Bool = { true }) throws -> CaretHelperManager {
        try bundle(at: destination, version: "current")
        let manager = CaretHelperManager(command: command,
                                         helperURL: destination, installedURL: destination,
                                         startTracking: start, stopTracking: {})
        manager.updateAvailability(enhanced: true, allowed: true)
        return manager
    }

    @MainActor
    func testDeniedPermissionDoesNotEnableTracking() async throws {
        var starts = 0
        let manager = try makeManager(command: { arguments in
            if arguments.first == "authorize" { throw CocoaError(.userCancelled) }
            return #"{"installed":true,"registered":true,"enabled":false,"selected":false}"#
        }, start: { starts += 1; return true })
        await manager.setup()
        XCTAssertFalse(manager.isActive)
        XCTAssertFalse(manager.isBusy)
        XCTAssertNotNil(manager.error)
        XCTAssertEqual(starts, 0)
    }

    @MainActor
    func testSuccessfulSetupStartsTrackingOnlyAfterSelectionIsVerified() async throws {
        var selected = false
        var beganTracking = false
        let manager = try makeManager(command: { arguments in
            if arguments.first == "start" { selected = true }
            return "{\"installed\":true,\"registered\":true,\"enabled\":true,\"selected\":\(selected)}"
        }, start: {
            XCTAssertTrue(selected)
            beganTracking = true
            return true
        })
        await manager.setup()
        XCTAssertTrue(beganTracking)
        XCTAssertTrue(manager.isActive)
        XCTAssertNil(manager.error)
    }

    @MainActor
    func testSelectionFailureDoesNotAppearEnabled() async throws {
        var beganTracking = false
        let manager = try makeManager(command: { _ in
            #"{"installed":true,"registered":true,"enabled":true,"selected":false}"#
        }, start: { beganTracking = true; return true })
        await manager.setup()
        XCTAssertFalse(manager.isActive)
        XCTAssertNotNil(manager.error)
        XCTAssertFalse(beganTracking)
    }

    @MainActor
    func testAutomaticRestoreDoesNotRequestRevokedPermission() async throws {
        var commands: [String] = []
        let manager = try makeManager(command: { arguments in
            commands.append(arguments[0])
            return #"{"installed":true,"registered":true,"enabled":false,"selected":false}"#
        })
        await manager.restore()
        XCTAssertFalse(commands.contains("authorize"))
        XCTAssertFalse(manager.isActive)
        XCTAssertFalse(manager.status.enabled)
    }

    @MainActor
    func testInstalledHelperStartsAutomaticallyWithoutOptIn() async throws {
        var selected = false
        var starts = 0
        let manager = try makeManager(command: { arguments in
            if arguments.first == "start" { selected = true }
            return "{\"installed\":true,\"registered\":true,\"enabled\":true,\"selected\":\(selected)}"
        }, start: { starts += 1; return true })
        await manager.restore()
        XCTAssertTrue(manager.isActive)
        XCTAssertEqual(starts, 1)
        await manager.refresh()
        XCTAssertEqual(starts, 1)
    }

    @MainActor
    func testAbsentHelperIsNotReinstalledAutomatically() async throws {
        var commands: [String] = []
        let manager = try makeManager(command: { arguments in
            commands.append(arguments[0])
            return #"{"installed":false,"registered":false,"enabled":false,"selected":false}"#
        })
        await manager.restore()
        XCTAssertEqual(commands, ["status"])
        XCTAssertFalse(manager.isActive)
        XCTAssertNil(manager.error)
    }

    @MainActor
    func testUninstalledHelperStaysOffOnRefresh() async throws {
        var installed = true
        var commands: [String] = []
        let manager = try makeManager(command: { arguments in
            commands.append(arguments[0])
            if arguments.first == "uninstall" { installed = false }
            return "{\"installed\":\(installed),\"registered\":\(installed),\"enabled\":\(installed),\"selected\":\(installed)}"
        })
        await manager.restore()
        XCTAssertTrue(manager.isActive)
        await manager.uninstall()
        commands.removeAll()
        await manager.refresh()
        XCTAssertEqual(commands, ["status"])
        XCTAssertFalse(manager.isActive)
        XCTAssertFalse(manager.status.installed)
    }

    @MainActor
    func testClosingPermissionRequestNeverActivatesOnLateApproval() async throws {
        var manager: CaretHelperManager!
        var starts = 0
        manager = try makeManager(command: { arguments in
            if arguments.first == "authorize" {
                manager.cancelPermissionRequest()
                return "Allowed"
            }
            return #"{"installed":true,"registered":true,"enabled":false,"selected":false}"#
        }, start: { starts += 1; return true })
        await manager.setup()
        XCTAssertFalse(manager.isActive)
        XCTAssertNil(manager.error)
        XCTAssertEqual(starts, 0)
        manager = nil
    }

    @MainActor
    func testFailedUninstallTurnsTrackingOffAndRetainsRecoveryState() async throws {
        let manager = try makeManager(command: { arguments in
            if arguments.first == "uninstall" { throw CocoaError(.fileWriteNoPermission) }
            return #"{"installed":true,"registered":true,"enabled":true,"selected":true}"#
        })
        await manager.setup()
        XCTAssertTrue(manager.isActive)
        await manager.uninstall()
        XCTAssertFalse(manager.isActive)
        XCTAssertTrue(manager.status.installed)
        XCTAssertNotNil(manager.error)
    }

    @MainActor
    func testConcurrentRefreshesShareStatusCheckAndKeepCachedStatusVisible() async throws {
        let requested = expectation(description: "Refresh requested status")
        let joined = expectation(description: "Second caller joined refresh")
        var checks = 0
        var response: CheckedContinuation<String, Never>?
        let cached = #"{"installed":true,"registered":true,"enabled":false,"selected":false}"#
        let missing = #"{"installed":false,"registered":false,"enabled":false,"selected":false}"#
        let manager = try makeManager(command: { arguments in
            XCTAssertEqual(arguments, ["status", "--json"])
            checks += 1
            if checks == 2 {
                return await withCheckedContinuation {
                    response = $0
                    requested.fulfill()
                }
            }
            return cached
        })
        await manager.refresh()
        XCTAssertTrue(manager.status.installed)

        let first = Task { await manager.refresh() }
        await fulfillment(of: [requested], timeout: 2)
        var secondCompleted = false
        let second = Task {
            joined.fulfill()
            await manager.refresh()
            secondCompleted = true
        }
        await fulfillment(of: [joined], timeout: 2)
        XCTAssertEqual(checks, 2)
        XCTAssertFalse(secondCompleted)
        XCTAssertTrue(manager.status.installed)
        XCTAssertFalse(manager.isBusy)
        response?.resume(returning: missing)
        await first.value
        await second.value
        XCTAssertFalse(manager.status.installed)
        XCTAssertTrue(secondCompleted)

        await manager.refresh()
        XCTAssertEqual(checks, 3, "A later refresh must perform a new check")
        XCTAssertTrue(manager.status.installed)
    }

    @MainActor
    func testSharedRefreshFailureReleasesTaskForRetry() async throws {
        let requested = expectation(description: "Status check started")
        let joined = expectation(description: "Second refresh started")
        var checks = 0
        var response: CheckedContinuation<String, Error>?
        let manager = try makeManager(command: { _ in
            checks += 1
            if checks == 1 {
                return try await withCheckedThrowingContinuation {
                    response = $0
                    requested.fulfill()
                }
            }
            return #"{"installed":true,"registered":true,"enabled":false,"selected":false}"#
        })
        let first = Task { await manager.refresh() }
        await fulfillment(of: [requested], timeout: 2)
        let second = Task {
            joined.fulfill()
            await manager.refresh()
        }
        await fulfillment(of: [joined], timeout: 2)
        response?.resume(throwing: CocoaError(.fileReadUnknown))
        await first.value
        await second.value
        XCTAssertEqual(checks, 1)
        XCTAssertNotNil(manager.error)
        await manager.refresh()
        XCTAssertEqual(checks, 2)
        XCTAssertTrue(manager.status.installed)
    }

    @MainActor
    func testUninstallInvalidatesInFlightRefresh() async throws {
        let requested = expectation(description: "Refresh is waiting for status")
        var checks = 0
        var response: CheckedContinuation<String, Never>?
        var starts = 0
        let manager = try makeManager(command: { arguments in
            if arguments.first == "status" {
                checks += 1
                if checks == 1 {
                    return await withCheckedContinuation {
                        response = $0
                        requested.fulfill()
                    }
                }
            }
            return #"{"installed":false,"registered":false,"enabled":false,"selected":false}"#
        }, start: { starts += 1; return true })
        let refresh = Task { await manager.refresh() }
        await fulfillment(of: [requested], timeout: 2)
        await manager.uninstall()
        response?.resume(returning: #"{"installed":true,"registered":true,"enabled":true,"selected":true}"#)
        await refresh.value
        XCTAssertFalse(manager.status.installed)
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(starts, 0)
    }
}
