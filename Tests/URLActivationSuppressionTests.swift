import XCTest
@testable import Input_Source_Pro

/// Verifies the pure window logic behind `AppDelegate`'s decision to suppress the
/// Preferences window when an activation is the side effect of an `open` URL
/// action (rather than a genuine user activation).
final class URLActivationSuppressionTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let window: TimeInterval = 2

    func testNoRecentURLActionDoesNotSuppress() {
        XCTAssertFalse(AppDelegate.shouldSuppressPreferences(
            lastURLActionAt: nil, now: base, window: window
        ))
    }

    func testActivationWithinWindowSuppresses() {
        XCTAssertTrue(AppDelegate.shouldSuppressPreferences(
            lastURLActionAt: base, now: base.addingTimeInterval(0.1), window: window
        ))
    }

    func testActivationAtSameInstantSuppresses() {
        XCTAssertTrue(AppDelegate.shouldSuppressPreferences(
            lastURLActionAt: base, now: base, window: window
        ))
    }

    func testActivationJustInsideWindowSuppresses() {
        XCTAssertTrue(AppDelegate.shouldSuppressPreferences(
            lastURLActionAt: base, now: base.addingTimeInterval(window - 0.001), window: window
        ))
    }

    func testActivationAtWindowBoundaryDoesNotSuppress() {
        // The boundary is exclusive: exactly `window` later counts as a fresh
        // activation, not part of the `open` burst.
        XCTAssertFalse(AppDelegate.shouldSuppressPreferences(
            lastURLActionAt: base, now: base.addingTimeInterval(window), window: window
        ))
    }

    func testActivationAfterWindowDoesNotSuppress() {
        // The original one-shot flag could linger and swallow this; the timestamp
        // window auto-expires, so a later genuine activation still opens Preferences.
        XCTAssertFalse(AppDelegate.shouldSuppressPreferences(
            lastURLActionAt: base, now: base.addingTimeInterval(60), window: window
        ))
    }

    func testActivationBeforeURLActionDoesNotSuppress() {
        // A timestamp in the future (out-of-order delivery / clock skew) must not
        // suppress a real activation.
        XCTAssertFalse(AppDelegate.shouldSuppressPreferences(
            lastURLActionAt: base, now: base.addingTimeInterval(-1), window: window
        ))
    }
}
