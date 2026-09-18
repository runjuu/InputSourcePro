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
}