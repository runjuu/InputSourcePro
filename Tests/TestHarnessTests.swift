import XCTest
@testable import Input_Source_Pro

final class TestHarnessTests: XCTestCase {
    func testCanLoadApplicationModule() {
        XCTAssertEqual(BrowserRuleType.domain.name, "DOMAIN")
    }
}
