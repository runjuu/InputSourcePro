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

    func testWhalePreservesEncodedDelimitersWhenMatchingAddressBar() {
        let paths = [("/a%2Fb", "/a/b"), ("/a%3Fb", "/a?b"), ("/?q=a%26b", "/?q=a&b")]
        for (encodedPath, literalPath) in paths {
            let encodedURL = URL(string: "https://example.com\(encodedPath)")!
            let literalURL = URL(string: "https://example.com\(literalPath)")!
            for (documentURL, activeURL, address) in [
                (encodedURL, literalURL, "example.com\(literalPath)"),
                (literalURL, encodedURL, "example.com\(encodedPath)"),
            ] {
                XCTAssertEqual(Browser.Whale.selectWhaleTabURL(
                    documentURL: documentURL,
                    webAreaURLs: [encodedURL, literalURL],
                    focusedWebAreaURL: nil,
                    addressBarValue: address
                ), activeURL, address)
            }
        }
    }

    func testWhaleMatchesUnicodeAddressBarWithEncodedPageURL() {
        for path in ["/%ED%95%9C%EA%B8%80", "/%ed%95%9c%ea%b8%80"] {
            let koreanPage = URL(string: "https://example.com\(path)")!
            XCTAssertEqual(Browser.Whale.selectWhaleTabURL(
                documentURL: left,
                webAreaURLs: [left, koreanPage],
                focusedWebAreaURL: nil,
                addressBarValue: "example.com/한글"
            ), koreanPage)
        }
    }

    func testWhaleMatchesUnreservedEscapesInAddressBar() {
        let encodedPage = URL(string: "https://example.com/%41%7e%2D%2E%5f%30")!
        XCTAssertEqual(Browser.Whale.selectWhaleTabURL(
            documentURL: left,
            webAreaURLs: [left, encodedPage],
            focusedWebAreaURL: nil,
            addressBarValue: "example.com/A~-._0"
        ), encodedPage)
    }

    func testWhaleMatchesElidedAddressContainingURLInQuery() {
        let searchPage = URL(string: "https://search.example/search?q=https://example.org")!
        XCTAssertEqual(Browser.Whale.selectWhaleTabURL(
            documentURL: left,
            webAreaURLs: [left, searchPage],
            focusedWebAreaURL: nil,
            addressBarValue: "search.example/search?q=https://example.org"
        ), searchPage)
    }
}
