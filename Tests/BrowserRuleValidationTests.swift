import XCTest
@testable import Input_Source_Pro

final class BrowserRuleValidationTests: XCTestCase {
    func testDomainSuffixMatchesExactDomain() {
        XCTAssertTrue(BrowserRule.validate(
            type: .domainSuffix,
            url: URL(string: "https://example.com/settings")!,
            value: "example.com"
        ))
    }

    func testDomainSuffixMatchesSubdomain() {
        XCTAssertTrue(BrowserRule.validate(
            type: .domainSuffix,
            url: URL(string: "https://mail.example.com/inbox")!,
            value: "example.com"
        ))
    }

    func testDomainSuffixRequiresLabelBoundary() {
        XCTAssertFalse(BrowserRule.validate(
            type: .domainSuffix,
            url: URL(string: "https://notexample.com")!,
            value: "example.com"
        ))
    }

    func testDomainSuffixTreatsDotsAsLiteralCharacters() {
        XCTAssertFalse(BrowserRule.validate(
            type: .domainSuffix,
            url: URL(string: "https://exampleXcom")!,
            value: "example.com"
        ))
    }

    func testDomainSuffixNormalizesCaseWhitespaceAndTrailingDots() {
        XCTAssertTrue(BrowserRule.validate(
            type: .domainSuffix,
            url: URL(string: "https://Sub.Example.COM./")!,
            value: "  EXAMPLE.com. "
        ))
    }

    func testDomainMatchesOnlyExactHost() {
        XCTAssertTrue(BrowserRule.validate(
            type: .domain,
            url: URL(string: "https://Example.com")!,
            value: "example.com"
        ))
        XCTAssertFalse(BrowserRule.validate(
            type: .domain,
            url: URL(string: "https://sub.example.com")!,
            value: "example.com"
        ))
    }

    func testURLRegexStillMatchesFullURL() {
        XCTAssertTrue(BrowserRule.validate(
            type: .urlRegex,
            url: URL(string: "https://example.com/projects/123")!,
            value: #"example\.com/projects/\d+"#
        ))
    }
}
