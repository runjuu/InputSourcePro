import ApplicationServices
import XCTest
@testable import Input_Source_Pro

final class QueryWebAreaServiceTests: XCTestCase {
    private let pageURL = URL(string: "https://example.com/page")!

    func testSkipsPersistentNewTabFooterWithoutWindowDocument() throws {
        let footer = element("chrome://newtab-footer/")
        let page = element(pageURL.absoluteString)

        XCTAssertTrue(try query([footer, page]).perform() === page)
    }

    func testPrefersWindowDocumentOverEarlierSidebarWebArea() throws {
        let sidebar = element("https://sidebar.example/")
        let page = element(pageURL.absoluteString)

        XCTAssertTrue(try query([sidebar, page]).perform(documentURL: pageURL) === page)
    }

    func testKeepsFirstEligibleWebAreaWhenDocumentDoesNotMatch() throws {
        let first = element(pageURL.absoluteString)
        let second = element("https://other.example/")

        XCTAssertTrue(try query([first, second]).perform(
            documentURL: URL(string: "https://stale.example/")!
        ) === first)
    }

    func testKeepsFirstEligibleWebAreaWithoutWindowDocument() throws {
        let first = element(pageURL.absoluteString)
        let second = element("https://other.example/")

        XCTAssertTrue(try query([first, second]).perform() === first)
    }

    func testDocumentCannotSelectFooterOrExtensionWebArea() throws {
        for address in ["chrome://newtab-footer/", "chrome-extension://extension/popup.html"] {
            let excluded = element(address)
            let page = element(pageURL.absoluteString)

            XCTAssertTrue(try query([excluded, page]).perform(
                documentURL: excluded.url
            ) === page, address)
        }
    }

    func testPreservesRealNewTabAndOtherInternalPages() throws {
        for address in ["chrome://newtab/", "chrome://new-tab-page/", "chrome://settings/"] {
            let page = element(address)
            let footer = element("chrome://newtab-footer/")

            XCTAssertTrue(try query([footer, page]).perform() === page, address)
            // AXDocument and AXURL can expose different aliases for the NTP.
            XCTAssertTrue(try query([footer, page]).perform(
                documentURL: URL(string: "chrome://newtab/")!
            ) === page, address)
        }
    }

    func testFooterExclusionDoesNotMatchOtherSchemesOrHosts() throws {
        for address in ["https://newtab-footer/", "chrome://newtab-footer.example/"] {
            let page = element(address)
            XCTAssertTrue(try query([page]).perform() === page, address)
        }
    }

    func testReturnsNilWithNoEligibleWebArea() throws {
        let footer = element("chrome://newtab-footer/")
        let popup = element("chrome-extension://extension/popup.html")

        XCTAssertNil(try query([]).perform(documentURL: pageURL))
        XCTAssertNil(try query([footer, popup]).perform(documentURL: pageURL))
    }

    func testCanMatchDocumentAfterWebAreaWithNoURL() throws {
        let loading = element(nil)
        let page = element(pageURL.absoluteString)

        XCTAssertTrue(try query([loading, page]).perform(documentURL: pageURL) === page)
        XCTAssertTrue(try query([loading, page]).perform() === loading)
    }

    func testDoesNotTraversePageContentsWhileLookingForDocument() throws {
        let window = element(nil, role: "AXWindow")
        let sidebar = element("https://sidebar.example/")
        let page = element(pageURL.absoluteString)
        let service = QueryWebAreaService(windowElement: window) { node in
            guard node === window else {
                XCTFail("Web areas should be treated as leaves")
                return []
            }
            return [page, sidebar]
        }

        XCTAssertTrue(try service.perform(documentURL: pageURL) === page)
    }

    func testDoesNotTraverseExcludedWebAreaContents() throws {
        let window = element(nil, role: "AXWindow")
        let footer = element("chrome://newtab-footer/")
        let popup = element("chrome-extension://extension/popup.html")
        let page = element(pageURL.absoluteString)
        let service = QueryWebAreaService(windowElement: window) { node in
            guard node === window else {
                XCTFail("Excluded web areas must not expose nested candidates")
                return []
            }
            return [page, popup, footer]
        }

        XCTAssertTrue(try service.perform(documentURL: pageURL) === page)
    }

