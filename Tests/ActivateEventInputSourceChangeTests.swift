import AppKit
import Combine
import XCTest
@testable import Input_Source_Pro

@MainActor
final class ActivateEventInputSourceChangeTests: XCTestCase {
    private let app = NSRunningApplication.current

    private func appKind() -> AppKind {
        .normal(app: app, info: (focusedElement: nil, isFocusOnInputContainer: true))
    }

    func testAppChangesWithUnchangedInputSourceIsFlagged() {
        let event = IndicatorVM.ActivateEvent.appChanges(
            current: appKind(),
            prev: appKind(),
            inputSourceDidChange: false
        )

        XCTAssertTrue(event.isAppChangesWithUnchangedInputSource)
        XCTAssertTrue(event.isAppChangesWithSameAppOrWebsite())
        XCTAssertFalse(event.isJustHide)
    }

    func testAppChangesWithChangedInputSourceIsNotFlagged() {
        let event = IndicatorVM.ActivateEvent.appChanges(
            current: appKind(),
            prev: appKind(),
            inputSourceDidChange: true
        )

        XCTAssertFalse(event.isAppChangesWithUnchangedInputSource)
        XCTAssertTrue(event.isAppChangesWithSameAppOrWebsite())
        XCTAssertFalse(event.isJustHide)
    }

    func testNonAppChangeEventsAreNotFlagged() {
        XCTAssertFalse(IndicatorVM.ActivateEvent.justHide.isAppChangesWithUnchangedInputSource)
        XCTAssertFalse(IndicatorVM.ActivateEvent.longMouseDown.isAppChangesWithUnchangedInputSource)
    }

    func testJustHideIsFlaggedAndNotAppChange() {
        let event = IndicatorVM.ActivateEvent.justHide
        XCTAssertTrue(event.isJustHide)
        XCTAssertFalse(event.isAppChangesWithUnchangedInputSource)
        XCTAssertFalse(event.isAppChangesWithSameAppOrWebsite())
    }

    func testTimerToleranceCanBeSpecified() {
        let delayPublisher = Timer.delay(seconds: 0.1, tolerance: 0.05)
        let intervalPublisher = Timer.interval(seconds: 0.5, tolerance: 0.05)
        XCTAssertNotNil(delayPublisher)
        XCTAssertNotNil(intervalPublisher)
    }

    func testUnchangedInputSourcePreservesFocusedFieldTracking() {
        XCTAssertEqual(activationMode(inputSourceDidChange: false, focusedField: true), .autoShow)
    }

    func testUnchangedInputSourceSuppressesOnlyTransientAppSwitchActivation() {
        XCTAssertEqual(activationMode(inputSourceDidChange: false), .hide)
        XCTAssertEqual(activationMode(inputSourceDidChange: true), .autoHide)
    }

    func testExplicitHideOverridesFocusedFieldTracking() {
        for focusedField in [false, true] {
            XCTAssertEqual(IndicatorWindowController.activationMode(
                event: .justHide,
                focusedField: focusedField
            ), .hide)
        }
    }

    func testFunctionKeyFeedbackPreservesFocusedFieldTracking() {
        for mode in [FKeyMode.functionKeys, .mediaKeys] {
            XCTAssertEqual(IndicatorWindowController.activationMode(
                event: .functionKeyModeChanges(mode),
                focusedField: true
            ), .autoShow)
        }
    }

    func testIndependentTriggersActivateWithoutAppSwitchTriggerOrTextFocus() {
        let events: [IndicatorVM.ActivateEvent] = [
            .inputSourceChanges(InputSource.getCurrentInputSource(), .system),
            .longMouseDown,
        ]

        for event in events {
            XCTAssertTrue(event.shouldActivateInitially(
                onAppSwitch: false,
                onInputFocus: true,
                isInputFocused: false
            ))
        }
    }

    func testAppSwitchStillRespectsInputSourceChangesAndFocusedFieldPreference() {
        let unchanged = IndicatorVM.ActivateEvent.appChanges(
            current: appKind(), prev: appKind(), inputSourceDidChange: false
        )
        XCTAssertFalse(unchanged.shouldActivateInitially(
            onAppSwitch: true, onInputFocus: false, isInputFocused: true
        ))
        XCTAssertFalse(unchanged.shouldActivateInitially(
            onAppSwitch: true, onInputFocus: true, isInputFocused: false
        ))
        XCTAssertTrue(unchanged.shouldActivateInitially(
            onAppSwitch: false, onInputFocus: true, isInputFocused: true
        ))

        let changed = IndicatorVM.ActivateEvent.appChanges(
            current: appKind(), prev: appKind(), inputSourceDidChange: true
        )
        XCTAssertTrue(changed.shouldActivateInitially(
            onAppSwitch: true, onInputFocus: false, isInputFocused: false
        ))
        XCTAssertFalse(changed.shouldActivateInitially(
            onAppSwitch: false, onInputFocus: false, isInputFocused: true
        ))
    }

