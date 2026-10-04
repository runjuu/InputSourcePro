import AppKit
import Combine
import AXSwift
import XCTest
@testable import Input_Source_Pro

#if DEBUG
@MainActor
final class CaretPaletteTests: XCTestCase {
    private let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)

    func testKnownNonInputFocusCannotDisplayCaret() {
        for role: Role in [.webArea, .button, .link, .staticText, .checkBox] {
            XCTAssertFalse(CaretPalette.TextFocus(role: role).permitsCaret)
        }
    }

    func testEditableFocusAllowsCaretTracking() {
        for role: Role in [.textArea, .textField, .comboBox] {
            XCTAssertEqual(CaretPalette.TextFocus(role: role), .input)
        }
    }

    func testCustomEditorWithNoAXTextRoleKeepsHelperTracking() {
        for role: Role? in [.window, .group, nil] {
            XCTAssertEqual(CaretPalette.TextFocus(role: role), .unknown)
            XCTAssertTrue(CaretPalette.TextFocus(role: role).permitsCaret)
        }
    }

    func testAcquiringNewFieldInvalidatesOldFieldConfirmation() {
        let previous = CaretPalette.Confirmation(pid: 42, uptime: 10)
        let next = CaretPalette.Confirmation(pid: 42, uptime: 10.1)
        XCTAssertFalse(previous.isCurrent(for: 42, now: 10.2, focusedAt: 10.1))
        XCTAssertTrue(next.isCurrent(for: 42, now: 10.2, focusedAt: 10.1))
    }

    func testCodexShortTextJumpIsConfirmedRegardlessOfDistance() {
        var filter = CaretGeometryFilter()
        let previous = CGRect(x: 612, y: 152, width: 1, height: 16)
        let transient = CGRect(x: 605, y: 152, width: 1, height: 16)
        let current = CGRect(x: 620, y: 152, width: 1, height: 16)
        _ = filter.accept(previous, at: 10)
        XCTAssertNil(filter.accept(transient, at: 10.1, confirmEveryChange: true))
        XCTAssertNil(filter.accept(current, at: 10.119, confirmEveryChange: true))
        XCTAssertEqual(filter.accept(current, at: 10.139, confirmEveryChange: true), current)
    }

    func testCodexFirstPositionIsConfirmedBeforeBeingDisplayed() {
        var filter = CaretGeometryFilter()
        let transient = CGRect(x: 605, y: 152, width: 1, height: 16)
        let current = CGRect(x: 612, y: 152, width: 1, height: 16)
        XCTAssertNil(filter.accept(transient, at: 10, confirmEveryChange: true))
        XCTAssertNil(filter.accept(current, at: 10.02, confirmEveryChange: true))
        XCTAssertEqual(filter.accept(current, at: 10.04, confirmEveryChange: true), current)
    }

    func testCodexRealBackspaceAndArrowMovementAreNotDiscarded() {
        var filter = CaretGeometryFilter()
        _ = filter.accept(CGRect(x: 620, y: 152, width: 1, height: 16), at: 10)
        let backward = CGRect(x: 612, y: 152, width: 1, height: 16)
        XCTAssertNil(filter.accept(backward, at: 10.1, confirmEveryChange: true))
        XCTAssertEqual(filter.accept(backward, at: 10.12, confirmEveryChange: true), backward)
        XCTAssertEqual(filter.accept(backward, at: 10.13, confirmEveryChange: true), backward)
    }

    func testCodexChangingGeometryCannotBypassConfirmationAfterTimeout() {
        var filter = CaretGeometryFilter()
        _ = filter.accept(CGRect(x: 612, y: 152, width: 1, height: 16), at: 10)
        XCTAssertNil(filter.accept(CGRect(x: 620, y: 152, width: 1, height: 16), at: 10.1, confirmEveryChange: true))
        XCTAssertNil(filter.accept(CGRect(x: 628, y: 152, width: 1, height: 16), at: 10.12, confirmEveryChange: true))
        let latest = CGRect(x: 636, y: 152, width: 1, height: 16)
        XCTAssertNil(filter.accept(latest, at: 10.16, confirmEveryChange: true))
        XCTAssertEqual(filter.accept(latest, at: 10.18, confirmEveryChange: true), latest)
    }

    func testNewInputPreventsMatchingTransientPositionsFromConfirmingEachOther() {
        var filter = CaretGeometryFilter()
        let previous = CGRect(x: 612, y: 152, width: 1, height: 16)
        let transient = CGRect(x: 605, y: 152, width: 1, height: 16)
        _ = filter.accept(previous, at: 10)
        for now in stride(from: 10.1, through: 10.5, by: 0.02) {
            XCTAssertNil(filter.accept(transient, at: now, confirmEveryChange: true, activityAt: now - 0.001))
        }
        XCTAssertEqual(filter.accept(previous, at: 10.52, confirmEveryChange: true, activityAt: 10.499), previous)
    }

    func testGenuineMovementCanConfirmAfterInputStops() {
        var filter = CaretGeometryFilter()
        let next = CGRect(x: 620, y: 152, width: 1, height: 16)
        XCTAssertNil(filter.accept(next, at: 10, confirmEveryChange: true, activityAt: 9.99))
        XCTAssertNil(filter.accept(next, at: 10.02, confirmEveryChange: true, activityAt: 10.01))
        XCTAssertEqual(filter.accept(next, at: 10.04, confirmEveryChange: true, activityAt: 10.01), next)
    }

    func testPendingConfirmationDoesNotQueryAccessibility() {
        var queriedAccessibility = false
        var result: PreferencesVM.CursorPosition?
        var emissions = 0
        let subscription = PreferencesVM.preferredCaretPositionPublisher(
            palette: { nil },
            accessibility: {
                queriedAccessibility = true
                return Just((CGPoint(x: 1, y: 2), true)).eraseToAnyPublisher()
            },
            awaitingConfirmation: { true }
        ).sink { result = $0; emissions += 1 }
        XCTAssertEqual(emissions, 1)
        XCTAssertNil(result)
        XCTAssertFalse(queriedAccessibility)
        subscription.cancel()
    }

    func testPendingConfirmationStillUsesFreshLastConfirmedPosition() {
        var queriedAccessibility = false
        var result: PreferencesVM.CursorPosition?
        let subscription = PreferencesVM.preferredCaretPositionPublisher(
            palette: { CGPoint(x: 30, y: 40) },
            accessibility: {
                queriedAccessibility = true
                return Just(nil).eraseToAnyPublisher()
            },
            awaitingConfirmation: { true }
        ).sink { result = $0 }
        XCTAssertEqual(result?.point, CGPoint(x: 30, y: 40))
        XCTAssertFalse(queriedAccessibility)
        subscription.cancel()
    }

    func testConfirmationStartingDuringAccessibilityQuerySuppressesItsResult() {
        let accessibility = PassthroughSubject<PreferencesVM.CursorPosition?, Never>()
        var awaitingConfirmation = false
        var result: PreferencesVM.CursorPosition?
        let subscription = PreferencesVM.preferredCaretPositionPublisher(
            palette: { nil },
            accessibility: { accessibility.eraseToAnyPublisher() },
            awaitingConfirmation: { awaitingConfirmation }
        ).sink { result = $0 }
        awaitingConfirmation = true
        accessibility.send((CGPoint(x: 1, y: 2), true))
        XCTAssertNil(result)
        subscription.cancel()
    }

    func testPendingConfirmationExpiresAndCannotFollowAnotherFocus() {
        let confirmation = CaretPalette.Confirmation(pid: 42, uptime: 10)
        XCTAssertTrue(confirmation.isCurrent(for: 42, now: 10.1, focusedAt: 9))
        XCTAssertFalse(confirmation.isCurrent(for: 42, now: 10.8, focusedAt: 9))
        XCTAssertFalse(confirmation.isCurrent(for: 42, now: 9.9, focusedAt: 9))
        XCTAssertFalse(confirmation.isCurrent(for: 43, now: 10.1, focusedAt: 9))
        XCTAssertFalse(confirmation.isCurrent(for: 42, now: 10.1, focusedAt: 10.05))
    }

    func testCodexReturningToAcceptedPositionCancelsTransientCandidate() {
        var filter = CaretGeometryFilter()
        let previous = CGRect(x: 612, y: 152, width: 1, height: 16)
        let transient = CGRect(x: 605, y: 152, width: 1, height: 16)
        _ = filter.accept(previous, at: 10)
        XCTAssertNil(filter.accept(transient, at: 10.1, confirmEveryChange: true))
        XCTAssertEqual(filter.accept(previous, at: 10.12, confirmEveryChange: true), previous)
        XCTAssertNil(filter.accept(transient, at: 10.2, confirmEveryChange: true))
    }

    func testTransientCodexGeometryDoesNotMoveIndicatorBack() {
        var filter = CaretGeometryFilter()
        let previous = CGRect(x: 740, y: 152, width: 1, height: 16)
        let transient = CGRect(x: 605, y: 92, width: 1, height: 16)
        let current = CGRect(x: 747, y: 152, width: 1, height: 16)
        XCTAssertEqual(filter.accept(previous, at: 10), previous)
        XCTAssertNil(filter.accept(transient, at: 10.1))
        XCTAssertNil(filter.accept(transient, at: 10.102))
        XCTAssertEqual(filter.accept(current, at: 10.119), current)
    }

    func testNearbyTypingAndBackspaceStayImmediate() {
        var filter = CaretGeometryFilter()
        for (index, x) in [740.0, 747.0, 754.0, 747.0].enumerated() {
            let rect = CGRect(x: x, y: 152, width: 1, height: 16)
            XCTAssertEqual(filter.accept(rect, at: 10 + Double(index) * 0.02), rect)
        }
    }

    func testRealRowChangeAndHomeKeyAreConfirmed() {
        for target in [CGRect(x: 740, y: 136, width: 1, height: 16),
                       CGRect(x: 100, y: 152, width: 1, height: 16)] {
            var filter = CaretGeometryFilter()
            _ = filter.accept(CGRect(x: 740, y: 152, width: 1, height: 16), at: 10)
            XCTAssertNil(filter.accept(target, at: 10.1))
            XCTAssertEqual(filter.accept(target, at: 10.12), target)
        }
    }

    func testContinuousLargeMovementCannotStarveUpdates() {
        var filter = CaretGeometryFilter()
        _ = filter.accept(CGRect(x: 100, y: 200, width: 1, height: 16), at: 10)
        XCTAssertNil(filter.accept(CGRect(x: 100, y: 180, width: 1, height: 16), at: 10.1))
        XCTAssertNil(filter.accept(CGRect(x: 100, y: 160, width: 1, height: 16), at: 10.12))
        let latest = CGRect(x: 100, y: 120, width: 1, height: 16)
        XCTAssertEqual(filter.accept(latest, at: 10.16), latest)
    }

    func testInvalidGeometryClearsFilterInsteadOfKeepingOldCaret() {
        var filter = CaretGeometryFilter()
        _ = filter.accept(CGRect(x: 100, y: 200, width: 1, height: 16), at: 10)
        XCTAssertEqual(filter.accept(.zero, at: 10.1), .zero)
        let nextField = CGRect(x: 800, y: 600, width: 1, height: 20)
        XCTAssertEqual(filter.accept(nextField, at: 10.2), nextField)
    }

    func testPollingSlowsDownAfterInputStops() {
        var schedule = CaretPollingSchedule()
        XCTAssertEqual(schedule.interval(at: 10), CaretPollingSchedule.idleInterval)
        schedule.noteActivity(at: 10)
        XCTAssertEqual(schedule.interval(at: 10), CaretPollingSchedule.activeInterval)
        XCTAssertEqual(schedule.interval(at: 10.3), CaretPollingSchedule.activeInterval)
        XCTAssertEqual(schedule.interval(at: 10.4), CaretPollingSchedule.idleInterval)
    }

    func testRepeatedActivityKeepsPollingFastThenReturnsToIdle() {
        var schedule = CaretPollingSchedule()
        for now in stride(from: 10.0, through: 12.0, by: 0.1) {
            schedule.noteActivity(at: now)
            XCTAssertEqual(schedule.interval(at: now + 0.09), CaretPollingSchedule.activeInterval)
        }
        XCTAssertEqual(schedule.interval(at: 12.4), CaretPollingSchedule.idleInterval)
    }

    func testNewActivityImmediatelyResumesFastPollingAfterLongIdle() {
        var schedule = CaretPollingSchedule()
        schedule.noteActivity(at: 10)
        XCTAssertEqual(schedule.interval(at: 100), CaretPollingSchedule.idleInterval)
        schedule.noteActivity(at: 100)
        XCTAssertEqual(schedule.interval(at: 100), CaretPollingSchedule.activeInterval)
        XCTAssertLessThan(CaretPollingSchedule.idleInterval, 0.75)
    }

    func testDefaultIndicatorWaitsForInitialCaretConfirmation() {
        let updates = PassthroughSubject<Void, Never>()
        let timeout = PassthroughSubject<Void, Never>()
        var point: CGPoint?
        var results: [PreferencesVM.CursorPosition?] = []
        let subscription = PreferencesVM.caretPositionWhenReadyPublisher(
            query: {
                PreferencesVM.preferredCaretPositionPublisher(
                    palette: { point },
                    accessibility: { XCTFail("Pending helper must not use AX"); return Just(nil).eraseToAnyPublisher() },
                    awaitingConfirmation: { point == nil }
                )
            },
            changes: updates.eraseToAnyPublisher(),
            awaitingConfirmation: { point == nil },
            deadline: { timeout.eraseToAnyPublisher() }
        ).sink { results.append($0) }

        updates.send(())
        XCTAssertTrue(results.isEmpty, "No relative fallback while focus is being confirmed")
        point = CGPoint(x: 585, y: 114)
        updates.send(())
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first??.point, point)
        XCTAssertEqual(results.first??.isContainer, false)
        timeout.send(())
        updates.send(())
        XCTAssertEqual(results.count, 1)
        subscription.cancel()
    }

    func testDefaultIndicatorFallsBackOnceIfHelperNeverConfirms() {
        let updates = PassthroughSubject<Void, Never>()
        let timeout = PassthroughSubject<Void, Never>()
        var point: PreferencesVM.CursorPosition?
        var results: [PreferencesVM.CursorPosition?] = []
        let subscription = PreferencesVM.caretPositionWhenReadyPublisher(
            query: { Just(point).eraseToAnyPublisher() },
            changes: updates.eraseToAnyPublisher(),
            awaitingConfirmation: { true },
            deadline: { timeout.eraseToAnyPublisher() }
        ).sink { results.append($0) }

        XCTAssertTrue(results.isEmpty)
        timeout.send(())
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0])
        point = (CGPoint(x: 100, y: 200), false)
        updates.send(())
        XCTAssertEqual(results.count, 1, "Do not jump to a late caret after choosing the fallback")
        subscription.cancel()
    }

    func testReadyCaretAndKnownMissingCaretDoNotWait() {
        for position: PreferencesVM.CursorPosition? in [nil, (CGPoint(x: 20, y: 30), false)] {
            var results: [PreferencesVM.CursorPosition?] = []
            let subscription = PreferencesVM.caretPositionWhenReadyPublisher(
                query: { Just(position).eraseToAnyPublisher() },
                changes: Empty().eraseToAnyPublisher(),
                awaitingConfirmation: { false },
                deadline: { XCTFail("No confirmation delay needed"); return Empty().eraseToAnyPublisher() }
            ).sink { results.append($0) }
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results[0]?.point, position?.point)
            subscription.cancel()
        }
    }

    func testLeavingInputFieldEndsPendingCaretWait() {
        let updates = PassthroughSubject<Void, Never>()
        var pending = true
        var results: [PreferencesVM.CursorPosition?] = []
        let subscription = PreferencesVM.caretPositionWhenReadyPublisher(
            query: { Just(nil).eraseToAnyPublisher() },
            changes: updates.eraseToAnyPublisher(),
            awaitingConfirmation: { pending },
            deadline: { Empty(completeImmediately: false).eraseToAnyPublisher() }
        ).sink { results.append($0) }
        XCTAssertTrue(results.isEmpty)
        pending = false
        updates.send(())
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0])
        subscription.cancel()
    }

    func testCancelledActivationCannotDisplayLateCaretOrFallback() {
        let updates = PassthroughSubject<Void, Never>()
        let timeout = PassthroughSubject<Void, Never>()
        var position: PreferencesVM.CursorPosition?
        var results: [PreferencesVM.CursorPosition?] = []
        var stoppedUpdates = false
        var stoppedTimeout = false
        let subscription = PreferencesVM.caretPositionWhenReadyPublisher(
            query: { Just(position).eraseToAnyPublisher() },
            changes: updates.handleEvents(receiveCancel: { stoppedUpdates = true }).eraseToAnyPublisher(),
            awaitingConfirmation: { true },
            deadline: { timeout.handleEvents(receiveCancel: { stoppedTimeout = true }).eraseToAnyPublisher() }
        ).sink { results.append($0) }
        subscription.cancel()
        position = (CGPoint(x: 50, y: 60), false)
        updates.send(())
        timeout.send(())
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(stoppedUpdates)
        XCTAssertTrue(stoppedTimeout)
    }

    func testHelperPositionWinsWithoutReadingAccessibility() {
        var queriedAccessibility = false
        var result: PreferencesVM.CursorPosition?
        let subscription = PreferencesVM.preferredCaretPositionPublisher(
            palette: { CGPoint(x: 30, y: 40) },
            accessibility: {
                queriedAccessibility = true
                return Just(nil).eraseToAnyPublisher()
            }
        ).sink { result = $0 }
        XCTAssertEqual(result?.point, CGPoint(x: 30, y: 40))
        XCTAssertEqual(result?.isContainer, false)
        XCTAssertFalse(queriedAccessibility)
        subscription.cancel()
    }

    func testAccessibilityRemainsAvailableWhenHelperHasNoPosition() {
        var result: PreferencesVM.CursorPosition?
        let subscription = PreferencesVM.preferredCaretPositionPublisher(
            palette: { nil },
            accessibility: { Just((CGPoint(x: 10, y: 20), true)).eraseToAnyPublisher() }
        ).sink { result = $0 }
        XCTAssertEqual(result?.point, CGPoint(x: 10, y: 20))
        XCTAssertEqual(result?.isContainer, true)
        subscription.cancel()
    }

    func testHelperConnectingDuringAccessibilityQueryTakesPriority() {
        let accessibility = PassthroughSubject<PreferencesVM.CursorPosition?, Never>()
        var palettePoint: CGPoint?
        var result: PreferencesVM.CursorPosition?
        let subscription = PreferencesVM.preferredCaretPositionPublisher(
            palette: { palettePoint },
            accessibility: { accessibility.eraseToAnyPublisher() }
        ).sink { result = $0 }
        palettePoint = CGPoint(x: 30, y: 40)
        accessibility.send((CGPoint(x: 10, y: 20), true))
        XCTAssertEqual(result?.point, palettePoint)
        XCTAssertEqual(result?.isContainer, false)
        subscription.cancel()
    }

    func testWakeWaitsForDisplayAndSessionToResume() {
        var suspension = CaretPalette.Suspension()
        suspension.set(.systemSleep, suspended: true)
        suspension.set(.displaySleep, suspended: true)
        suspension.set(.inactiveSession, suspended: true)
        suspension.set(.systemSleep, suspended: false)
        XCTAssertTrue(suspension.isSuspended)
        suspension.set(.displaySleep, suspended: false)
        XCTAssertTrue(suspension.isSuspended)
        suspension.set(.inactiveSession, suspended: false)
        XCTAssertFalse(suspension.isSuspended)
    }

    func testRepeatedLifecycleNotificationsDoNotLeaveTrackerSuspended() {
        var suspension = CaretPalette.Suspension()
        suspension.set(.displaySleep, suspended: true)
        suspension.set(.displaySleep, suspended: true)
        suspension.set(.displaySleep, suspended: false)
        XCTAssertFalse(suspension.isSuspended)
    }

    func testAppKitCoordinatesOnDisplayLeftOfMainScreen() {
        let sample = CaretPalette.Sample(rect: CGRect(x: -500, y: -100, width: 1, height: 24), pid: 42, uptime: 10)
        XCTAssertEqual(sample.point(for: 42, now: 10.1, focusedAt: 9, screens: [screen]), CGPoint(x: -500, y: -70))
    }

    func testRejectsStaleFutureAndPreviousFocusSamples() {
        let sample = CaretPalette.Sample(rect: CGRect(x: -500, y: 100, width: 1, height: 24), pid: 42, uptime: 10)
        XCTAssertNil(sample.point(for: 42, now: 11, focusedAt: 9, screens: [screen]))
        XCTAssertNil(sample.point(for: 42, now: 9, focusedAt: 9, screens: [screen]))
        XCTAssertNil(sample.point(for: 42, now: 10.1, focusedAt: 10.05, screens: [screen]))
        XCTAssertNil(sample.point(for: 99, now: 10.1, focusedAt: 9, screens: [screen]))
    }

    func testRejectsInvalidAndOffscreenGeometry() {
        let rects = [
            CGRect.zero,
            CGRect(x: -500, y: 100, width: 1000, height: 24),
            CGRect(x: -500, y: 100, width: 1, height: 500),
            CGRect(x: 500, y: 100, width: 1, height: 24),
            CGRect(x: CGFloat.nan, y: 100, width: 1, height: 24),
        ]
        for rect in rects {
            let sample = CaretPalette.Sample(rect: rect, pid: 42, uptime: 10)
            XCTAssertNil(sample.point(for: 42, now: 10.1, focusedAt: 9, screens: [screen]))
        }
    }
}
#endif
