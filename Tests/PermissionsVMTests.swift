import AppKit
import Combine
import XCTest
@testable import Input_Source_Pro

@MainActor
final class PermissionsVMTests: XCTestCase {
    func testAppActivationDetectsRepeatedRegrantsWithoutGeneralSettings() {
        var granted = true
        let notificationCenter = NotificationCenter()
        let permissions = PermissionsVM(
            accessibilityCheck: { granted },
            inputMonitoringCheck: { granted },
            notificationCenter: notificationCenter
        )

        for _ in 0..<2 {
            granted = false
            permissions.refresh()
            XCTAssertFalse(permissions.isAccessibilityEnabled)
            XCTAssertFalse(permissions.isInputMonitoringEnabled)

            let regranted = expectation(description: "Permission grant is published after activation")
            let subscription = permissions.$isAccessibilityEnabled
                .combineLatest(permissions.$isInputMonitoringEnabled)
                .filter { $0 && $1 }
                .first()
                .sink { _ in regranted.fulfill() }

            granted = true
            notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            wait(for: [regranted], timeout: 1)

            XCTAssertTrue(permissions.isAccessibilityEnabled)
            XCTAssertTrue(permissions.isInputMonitoringEnabled)
            withExtendedLifetime(subscription) {}
        }
    }

    func testAppActivationDetectsRevocationWithoutGeneralSettings() {
        var granted = true
        let notificationCenter = NotificationCenter()
        let permissions = PermissionsVM(
            accessibilityCheck: { granted },
            inputMonitoringCheck: { granted },
            notificationCenter: notificationCenter
        )
        let revoked = expectation(description: "Permission revocation is published after activation")
        let subscription = permissions.$isAccessibilityEnabled
            .combineLatest(permissions.$isInputMonitoringEnabled)
            .filter { !$0 && !$1 }
            .first()
            .sink { _ in revoked.fulfill() }

        granted = false
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        wait(for: [revoked], timeout: 1)

        XCTAssertFalse(permissions.isAccessibilityEnabled)
        XCTAssertFalse(permissions.isInputMonitoringEnabled)
        withExtendedLifetime(subscription) {}
    }

    func testRefreshDetectsRevocationAndRegrant() {
        var accessibilityGranted = true
        var inputMonitoringGranted = true
        let permissions = PermissionsVM(
            accessibilityCheck: { accessibilityGranted },
            inputMonitoringCheck: { inputMonitoringGranted }
        )

        accessibilityGranted = false
        inputMonitoringGranted = false
        permissions.refresh()

        XCTAssertFalse(permissions.isAccessibilityEnabled)
        XCTAssertFalse(permissions.isInputMonitoringEnabled)

        accessibilityGranted = true
        inputMonitoringGranted = true
        permissions.refresh()

        XCTAssertTrue(permissions.isAccessibilityEnabled)
        XCTAssertTrue(permissions.isInputMonitoringEnabled)
    }

    func testRefreshTracksPermissionsIndependently() {
        var accessibilityGranted = true
        var inputMonitoringGranted = false
        let permissions = PermissionsVM(
            accessibilityCheck: { accessibilityGranted },
            inputMonitoringCheck: { inputMonitoringGranted }
        )

        accessibilityGranted = false
        inputMonitoringGranted = true
        permissions.refresh()

        XCTAssertFalse(permissions.isAccessibilityEnabled)
        XCTAssertTrue(permissions.isInputMonitoringEnabled)
    }
}
