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
}