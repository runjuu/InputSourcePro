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

    func testFunctionKeyFeedbackRemainsTransientInPersistentModes() {
        for mode in [FKeyMode.functionKeys, .mediaKeys] {
            XCTAssertEqual(IndicatorWindowController.activationMode(
                event: .functionKeyModeChanges(mode),
                focusedField: true
            ), .autoHide)
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
                activateInitially: event.shouldActivateInitially(
                    onAppSwitch: false, onInputFocus: true, isInputFocused: false
                ),
                focusedInputs: focusedInputs.eraseToAnyPublisher(),
                show: {
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

    func testSuppressedInitialHintStillWatchesLaterFocus() {
        let focusedInputs = PassthroughSubject<Void, Never>()
        var showCount = 0
        let subscription = IndicatorWindowController.focusTriggeredIndicatorPublisher(
            activateInitially: false,
            focusedInputs: focusedInputs.eraseToAnyPublisher(),
            show: {
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
