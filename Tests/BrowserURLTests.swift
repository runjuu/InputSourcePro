import XCTest
@testable import Input_Source_Pro

final class BrowserURLTests: XCTestCase {
    private let left = URL(string: "https://example.com/")!
    private let right = URL(string: "https://www.iana.org/domains/reserved")!
    private let sidebar = URL(string: "https://m.naver.com/")!
    private let whaleNewTab = URL(string: "chrome-extension://mdppnmkhoflepinhojdkmkanhhlkginn/index.html")!

    func testWhaleUsesFocusedSplitPaneInsteadOfLeftWindowDocument() {
        XCTAssertEqual(Browser.Whale.selectWhaleTabURL(
            documentURL: left,
            webAreaURLs: [right, left],
            focusedWebAreaURL: right,
            addressBarValue: "example.com"
        ), right)
    }

    func testWhaleUsesAddressBarWhenFocusLeavesSplitPane() {
        XCTAssertEqual(Browser.Whale.selectWhaleTabURL(
            documentURL: left,
            webAreaURLs: [right, left],
            focusedWebAreaURL: nil,
            addressBarValue: "iana.org/domains/reserved"
        ), right)
    }

    func testWhaleIgnoresSidebarFocus() {
        XCTAssertEqual(Browser.Whale.selectWhaleTabURL(
            documentURL: left,
            webAreaURLs: [right, left],
            focusedWebAreaURL: sidebar,
            addressBarValue: "example.com"
        ), left)
    }

    func testWhaleDoesNotUseUncommittedAddressAsPageURL() {
        XCTAssertEqual(Browser.Whale.selectWhaleTabURL(
            documentURL: left,
            webAreaURLs: [right, left],
            focusedWebAreaURL: nil,
            addressBarValue: "https://unvisited.example/path"
        ), left)
    }

    func testWhaleRecognizesNewTabInRightSplitPane() {
        XCTAssertEqual(Browser.Whale.selectWhaleTabURL(
            documentURL: left,
            webAreaURLs: [whaleNewTab, left],
            focusedWebAreaURL: nil,
            addressBarValue: ""
        ), .newtab)
    }

    func testWhaleRecognizesFocusedNewTabExtension() {
        XCTAssertEqual(Browser.Whale.selectWhaleTabURL(
            documentURL: left,
            webAreaURLs: [whaleNewTab, left],
            focusedWebAreaURL: whaleNewTab,
            addressBarValue: ""
        ), .newtab)
    }

    func testAllThreeBrowsersRecognizeCanonicalNewTabDocument() {
        for browser in [Browser.Comet, .Aside, .Whale] {
            XCTAssertEqual(browser.normalizedTabURL(URL(string: "chrome://newtab/")!), .newtab)
        }
    }

    func testWhalePreservesRegularExtensionPages() {
        let settings = URL(string: "chrome-extension://mdppnmkhoflepinhojdkmkanhhlkginn/settings.html")!
        XCTAssertEqual(Browser.Whale.normalizedTabURL(settings), settings)
    }

    func testWhalePrefersExactURLWhenPanesDifferOnlyByScheme() {
        let httpPage = URL(string: "http://example.com/")!
        XCTAssertEqual(Browser.Whale.selectWhaleTabURL(
            documentURL: left,
            webAreaURLs: [left, httpPage],
            focusedWebAreaURL: nil,
            addressBarValue: "http://example.com/"
        ), httpPage)
    }
}
