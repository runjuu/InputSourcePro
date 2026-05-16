import Combine
import XCTest
@testable import Input_Source_Pro

@MainActor
final class RuntimeRuleChangeNotifierTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testChangesDoesNotEmitInitialVersion() {
        let notifier = RuntimeRuleChangeNotifier()
        var emissionCount = 0

        notifier.changes
            .sink { emissionCount += 1 }
            .store(in: &cancellables)

        XCTAssertEqual(emissionCount, 0)
    }

    func testNotifyIncrementsVersionAndEmitsChange() {
        let notifier = RuntimeRuleChangeNotifier()
        var emissionCount = 0

        notifier.changes
            .sink { emissionCount += 1 }
            .store(in: &cancellables)

        notifier.notify()
        notifier.notify()

        XCTAssertEqual(notifier.version, 2)
        XCTAssertEqual(emissionCount, 2)
    }
}
