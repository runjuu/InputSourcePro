import AppKit
import Combine
import XCTest
@testable import Input_Source_Pro

@MainActor
final class AlwaysOnIndicatorTests: XCTestCase {
    func testActiveCaretIndicatorHidesLabelAndBlocksSubsequentActivations() {
        var visibility = IndicatorWindowController.DefaultIndicatorVisibility()
        visibility.setActive(true)
        XCTAssertTrue(visibility.isActive)

        visibility.update(alwaysOnPosition: CGPoint(x: 100, y: 200), preferCaret: false)
        XCTAssertFalse(visibility.isActive, "A late caret result must hide an already visible label")
        visibility.setActive(true)
        XCTAssertFalse(visibility.isActive, "Input switches must not restore the label while suppressed")

        visibility.update(alwaysOnPosition: nil, preferCaret: false)
        XCTAssertFalse(visibility.isActive, "Losing the caret must not replay an earlier activation")
        visibility.setActive(true)
        XCTAssertTrue(visibility.isActive, "New activations must work when the caret is unavailable")
        visibility.setActive(false)
        XCTAssertFalse(visibility.isActive)
    }

    func testDefaultLabelRemainsAvailableWhenBothCaretOptionsAreEnabled() {
        var visibility = IndicatorWindowController.DefaultIndicatorVisibility()
        let point = CGPoint(x: 100, y: 200)
        visibility.update(alwaysOnPosition: point, preferCaret: true)
        visibility.setActive(true)
        XCTAssertTrue(visibility.isActive)

        visibility.update(alwaysOnPosition: point, preferCaret: false)
        XCTAssertFalse(visibility.isActive, "Disabling default caret placement must hide the active label")
        visibility.update(alwaysOnPosition: point, preferCaret: true)
        XCTAssertFalse(visibility.isActive, "Changing the preference must not replay an old activation")
        visibility.setActive(true)
        XCTAssertTrue(visibility.isActive)
    }

    func testAlwaysOnIsIndependentOfCaretPreferenceAndDefaultTriggers() {
        withPreferences { preferences in
            preferences.isEnhancedModeEnabled = true
            preferences.isActiveWhenSwitchApp = false
            preferences.isActiveWhenSwitchInputSource = false
            preferences.isActiveWhenFocusedElementChanges = false
            preferences.isActiveWhenLongpressLeftMouse = false

            for preferCaret in [false, true] {
                preferences.tryToDisplayIndicatorNearCursor = preferCaret
                preferences.isEnableAlwaysOnIndicator = true
                XCTAssertTrue(preferences.isAlwaysOnIndicatorEnabled)

                preferences.isEnableAlwaysOnIndicator = false
                XCTAssertFalse(preferences.isAlwaysOnIndicatorEnabled)
            }
        }
    }

    func testAlwaysOnRequiresEnhancedModeWithoutClearingTheSavedChoice() {
        withPreferences { preferences in
            preferences.isEnableAlwaysOnIndicator = true
            preferences.isEnhancedModeEnabled = false
            XCTAssertFalse(preferences.isAlwaysOnIndicatorEnabled)
            XCTAssertTrue(preferences.isEnableAlwaysOnIndicator)

            preferences.isEnhancedModeEnabled = true
            XCTAssertTrue(preferences.isAlwaysOnIndicatorEnabled)
        }
    }

    func testDotAppearsImmediatelyAtCaretAndHidesWhenPositionIsLost() throws {
        let controller = AlwaysOnIndicatorWindowController()
        defer { controller.close() }
        controller.update(config: config(color: .red))
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isVisible)

