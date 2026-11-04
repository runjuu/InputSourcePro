import AppKit
import CoreData
import Sparkle
import XCTest
@testable import Input_Source_Pro

@MainActor
final class AppLaunchBehaviorTests: XCTestCase {
    func testFirstLaunchOpensPreferencesForSetup() {
        let delegate = RecordingAppDelegate()

        delegate.openPreferencesAtFirstLaunch(previousBuildVersion: 0, currentBuildVersion: 707)

        XCTAssertEqual(delegate.preferencesOpenCount, 1)
    }

    func testLaunchingSameVersionDoesNotOpenPreferences() {
        let delegate = RecordingAppDelegate()

        delegate.openPreferencesAtFirstLaunch(previousBuildVersion: 707, currentBuildVersion: 707)

        XCTAssertEqual(delegate.preferencesOpenCount, 0)
    }

    func testLaunchingNewVersionOpensPreferences() {
        let delegate = RecordingAppDelegate()

        delegate.openPreferencesAtFirstLaunch(previousBuildVersion: 706, currentBuildVersion: 707)

        XCTAssertEqual(delegate.preferencesOpenCount, 1)
    }

    func testLaunchingOlderVersionStillOpensPreferences() {
        let delegate = RecordingAppDelegate()

        delegate.openPreferencesAtFirstLaunch(previousBuildVersion: 708, currentBuildVersion: 707)

        XCTAssertEqual(delegate.preferencesOpenCount, 1)
    }

    func testNewVersionOpensPreferencesEvenWithPendingURLOrUpdateCheck() {
        let delegate = RecordingAppDelegate()
        delegate.userInitiatedUpdateSessionInProgress = true
        delegate.application(NSApplication.shared, open: [importURL])

        delegate.openPreferencesAtFirstLaunch(previousBuildVersion: 706, currentBuildVersion: 707)

        XCTAssertEqual(delegate.preferencesOpenCount, 1)
    }

    func testOrdinaryActivationStillOpensPreferences() async {
        let delegate = RecordingAppDelegate()

        activate(delegate)
        await waitForActivation()

        XCTAssertEqual(delegate.preferencesOpenCount, 1)
    }

    func testExplicitReopenDuringUpdateOpensPreferences() async {
        for hasVisibleWindows in [false, true] {
            let delegate = RecordingAppDelegate()
            delegate.userInitiatedUpdateSessionInProgress = true

            activate(delegate)
            let useDefaultHandling = delegate.applicationShouldHandleReopen(
                NSApplication.shared,
                hasVisibleWindows: hasVisibleWindows
            )
            await waitForActivation()

            XCTAssertFalse(useDefaultHandling)
            XCTAssertEqual(delegate.preferencesOpenCount, 1)
        }
    }

    func testExplicitReopenCancelsPendingActivation() async {
        let delegate = RecordingAppDelegate()

        activate(delegate)
        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        XCTAssertEqual(delegate.preferencesOpenCount, 1)
        await waitForActivation()

        XCTAssertEqual(delegate.preferencesOpenCount, 1, "The delayed activation must not reopen a window the user can already close")
    }

    func testExplicitReopenAfterUpdateEndsBetweenCallbacksOpensPreferences() async {
        let delegate = RecordingAppDelegate()
        delegate.userInitiatedUpdateSessionInProgress = true

        activate(delegate)
        delegate.userInitiatedUpdateSessionInProgress = false
        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        await waitForActivation()

        XCTAssertEqual(delegate.preferencesOpenCount, 1)
    }

    func testRejectedManualCheckPreservesBackgroundSessionActivation() async {
        let container = NSPersistentContainer(name: "Main", managedObjectModel: PreferencesVM.managedObjectModel)
        let preferences = PreferencesVM(permissionsVM: PermissionsVM(), container: container)
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        // Simulate Sparkle's background session without starting a network request.
        updater.setValue(true, forKey: "startedUpdater")
        updater.setValue(true, forKey: "sessionInProgress")
        updater.setValue(false, forKey: "canCheckForUpdates")
        defer {
            updater.setValue(false, forKey: "sessionInProgress")
            updater.setValue(false, forKey: "startedUpdater")
        }
        preferences.updaterController = controller
        preferences.canChecksForUpdates = true // The debounced UI value can lag behind Sparkle.

        let delegate = PreferencesRecordingAppDelegate()
        delegate.preferencesVM = preferences
        activate(delegate)
        preferences.checkUpdates()
        await waitForActivation()

        XCTAssertFalse(preferences.isUserInitiatedUpdateSessionInProgress)
        XCTAssertEqual(preferences.updateCheckGeneration, 0)
        XCTAssertEqual(delegate.preferencesOpenCount, 1, "A rejected request must not cancel an ordinary activation")

        activate(delegate)
        await waitForActivation()

        XCTAssertEqual(delegate.preferencesOpenCount, 2, "The background session must keep allowing ordinary activation")
    }