    func testStopsBeforeLaterSiblingsOnceDocumentMatches() throws {
        let window = element(nil, role: "AXWindow")
        let later = element(nil, role: "AXGroup")
        let page = element(pageURL.absoluteString)
        let service = QueryWebAreaService(windowElement: window) { node in
            guard node === window else {
                XCTFail("The document match should end the search")
                return []
            }
            return [later, page]
        }

        XCTAssertTrue(try service.perform(documentURL: pageURL) === page)
        XCTAssertTrue(try service.perform() === page)
    }

    func testKeepsFallbackWhenLaterAccessibilityReadFails() throws {
        let window = element(nil, role: "AXWindow")
        let unavailable = element(nil, role: "AXGroup")
        let first = element("https://sidebar.example/")
        let service = QueryWebAreaService(windowElement: window) { node in
            if node === window { return [unavailable, first] }
            throw ReadFailure.unavailable
        }

        XCTAssertTrue(try service.perform(documentURL: pageURL) === first)
    }

    func testContinuesLookingForDocumentAfterFailedReadWithFallback() throws {
        let window = element(nil, role: "AXWindow")
        let unavailable = element(nil, role: "AXGroup")
        let first = element("https://sidebar.example/")
        let page = element(pageURL.absoluteString)
        let service = QueryWebAreaService(windowElement: window) { node in
            if node === window { return [page, unavailable, first] }
            throw ReadFailure.unavailable
        }

        XCTAssertTrue(try service.perform(documentURL: pageURL) === page)
    }

    func testPropagatesAccessibilityFailureBeforeFindingAnyCandidate() {
        let service = QueryWebAreaService(windowElement: element(nil, role: "AXWindow")) { _ in
            throw ReadFailure.unavailable
        }

        XCTAssertThrowsError(try service.perform(documentURL: pageURL)) { error in
            XCTAssertTrue(error is ReadFailure)
        }
    }

    func testPropagatesAccessibilityFailureBeforePendingDocumentMatch() {
        let window = element(nil, role: "AXWindow")
        let unavailable = element(nil, role: "AXGroup")
        let content = element(nil, role: "AXGroup")
        let page = element(pageURL.absoluteString)
        var didReadContent = false
        let service = QueryWebAreaService(windowElement: window) { node in
            if node === window { return [content, unavailable] }
            if node === unavailable { throw ReadFailure.unavailable }
            if node === content {
                didReadContent = true
                return [page]
            }
            return []
        }

        XCTAssertThrowsError(try service.perform(documentURL: pageURL)) { error in
            XCTAssertTrue(error is ReadFailure)
        }
        XCTAssertFalse(didReadContent)
    }

    func testPropagatesAccessibilityFailureBeforePendingPageWithoutDocument() {
        let window = element(nil, role: "AXWindow")
        let unavailable = element(nil, role: "AXGroup")
        let content = element(nil, role: "AXGroup")
        let page = element(pageURL.absoluteString)
        var didReadContent = false
        let service = QueryWebAreaService(windowElement: window) { node in
            if node === window { return [content, unavailable] }
            if node === unavailable { throw ReadFailure.unavailable }
            if node === content {
                didReadContent = true
                return [page]
            }
            return []
        }

        XCTAssertThrowsError(try service.perform()) { error in
            XCTAssertTrue(error is ReadFailure)
        }
        XCTAssertFalse(didReadContent)
    }

    private enum ReadFailure: Error {
        case unavailable
    }

    // Fixtures are ordered as encountered by the service's last-child-first DFS.
    private func query(_ webAreas: [Element]) -> QueryWebAreaService {
        let window = element(nil, role: "AXWindow")
        return QueryWebAreaService(windowElement: window) { node in
            node === window ? Array(webAreas.reversed()) : []
        }
    }

    private func element(_ address: String?, role: String = "AXWebArea") -> Element {
        Element(
            rawElement: AXUIElementCreateApplication(getpid()),
            role: role,
            url: address.flatMap { URL(string: $0) }
        )
    }
}
