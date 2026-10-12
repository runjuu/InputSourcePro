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

    func testExternalSourceChangeAcrossHostsUsesInputSourceTrigger() {
        let previous = state(source: "EN", host: "before.example")
        let current = state(source: "RU", host: "after.example")

        for hideForcedKeyboard in [false, true] {
            let event = activationEvent(
                previous: previous,
                current: current,
                hideWhenSwitchAppWithForceKeyboard: hideForcedKeyboard
            )

            guard case let .inputSourceChanges(source, reason) = event else {
                XCTFail("An external source change must use its enabled trigger across hosts")
                continue
            }
            XCTAssertEqual(source.persistentIdentifier, "RU")
            guard case .system = reason else {
                XCTFail("The external source-change reason must be preserved")
                continue
            }
        }
    }

    func testExternalSourceChangeWithinHostUsesInputSourceTrigger() {
        let event = activationEvent(
            previous: state(source: "EN", host: "example.com"),
            current: state(source: "RU", host: "example.com")
        )

        guard case let .inputSourceChanges(source, reason) = event else {
            return XCTFail("An external source change must use its enabled trigger within a host")
        }
        XCTAssertEqual(source.persistentIdentifier, "RU")
        guard case .system = reason else {
            return XCTFail("The external source-change reason must be preserved")
        }
    }

    func testDisabledSourceTriggerPreservesEnabledAppSwitchTrigger() {
        let previous = state(source: "EN", host: "before.example")
        let current = state(source: "RU", host: "after.example")
        let event = activationEvent(
            previous: previous,
            current: current,
            onAppSwitch: true,
            onInputSourceChange: false
        )

        guard case let .appChanges(actualCurrent, actualPrevious, inputSourceDidChange) = event else {
            return XCTFail("A disabled source trigger must leave the app-switch trigger available")
        }
        XCTAssertEqual(actualCurrent?.getId(), current.appKind?.getId())
        XCTAssertEqual(actualPrevious?.getId(), previous.appKind?.getId())
        XCTAssertTrue(inputSourceDidChange)
    }

    func testExternalSourceChangeStaysHiddenWhenAllTriggersAreDisabled() {
        let event = activationEvent(
            previous: state(source: "EN", host: "before.example"),
            current: state(source: "RU", host: "after.example"),
            onInputSourceChange: false
        )

        XCTAssertTrue(event.isJustHide)
    }

    func testInitialStateDoesNotInventAnExternalSourceChange() {
        let current = state(source: "RU", host: "example.com")

        XCTAssertTrue(activationEvent(previous: nil, current: current).isJustHide)
        let appEvent = activationEvent(previous: nil, current: current, onAppSwitch: true)
        guard case .appChanges = appEvent else {
            return XCTFail("Initial state must continue to use app-switch gating")
        }
    }

    func testRuleDrivenSourceChangesPreserveForcedKeyboardHiding() {
        let previous = state(source: "EN", host: "before.example")
        let forcedSource = TestInputSource("RU")
        let current = state(
            source: "RU",
            host: "after.example",
            reason: .appSpecified(.specified(forcedSource))
        )

        XCTAssertTrue(activationEvent(
            previous: previous,
            current: current,
            onAppSwitch: true,
            hideWhenSwitchAppWithForceKeyboard: true
        ).isJustHide)
        let visibleEvent = activationEvent(previous: previous, current: current, onAppSwitch: true)
        guard case .appChanges = visibleEvent else {
            return XCTFail("Rule-driven switches must retain app-switch gating")
        }

        let cachedEvent = activationEvent(
            previous: previous,
            current: state(source: "RU", host: "after.example", reason: .appSpecified(.cached(forcedSource))),
            onAppSwitch: true,
            hideWhenSwitchAppWithForceKeyboard: true
        )
        guard case .appChanges = cachedEvent else {
            return XCTFail("Restoring a cached source must remain exempt from forced-keyboard hiding")
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

    private func state(
        source: String,
        host: String,
        reason: IndicatorVM.InputSourceChangeReason = .system
    ) -> IndicatorVM.State {
        .init(
            appKind: .browser(
                app: app,
                info: (
                    focusedElement: nil,
                    isFocusOnInputContainer: true,
                    url: URL(string: "https://\(host)/"),
                    rule: nil,
                    isFocusedOnAddressBar: false
                )
            ),
            inputSource: TestInputSource(source),
            inputSourceChangeReason: reason
        )
    }

    private func activationEvent(
        previous: IndicatorVM.State?,
        current: IndicatorVM.State,
        onAppSwitch: Bool = false,
        onInputFocus: Bool = false,
        onInputSourceChange: Bool = true,
        hideWhenSwitchAppWithForceKeyboard: Bool = false
    ) -> IndicatorVM.ActivateEvent {
        IndicatorVM.activationEvent(
            previous: previous,
            current: current,
            onAppSwitch: onAppSwitch,
            onInputFocus: onInputFocus,
            onInputSourceChange: onInputSourceChange,
            hideWhenSwitchAppWithForceKeyboard: hideWhenSwitchAppWithForceKeyboard
        )
    }

    private final class TestInputSource: InputSource {
        private let identifier: String

        init(_ identifier: String) {
            self.identifier = identifier
            super.init(tisInputSource: InputSource.getCurrentInputSource().tisInputSource)
        }

        override var persistentIdentifier: String { identifier }
    }
}