        controller.position = CGPoint(x: 100, y: 200)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.frame.midX, 100)
        XCTAssertEqual(window.frame.minY, 200)
        XCTAssertEqual(window.frame.size, CGSize(width: 8, height: 8))

        controller.position = nil
        XCTAssertFalse(window.isVisible)
    }

    func testVisibleDefaultIndicatorHidesTheDotUntilDismissed() throws {
        let controller = AlwaysOnIndicatorWindowController()
        defer { controller.close() }
        controller.update(config: config(color: .red))
        controller.position = CGPoint(x: 100, y: 200)
        controller.isDefaultIndicatorVisible = true

        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isVisible)

        controller.isDefaultIndicatorVisible = false
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.frame.midX, 100)
        XCTAssertEqual(window.frame.minY, 200)
    }

    func testCaretAndContentUpdatesDoNotRestoreDotWhileDefaultIndicatorIsVisible() throws {
        let controller = AlwaysOnIndicatorWindowController()
        defer { controller.close() }
        controller.update(config: config(color: .red))
        controller.position = CGPoint(x: 100, y: 200)
        let window = try XCTUnwrap(controller.window)

        controller.isDefaultIndicatorVisible = true
        XCTAssertFalse(window.isVisible)

        controller.update(config: config(color: .blue))
        controller.position = CGPoint(x: 200, y: 300)
        XCTAssertFalse(window.isVisible)

        controller.isDefaultIndicatorVisible = false
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.frame.size, CGSize(width: 8, height: 8))
        XCTAssertEqual(window.frame.midX, 200)
        XCTAssertEqual(window.frame.minY, 300)
    }

    func testContentUpdatesKeepTheDotAtTheCaretWithoutShowingDefaultContent() throws {
        let controller = AlwaysOnIndicatorWindowController()
        defer { controller.close() }
        controller.update(config: config(color: .red))
        controller.position = CGPoint(x: 100, y: 200)
        let window = try XCTUnwrap(controller.window)
        let oldView = window.contentView

        controller.update(config: config(color: .blue))
        XCTAssertFalse(window.contentView === oldView)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.frame.midX, 100)
        XCTAssertEqual(window.frame.minY, 200)
        XCTAssertEqual(window.frame.size, CGSize(width: 8, height: 8))
    }

    func testAlwaysOnPublishersKeepTrackingWithDefaultTriggersDisabled() {
        withPreferences { preferences in
            preferences.isEnhancedModeEnabled = true
            preferences.isEnableAlwaysOnIndicator = true
            preferences.tryToDisplayIndicatorNearCursor = false
            preferences.isActiveWhenSwitchApp = false
            preferences.isActiveWhenSwitchInputSource = false
            preferences.isActiveWhenFocusedElementChanges = false
            preferences.isActiveWhenLongpressLeftMouse = false
            preferences.isAlwaysDisplayIndicatorNearMouse = false
            preferences.indicatorPosition = .nearMouse

            let app = NSRunningApplication.current
            let appKind = AppKind.normal(app: app, info: (focusedElement: nil, isFocusOnInputContainer: false))
            let context = CurrentValueSubject<(AppKind?, Preferences, Bool), Never>((appKind, preferences, false))
            let caret = PassthroughSubject<IndicatorWindowController.AlwaysNearMouse.Placement, Never>()
            let configs = CurrentValueSubject<IndicatorViewConfig, Never>(config(color: .red))
            var isAppAllowed = true
            var trackingStarts = 0
            var trackingStops = 0
            let positions = IndicatorWindowController.alwaysOnPositionPublisher(
                context: context.eraseToAnyPublisher(),
                isAppAllowed: { _ in isAppAllowed },
                getPosition: { queriedApp in
                    XCTAssertEqual(queriedApp.processIdentifier, app.processIdentifier)
                    return caret
                        .handleEvents(
                            receiveSubscription: { _ in trackingStarts += 1 },
                            receiveCancel: { trackingStops += 1 }
                        )
                        .eraseToAnyPublisher()
                }
            )
            let controller = AlwaysOnIndicatorWindowController()
            defer { controller.close() }
            controller.observe(configs: configs.eraseToAnyPublisher(), positions: positions)
            flushMainQueue()
            XCTAssertEqual(trackingStarts, 1)
            XCTAssertEqual(controller.window?.isVisible, false)

            let firstPoint = CGPoint(x: 100, y: 200)
            caret.send(.caret(firstPoint))
            XCTAssertEqual(controller.window?.isVisible, true)
            XCTAssertEqual(controller.position, firstPoint)

            let oldView = controller.window?.contentView
            configs.send(config(color: .blue))
            XCTAssertFalse(controller.window?.contentView === oldView)
            XCTAssertEqual(controller.window?.isVisible, true)
            XCTAssertEqual(controller.position, firstPoint)
            XCTAssertEqual(trackingStarts, 1, "Content changes must not restart caret tracking")

            caret.send(.mouse)
            XCTAssertEqual(controller.window?.isVisible, false)
            caret.send(.caret(CGPoint(x: 200, y: 300)))
            XCTAssertEqual(controller.window?.isVisible, true)
            XCTAssertEqual(controller.position, CGPoint(x: 200, y: 300))

            let unchangedAppSwitch = IndicatorVM.ActivateEvent.appChanges(
                current: appKind, prev: nil, inputSourceDidChange: false
            )
            XCTAssertEqual(IndicatorWindowController.activationMode(
                event: unchangedAppSwitch, focusedField: false
            ), .hide)
            context.send((appKind, preferences, false))
            flushMainQueue()
            XCTAssertEqual(trackingStops, 1)
            XCTAssertEqual(trackingStarts, 2, "An unchanged input source must not suppress independent caret tracking")
            caret.send(.caret(firstPoint))
            XCTAssertEqual(controller.window?.isVisible, true)

            context.send((appKind, preferences, true))
            flushMainQueue()
            XCTAssertEqual(trackingStops, 2)
            XCTAssertEqual(controller.window?.isVisible, false)
            caret.send(.caret(firstPoint))
            XCTAssertNil(controller.position, "A cancelled query must not restore a dot while locked")

            context.send((appKind, preferences, false))
            flushMainQueue()
            XCTAssertEqual(trackingStarts, 3)
            caret.send(.caret(firstPoint))
            XCTAssertEqual(controller.window?.isVisible, true)

            isAppAllowed = false
            context.send((appKind, preferences, false))
            flushMainQueue()
            XCTAssertEqual(trackingStops, 3)
            XCTAssertEqual(controller.window?.isVisible, false)

            isAppAllowed = true
            preferences.isAlwaysDisplayIndicatorNearMouse = true
            context.send((appKind, preferences, false))
            flushMainQueue()
            XCTAssertEqual(trackingStarts, 3, "Mouse-following mode must own the single persistent indicator")

            preferences.isAlwaysDisplayIndicatorNearMouse = false
            preferences.isEnableAlwaysOnIndicator = false
            context.send((appKind, preferences, false))
            flushMainQueue()
            XCTAssertEqual(trackingStarts, 3)
            XCTAssertEqual(controller.window?.isVisible, false)
        }
    }

    func testIndependentDotStaysSuspendedUntilBothWakeAndUnlock() {
        withPreferences { preferences in
            preferences.isEnhancedModeEnabled = true
            preferences.isEnableAlwaysOnIndicator = true
            preferences.isAlwaysDisplayIndicatorNearMouse = false

            let lockCenter = NotificationCenter()
            let workspaceCenter = NotificationCenter()
            let suspended = IndicatorVM.indicatorSuspensionPublisher(
                lockNotificationCenter: lockCenter,
                workspaceNotificationCenter: workspaceCenter
            )
            let appKind = AppKind.normal(
                app: NSRunningApplication.current,
                info: (focusedElement: nil, isFocusOnInputContainer: true)
            )
            var trackingStarts = 0
            let positions = IndicatorWindowController.alwaysOnPositionPublisher(
                context: Publishers.CombineLatest3(
                    Just(Optional(appKind)), Just(preferences), suspended
                ).eraseToAnyPublisher(),
                isAppAllowed: { _ in true },
                getPosition: { _ in
                    trackingStarts += 1
                    return Just(.caret(CGPoint(x: 100, y: 200))).eraseToAnyPublisher()
                }
            )
            let controller = AlwaysOnIndicatorWindowController()
            defer { controller.close() }
            controller.observe(configs: Just(config(color: .red)).eraseToAnyPublisher(), positions: positions)
            flushMainQueue()
            XCTAssertEqual(controller.window?.isVisible, true)
            XCTAssertEqual(trackingStarts, 1)

            lockCenter.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
            workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            flushMainQueue()
            XCTAssertEqual(controller.window?.isVisible, false)
            XCTAssertEqual(trackingStarts, 1, "Waking must not resume caret queries while still locked")

            lockCenter.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
            flushMainQueue()
            XCTAssertEqual(controller.window?.isVisible, true)
            XCTAssertEqual(trackingStarts, 2)
        }
    }

    private func flushMainQueue() {
        let flushed = expectation(description: "Scheduled publisher updates")
        // Notifications and indicator contexts each schedule onto the main queue.
        DispatchQueue.main.async {
            DispatchQueue.main.async { flushed.fulfill() }
        }
        wait(for: [flushed], timeout: 1)
    }

    private func config(color: NSColor) -> IndicatorViewConfig {
        IndicatorViewConfig(
            inputSource: InputSource.getCurrentInputSource(),
            kind: .alwaysOn,
            size: .medium,
            bgColor: color,
            textColor: .white
        )
    }

    private func withPreferences(_ body: (inout Preferences) -> Void) {
        let keys = [
            "isDetectSpotlightLikeApp",
            "isEnableAlwaysOnIndicator",
            "tryToDisplayIndicatorNearCursor",
            "isActiveWhenSwitchApp",
            "isActiveWhenSwitchInputSource",
            "isActiveWhenFocusedElementChanges",
            "isActiveWhenLongpressLeftMouse",
            "isAlwaysDisplayIndicatorNearMouse",
            "indicatorPosition",
        ]
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        defer {
            for key in keys {
                if let value = domain[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        var preferences = Preferences()
        body(&preferences)
    }
}