    func testExplicitTriggersKeepWatchingFocusAfterImmediateHintCompletes() {
        let events: [IndicatorVM.ActivateEvent] = [
            .inputSourceChanges(InputSource.getCurrentInputSource(), .system),
            .longMouseDown,
        ]

        for event in events {
            let focusedInputs = PassthroughSubject<Void, Never>()
            var showCount = 0
            var completed = false
            let subscription = IndicatorWindowController.focusTriggeredIndicatorPublisher(
                initialEvent: event.shouldActivateInitially(
                    onAppSwitch: false, onInputFocus: true, isInputFocused: false
                ) ? event : nil,
                inputSource: InputSource.getCurrentInputSource(),
                focusedInputs: focusedInputs.eraseToAnyPublisher(),
                show: { _ in
                    showCount += 1
                    return Just(()).eraseToAnyPublisher()
                }
            )
            .sink(receiveCompletion: { _ in completed = true }, receiveValue: { _ in })

            XCTAssertEqual(showCount, 1)
            XCTAssertFalse(completed)
            focusedInputs.send(())
            XCTAssertEqual(showCount, 2)
            XCTAssertFalse(completed)

            subscription.cancel()
            focusedInputs.send(())
            XCTAssertEqual(showCount, 2)
        }
    }

    func testStatusBadgesKeepWatchingFocusWithoutReplayingBadge() {
        let inputSource = InputSource.getCurrentInputSource()
        let events: [IndicatorVM.ActivateEvent] = [
            .capsLockChanges(true), .capsLockChanges(false),
            .functionKeyModeChanges(.functionKeys), .functionKeyModeChanges(.mediaKeys),
        ]

        for event in events {
            for completeBadgeBeforeFocus in [true, false] {
                XCTAssertEqual(IndicatorWindowController.activationMode(
                    event: event, focusedField: true
                ), .autoShow)

                let focusedInputs = PassthroughSubject<Void, Never>()
                let badge = PassthroughSubject<Void, Never>()
                var shown: [String] = []
                var completed = false
                var badgeCancelled = false
                let subscription = IndicatorWindowController.focusTriggeredIndicatorPublisher(
                    initialEvent: event,
                    inputSource: inputSource,
                    focusedInputs: focusedInputs.eraseToAnyPublisher()
                ) { shownEvent in
                    shown.append(shownEvent.description)
                    if case let .inputSourceChanges(source, reason) = shownEvent {
                        XCTAssertEqual(source.persistentIdentifier, inputSource.persistentIdentifier)
                        if case .noChanges = reason {} else {
                            XCTFail("Focusing a field must not report an input-source change")
                        }
                        return Just(()).eraseToAnyPublisher()
                    }
                    return badge
                        .handleEvents(receiveCancel: { badgeCancelled = true })
                        .eraseToAnyPublisher()
                }
                .sink(receiveCompletion: { _ in completed = true }, receiveValue: { _ in })

                XCTAssertEqual(shown, [event.description])
                if completeBadgeBeforeFocus {
                    badge.send(())
                    badge.send(completion: .finished)
                }
                XCTAssertFalse(completed)

                focusedInputs.send(())
                focusedInputs.send(())
                XCTAssertEqual(shown, [event.description, "inputSourceChanges", "inputSourceChanges"])
                XCTAssertEqual(badgeCancelled, !completeBadgeBeforeFocus)
                XCTAssertFalse(completed)

                subscription.cancel()
                focusedInputs.send(())
                XCTAssertEqual(shown.count, 3)
            }
        }
    }

    func testSuppressedInitialHintStillWatchesLaterFocus() {
        let focusedInputs = PassthroughSubject<Void, Never>()
        var showCount = 0
        let subscription = IndicatorWindowController.focusTriggeredIndicatorPublisher(
            initialEvent: nil,
            inputSource: InputSource.getCurrentInputSource(),
            focusedInputs: focusedInputs.eraseToAnyPublisher(),
            show: { _ in
                showCount += 1
                return Just(()).eraseToAnyPublisher()
            }
        )
        .sink { _ in }

        XCTAssertEqual(showCount, 0)
        focusedInputs.send(())
        XCTAssertEqual(showCount, 1)
        subscription.cancel()
    }

    private func activationMode(
        inputSourceDidChange: Bool,
        focusedField: Bool = false
    ) -> IndicatorWindowController.ActivationMode {
        IndicatorWindowController.activationMode(
            event: .appChanges(current: appKind(), prev: appKind(), inputSourceDidChange: inputSourceDidChange),
            focusedField: focusedField
        )
    }
}