    func testUpdateDialogActivationDoesNotOpenPreferences() async {
        let delegate = RecordingAppDelegate()
        delegate.userInitiatedUpdateSessionInProgress = true

        activate(delegate)
        await waitForActivation()
        activate(delegate)
        await waitForActivation()

        XCTAssertEqual(delegate.preferencesOpenCount, 0)
    }

    func testQuicklyDismissingUpdateDialogDoesNotOpenPreferences() async {
        let delegate = RecordingAppDelegate()
        delegate.userInitiatedUpdateSessionInProgress = true

        activate(delegate)
        delegate.userInitiatedUpdateSessionInProgress = false
        await waitForActivation()

        XCTAssertEqual(delegate.preferencesOpenCount, 0)
    }

    func testUpdateCheckStartingDuringActivationDelayDoesNotOpenPreferences() async {
        let delegate = RecordingAppDelegate()

        activate(delegate)
        delegate.userInitiatedUpdateSessionInProgress = true
        await waitForActivation()

        XCTAssertEqual(delegate.preferencesOpenCount, 0)
    }

    func testUpdateCheckFinishingDuringActivationDelayDoesNotOpenPreferences() async {
        let delegate = RecordingAppDelegate()

        activate(delegate)
        delegate.checkGeneration += 1
        delegate.userInitiatedUpdateSessionInProgress = true
        delegate.userInitiatedUpdateSessionInProgress = false
        await waitForActivation()

        XCTAssertEqual(delegate.preferencesOpenCount, 0)
    }

    func testOrdinaryActivationAfterUpdateSessionStillOpensPreferences() async {
        let delegate = RecordingAppDelegate()
        delegate.userInitiatedUpdateSessionInProgress = true
        activate(delegate)
        delegate.userInitiatedUpdateSessionInProgress = false

        activate(delegate)
        await waitForActivation()

        XCTAssertEqual(delegate.preferencesOpenCount, 1)
    }

    func testURLDeliveredAfterActivationSuppressesPreferences() async {
        let delegate = RecordingAppDelegate()

        activate(delegate)
        delegate.application(NSApplication.shared, open: [importURL])
        await waitForActivation()

        XCTAssertEqual(delegate.preferencesOpenCount, 0)
    }

    func testURLDeliveredBeforeActivationSuppressesPreferences() async {
        let delegate = RecordingAppDelegate()
        delegate.application(NSApplication.shared, open: [importURL])

        activate(delegate)
        activate(delegate)
        await waitForActivation()

        XCTAssertEqual(delegate.preferencesOpenCount, 0)
    }

    func testURLSuppressionExpiresAndDoesNotSuppressEarlierActivations() {
        let actionAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertFalse(AppDelegate.shouldSuppressPreferences(lastURLActionAt: nil, now: actionAt))
        XCTAssertFalse(AppDelegate.shouldSuppressPreferences(lastURLActionAt: actionAt, now: actionAt.addingTimeInterval(-1)))
        XCTAssertTrue(AppDelegate.shouldSuppressPreferences(lastURLActionAt: actionAt, now: actionAt))
        XCTAssertTrue(AppDelegate.shouldSuppressPreferences(lastURLActionAt: actionAt, now: actionAt.addingTimeInterval(1.999)))
        XCTAssertFalse(AppDelegate.shouldSuppressPreferences(lastURLActionAt: actionAt, now: actionAt.addingTimeInterval(2)))
        XCTAssertFalse(AppDelegate.shouldSuppressPreferences(lastURLActionAt: actionAt, now: actionAt.addingTimeInterval(60)))
    }

    private var importURL: URL {
        URL(string: "inputsourcepro://import?path=/tmp/settings.json&silent=true")!
    }

    private func activate(_ delegate: AppDelegate) {
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
    }

    private func waitForActivation() async {
        let finished = expectation(description: "Activation grace period elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.urlActivationGrace + 0.1) {
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
    }
}

@MainActor
private class PreferencesRecordingAppDelegate: AppDelegate {
    private(set) var preferencesOpenCount = 0

    override func openPreferences() {
        preferencesOpenCount += 1
    }
}

@MainActor
private final class RecordingAppDelegate: PreferencesRecordingAppDelegate {
    var userInitiatedUpdateSessionInProgress = false
    var checkGeneration = 0

    override var isUserInitiatedUpdateSessionInProgress: Bool {
        userInitiatedUpdateSessionInProgress
    }

    override var updateCheckGeneration: Int {
        checkGeneration
    }
}
