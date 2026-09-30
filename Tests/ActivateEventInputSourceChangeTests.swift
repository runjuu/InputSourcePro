import AppKit
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

    func testUnchangedInputSourcePreservesAlwaysOnTracking() {
        XCTAssertEqual(activationMode(inputSourceDidChange: false, alwaysOn: true), .alwaysOn)
        XCTAssertEqual(activationMode(inputSourceDidChange: false, alwaysOn: true, focusedField: true), .alwaysOn)
    }

    func testUnchangedInputSourceSuppressesOnlyTransientAppSwitchActivation() {
        XCTAssertEqual(activationMode(inputSourceDidChange: false), .hide)
        XCTAssertEqual(activationMode(inputSourceDidChange: true), .autoHide)
    }

    func testExplicitHideOverridesPersistentModes() {
        for alwaysOn in [false, true] {
            for focusedField in [false, true] {
                XCTAssertEqual(IndicatorWindowController.activationMode(
                    event: .justHide,
                    alwaysOn: alwaysOn,
                    focusedField: focusedField
                ), .hide)
            }
        }
    }

    func testFunctionKeyFeedbackRemainsTransientInPersistentModes() {
        for mode in [FKeyMode.functionKeys, .mediaKeys] {
            XCTAssertEqual(IndicatorWindowController.activationMode(
                event: .functionKeyModeChanges(mode),
                alwaysOn: true,
                focusedField: true
            ), .autoHide)
        }
    }

    private func activationMode(
        inputSourceDidChange: Bool,
        alwaysOn: Bool = false,
        focusedField: Bool = false
    ) -> IndicatorWindowController.ActivationMode {
        IndicatorWindowController.activationMode(
            event: .appChanges(current: appKind(), prev: appKind(), inputSourceDidChange: inputSourceDidChange),
            alwaysOn: alwaysOn,
            focusedField: focusedField
        )
    }
}
