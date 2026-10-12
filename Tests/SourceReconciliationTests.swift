import AppKit
import Combine
import XCTest
@testable import Input_Source_Pro

@MainActor
final class SourceReconciliationTests: XCTestCase {
    private enum Reason: Equatable {
        case noChanges, system, shortcut, specified
    }

    private typealias Action = SourceReconciliationCore.Action<AppKind, String>
    private typealias Snapshot = SourceReconciliationCore.Snapshot<AppKind, String, Reason>

    func testNavigationReconcilesExternalSourceBeforeNotification() {
        let before = browserContext(path: "before")
        let after = browserContext(path: "after")
        XCTAssertEqual(before.getId(), after.getId())
        XCTAssertFalse(before.isSameAppOrWebsite(with: after, detectAddressBar: true))
        let harness = Harness(context: before)

        harness.actual = "RU"
        harness.actions.send(.appChanged(after))
        harness.actions.send(.inputSourceChanged("RU"))
        harness.actions.send(.inputSourceChanged("RU"))

        XCTAssertEqual(harness.published.map(\.inputSource), ["EN", "RU"])
        XCTAssertEqual(harness.published.map(\.inputSourceChangeReason), [.noChanges, .system])
        XCTAssertEqual(harness.state.appKind?.getBrowserInfo()?.url, after.getBrowserInfo()?.url)
        XCTAssertEqual(harness.cached, ["RU"])
        XCTAssertTrue(harness.selected.isEmpty)
    }

    func testNavigationWithUnchangedSourceDoesNotReportSystemChange() {
        let harness = Harness(context: browserContext(path: "before"))

        harness.actions.send(.appChanged(browserContext(path: "after")))
        harness.actions.send(.inputSourceChanged("EN"))

        XCTAssertEqual(harness.published.map(\.inputSource), ["EN", "EN"])
        XCTAssertEqual(harness.published.map(\.inputSourceChangeReason), [.noChanges, .noChanges])
        XCTAssertTrue(harness.selected.isEmpty)
    }

    func testObservationBeforeNavigationReportsSystemChangeOnlyOnce() {
        let harness = Harness(context: browserContext(path: "before"))

        harness.actual = "RU"
        harness.actions.send(.inputSourceChanged("RU"))
        harness.actions.send(.appChanged(browserContext(path: "after")))
        harness.actions.send(.inputSourceChanged("RU"))

        XCTAssertEqual(harness.published.map(\.inputSource), ["EN", "RU", "RU"])
        XCTAssertEqual(harness.published.map(\.inputSourceChangeReason), [.noChanges, .system, .noChanges])
        XCTAssertTrue(harness.selected.isEmpty)
    }

    func testMatchingLiveRuleSkipsSelectionEvenWhenStoredSourceDiffers() {
        let harness = Harness(context: browserContext(path: "before"))
        harness.actual = "RU"
        harness.rule = ("RU", .specified)

        harness.actions.send(.appChanged(browserContext(path: "after")))

        XCTAssertEqual(harness.published.map(\.inputSource), ["EN", "RU"])
        XCTAssertEqual(harness.state.inputSourceChangeReason, .noChanges)
        XCTAssertEqual(harness.cached, ["RU"])
        XCTAssertTrue(harness.selected.isEmpty)
    }

    func testPublishedFeedbackWaitsUntilCurrentAssignmentFinishes() {
        let harness = Harness(context: browserContext(path: "before"))
        var callbacks: [String] = []
        let subscription = harness.$state.dropFirst().sink { snapshot in
            callbacks.append("begin \(snapshot.inputSource)")
            if snapshot.inputSource == "RU" {
                harness.actions.send(.inputSourceChanged("UA"))
            }
            callbacks.append("end \(snapshot.inputSource)")
        }
        defer { subscription.cancel() }

        harness.actions.send(.switchInputSourceByShortcut("RU"))

        XCTAssertEqual(callbacks, ["begin RU", "end RU", "begin UA", "end UA"])
        XCTAssertEqual(harness.published.map(\.inputSource), ["EN", "RU", "UA"])
        XCTAssertEqual(harness.state.inputSource, "UA")
        XCTAssertEqual(harness.state.inputSourceChangeReason, .system)
        XCTAssertEqual(harness.selected, ["RU"])
        XCTAssertEqual(harness.cached, ["RU", "UA"])
    }

    private func browserContext(path: String) -> AppKind {
        .browser(
            app: NSRunningApplication.current,
            info: (
                focusedElement: nil,
                isFocusOnInputContainer: true,
                url: URL(string: "https://example.com/\(path)"),
                rule: nil,
                isFocusedOnAddressBar: false
            )
        )
    }

    @MainActor
    private final class Harness {
        let actions = SourceReconciliationCore.SerializedActionRelay<Action>(
            onFault: { XCTFail("Unexpected action relay fault: \($0)") }
        )
        var actual = "EN"
        var rule: (inputSource: String, reason: Reason)?
        var selected: [String] = []
        var cached: [String] = []
        var published: [Snapshot] = []
        @Published private(set) var state: Snapshot

        init(context: AppKind) {
            state = Snapshot(appKind: context, inputSource: "EN", inputSourceChangeReason: .noChanges)
            SourceReconciliationCore.states(
                actions: actions.publisher,
                initial: state,
                dependencies: { [weak self] in
                    guard let self else { return nil }
                    return SourceReconciliationCore.Dependencies(
                        readActual: { self.actual },
                        rule: { _ in self.rule },
                        select: { source, _ in self.selected.append(source) },
                        cache: { _, source in self.cached.append(source) },
                        noChanges: .noChanges,
                        system: .system,
                        shortcut: .shortcut
                    )
                },
                sameContext: { $0.isSameAppOrWebsite(with: $1, detectAddressBar: true) }
            )
            .handleEvents(receiveOutput: { [weak self] in self?.published.append($0) })
            .assign(to: &$state)
            actions.send(.start)
        }
    }
}
