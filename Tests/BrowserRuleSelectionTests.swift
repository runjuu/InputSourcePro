import CoreData
import XCTest
@testable import Input_Source_Pro

final class BrowserRuleSelectionTests: XCTestCase {
    private var context: NSManagedObjectContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        context = try Self.makeManagedObjectContext()
    }

    override func tearDownWithError() throws {
        context = nil
        try super.tearDownWithError()
    }

    func testFirstEnabledRuleSkipsDisabledMatchingRule() {
        let disabled = makeRule(type: .domain, value: "example.com", disabled: true)
        let enabled = makeRule(type: .domain, value: "example.com")

        let result = BrowserRule.firstEnabledRule(
            matching: URL(string: "https://example.com/account")!,
            in: [disabled, enabled]
        )

        XCTAssertTrue(result === enabled)
    }

    func testFirstEnabledRuleReturnsNilWhenOnlyMatchIsDisabled() {
        let disabled = makeRule(type: .domain, value: "example.com", disabled: true)

        let result = BrowserRule.firstEnabledRule(
            matching: URL(string: "https://example.com/account")!,
            in: [disabled]
        )

        XCTAssertNil(result)
    }

    func testFirstEnabledRulePreservesEnabledRulePriority() {
        let first = makeRule(type: .domainSuffix, value: "example.com")
        let second = makeRule(type: .domain, value: "app.example.com")

        let result = BrowserRule.firstEnabledRule(
            matching: URL(string: "https://app.example.com/account")!,
            in: [first, second]
        )

        XCTAssertTrue(result === first)
    }

    private func makeRule(
        type: BrowserRuleType,
        value: String,
        disabled: Bool = false
    ) -> BrowserRule {
        let rule = NSEntityDescription.insertNewObject(
            forEntityName: "BrowserRule",
            into: context
        ) as! BrowserRule
        rule.createdAt = Date()
        rule.type = type
        rule.value = value
        rule.disabled = disabled
        return rule
    }

    private static func makeManagedObjectContext() throws -> NSManagedObjectContext {
        let bundles = [Bundle.main, Bundle(for: BrowserRule.self)]
        let modelURL = bundles.lazy.compactMap {
            $0.url(forResource: "Main", withExtension: "momd")
        }.first

        guard let modelURL,
              let model = NSManagedObjectModel(contentsOf: modelURL)
        else {
            throw XCTSkip("Unable to load Main Core Data model")
        }

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }
}
