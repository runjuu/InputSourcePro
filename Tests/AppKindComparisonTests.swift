import AppKit
import XCTest
@testable import Input_Source_Pro

@MainActor
final class AppKindComparisonTests: XCTestCase {
    private let app = NSRunningApplication.current

    func testFocusedAddressBarCreatesBrowserInfoWithoutURL() {
        let browserInfo = AppKind.makeBrowserInfo(
            focusedElement: nil,
            isFocusOnInputContainer: true,
            url: nil,
            rule: nil,
            isFocusedOnAddressBar: true
        )

        XCTAssertNotNil(browserInfo)
        XCTAssertNil(browserInfo?.url)
        XCTAssertEqual(browserInfo?.isFocusedOnAddressBar, true)
    }

    func testMissingURLOutsideAddressBarDoesNotCreateBrowserInfo() {
        let browserInfo = AppKind.makeBrowserInfo(
            focusedElement: nil,
            isFocusOnInputContainer: true,
            url: nil,
            rule: nil,
            isFocusedOnAddressBar: false
        )

        XCTAssertNil(browserInfo)
    }

    func testFocusedAddressBarPreservesObservedPageURL() {
        let url = URL(string: "https://example.com/page")!
        let browserInfo = AppKind.makeBrowserInfo(
            focusedElement: nil,
            isFocusOnInputContainer: true,
            url: url,
            rule: nil,
            isFocusedOnAddressBar: true
        )

        XCTAssertEqual(browserInfo?.url, url)
    }

    func testAddressBarTextMutationDoesNotChangeContext() {
        let previous = browser(url: URL(string: "https://example.com")!, addressBarFocused: true)
        let current = browser(url: URL(string: "https://search.invalid/n")!, addressBarFocused: true)

        XCTAssertTrue(current.isSameAppOrWebsite(with: previous, detectAddressBar: true))
    }

    func testEnteringAddressBarChangesContextWhenDetectionIsEnabled() {
        let url = URL(string: "https://example.com")!
        let previous = browser(url: url, addressBarFocused: false)
        let current = browser(url: url, addressBarFocused: true)

        XCTAssertFalse(current.isSameAppOrWebsite(with: previous, detectAddressBar: true))
    }

    func testLeavingAddressBarChangesContextWhenDetectionIsEnabled() {
        let url = URL(string: "https://example.com")!
        let previous = browser(url: url, addressBarFocused: true)
        let current = browser(url: url, addressBarFocused: false)

        XCTAssertFalse(current.isSameAppOrWebsite(with: previous, detectAddressBar: true))
    }

    func testNavigationChangesContextOutsideAddressBar() {
        let previous = browser(url: URL(string: "https://example.com")!, addressBarFocused: false)
        let current = browser(url: URL(string: "https://example.com/next")!, addressBarFocused: false)

        XCTAssertFalse(current.isSameAppOrWebsite(with: previous, detectAddressBar: true))
    }

    func testNormalAndBrowserWithUnknownURLAreDifferentContexts() {
        let normal = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: true)
        )
        let unknownBrowser = browser(url: nil, addressBarFocused: true)

        XCTAssertFalse(unknownBrowser.isSameAppOrWebsite(with: normal, detectAddressBar: true))
        XCTAssertFalse(normal.isSameAppOrWebsite(with: unknownBrowser, detectAddressBar: true))
    }

    func testNewTabURLDoesNotCreateWebsiteId() {
        let newTab = browser(url: .newtab, addressBarFocused: false)

        XCTAssertNil(newTab.getId())
    }

    private func browser(url: URL?, addressBarFocused: Bool) -> AppKind {
        return .browser(
            app: app,
            info: (
                focusedElement: nil,
                isFocusOnInputContainer: true,
                url: url,
                rule: nil,
                isFocusedOnAddressBar: addressBarFocused
            )
        )
    }
}
