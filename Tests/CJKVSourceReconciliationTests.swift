import Combine
import XCTest
@testable import Input_Source_Pro

@MainActor
final class CJKVSourceReconciliationTests: XCTestCase {
    func testTemporarySourceDoesNotReplaceAppCacheBeforeAnotherSwitchCancelsIt() {
        let harness = Harness(cache: ["A": "EN", "B": "FR"])
        harness.observe()
        harness.actions.send(.switchInputSourceByShortcut("CH"))

        harness.observe()
        XCTAssertEqual(harness.state.inputSource, "CH")
        XCTAssertEqual(harness.cache["A"], "CH")

        harness.actions.send(.appChanged("B"))
        harness.observe()
        harness.actions.send(.appChanged("A"))

        XCTAssertEqual(harness.selected, ["CH", "FR", "CH"])
        XCTAssertEqual(harness.cache["A"], "CH")
        XCTAssertEqual(harness.state.inputSource, "CH")
    }

    func testAppChangeReadsPendingTargetInsteadOfTemporarySource() {
        let harness = Harness()
        harness.actions.send(.switchInputSourceByShortcut("CH"))

        harness.actions.send(.appChanged("B"))
        harness.observe()

        XCTAssertEqual(harness.actual, "EN")
        XCTAssertEqual(harness.state.inputSource, "CH")
        XCTAssertEqual(harness.cache["B"], "CH")
        XCTAssertEqual(harness.selected, ["CH"])
    }

    func testFailedReturnReconcilesAfterWorkaroundFinishes() {
        let harness = Harness()
        harness.actions.send(.switchInputSourceByShortcut("CH"))
        harness.observe()

        harness.finishPendingSelection(actual: "EN")
        harness.observe()

        XCTAssertEqual(harness.state.inputSource, "EN")
        XCTAssertEqual(harness.state.inputSourceChangeReason, "system")
        XCTAssertEqual(harness.cache["A"], "EN")
    }

    func testCancellationReconcilesActualSourceWithoutWaitingForCompletion() {
        let harness = Harness()
        harness.actions.send(.switchInputSourceByShortcut("CH"))
        harness.observe()

        harness.cancelPendingSelection()
        harness.observe()

        XCTAssertEqual(harness.state.inputSource, "EN")
        XCTAssertEqual(harness.cache["A"], "EN")
    }

    func testDifferentExternalSourceIsObservedDuringWorkaround() {
        let harness = Harness()
        harness.actions.send(.switchInputSourceByShortcut("CH"))

        harness.actual = "FR"
        harness.observe()

        XCTAssertEqual(harness.state.inputSource, "FR")
        XCTAssertEqual(harness.state.inputSourceChangeReason, "system")
        XCTAssertEqual(harness.cache["A"], "FR")
    }

    func testFailedOrdinarySelectionStillReconcilesRepeatedActualSource() {
        let harness = Harness()
        harness.observe()
        harness.failedSource = "FR"

        harness.actions.send(.switchInputSourceByShortcut("FR"))
        harness.observe()

        XCTAssertEqual(harness.state.inputSource, "EN")
        XCTAssertEqual(harness.state.inputSourceChangeReason, "system")
        XCTAssertEqual(harness.cache["A"], "EN")
    }

    func testOldCompletionDoesNotClearNewTemporarySelection() {
        var selection = InputSourceSwitcher.TemporarySelection<String>()
        let oldID = selection.begin(target: "CH", temporary: "EN")
        selection.cancel()
        let newID = selection.begin(target: "JP", temporary: "EN")

        selection.finish(oldID)
        XCTAssertEqual(selection.sourceForReconciliation("EN"), "JP")

        selection.finish(newID)
        XCTAssertEqual(selection.sourceForReconciliation("EN"), "EN")
    }

    @MainActor
    private final class Harness {
        typealias Action = SourceReconciliationCore.Action<String, String>
        typealias Snapshot = SourceReconciliationCore.Snapshot<String, String, String>

        let actions = SourceReconciliationCore.SerializedActionRelay<Action>(
            onFault: { XCTFail("Unexpected action relay fault: \($0)") }
        )
        var actual = "EN"
        var failedSource: String?
        var cache: [String: String]
        private(set) var selected: [String] = []
        @Published private(set) var state = Snapshot(
            appKind: "A", inputSource: "EN", inputSourceChangeReason: "noChanges"
        )

        private var temporarySelection = InputSourceSwitcher.TemporarySelection<String>()
        private var pendingSelectionID: UUID?
        private let tokens = PassthroughSubject<Void, Never>()
        private var observations: AnyCancellable?

        init(cache: [String: String] = [:]) {
            self.cache = cache
            SourceReconciliationCore.states(
                actions: actions.publisher,
                initial: state,
                dependencies: { [weak self] in
                    guard let self else { return nil }
                    return SourceReconciliationCore.Dependencies(
                        readActual: { self.sourceForReconciliation() },
                        rule: { context in self.cache[context].map { ($0, "cached") } },
                        select: { source, _ in self.select(source) },
                        cache: { context, source in self.cache[context] = source },
                        noChanges: "noChanges",
                        system: "system",
                        shortcut: "shortcut"
                    )
                },
                sameContext: ==
            )
            .assign(to: &$state)
            observations = SourceReconciliationCore.observations(
                tokens: tokens.eraseToAnyPublisher(),
                readActual: { [unowned self] in self.sourceForReconciliation() },
                observed: { _ in }
            )
            .sink { [weak self] in self?.actions.send(.inputSourceChanged($0)) }
            actions.send(.start)
        }

        func observe() {
            tokens.send(())
        }

        func finishPendingSelection(actual: String) {
            guard let id = pendingSelectionID else {
                XCTFail("Expected a pending temporary selection")
                return
            }
            self.actual = actual
            temporarySelection.finish(id)
            pendingSelectionID = nil
        }

        func cancelPendingSelection() {
            temporarySelection.cancel()
            pendingSelectionID = nil
        }

        private func sourceForReconciliation() -> String {
            temporarySelection.sourceForReconciliation(actual)
        }

        private func select(_ source: String) {
            selected.append(source)
            cancelPendingSelection()
            if source == "CH" {
                pendingSelectionID = temporarySelection.begin(target: source, temporary: "EN")
                actual = "EN"
            } else if source != failedSource {
                actual = source
            }
        }
    }
}
