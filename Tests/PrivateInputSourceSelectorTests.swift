import Combine
import XCTest
@testable import Input_Source_Pro

final class PrivateInputSourceSelectorTests: XCTestCase {
    private typealias Selector = PrivateInputSourceSelector

    func testCancelledRequestNeverSends() {
        let request = makeRequest()
        request.cancel()
        assertFailure(request.perform(focusPID: { 100 }, now: { 0 }, connect: { .success($0) }) { _, _, _ in
            XCTFail("Cancelled request sent an activation")
            return .success(())
        }, .cancelled)
    }

    func testFocusChangeBeforeSendDoesNotRetargetAnotherApp() {
        assertFailure(makeRequest().perform(focusPID: { 200 }, now: { 0 }, connect: { .success($0) }) { _, _, _ in
            XCTFail("Request followed focus into another app")
            return .success(())
        }, .focusChanged)
    }

    func testFocusChangeDuringSendDoesNotRetryOrReportSuccess() {
        var pid: pid_t = 100
        var sends = 0
        let result = makeRequest().perform(focusPID: { pid }, now: { 0 }, connect: { .success($0) }) { targetPID, _, _ in
            XCTAssertEqual(targetPID, 100)
            sends += 1
            pid = 200
            return .success(())
        }
        assertFailure(result, .focusChanged)
        XCTAssertEqual(sends, 1)
    }

    func testCancellationDuringSendDiscardsSuccessfulReply() {
        let request = makeRequest()
        assertFailure(request.perform(focusPID: { 100 }, now: { 0 }, connect: { .success($0) }) { _, _, _ in
            request.cancel()
            return .success(())
        }, .cancelled)
    }

    func testQueueDelayCountsAgainstDeadline() {
        assertFailure(makeRequest().perform(focusPID: { 100 }, now: { 1 }, connect: { .success($0) }) { _, _, _ in
            XCTFail("Expired request sent an activation")
            return .success(())
        }, .timedOut)
    }

    func testSendReceivesOnlyRemainingBudget() throws {
        let result = makeRequest().perform(focusPID: { 100 }, now: { 0.2 }, connect: { .success($0) }) { pid, data, timeout in
            XCTAssertEqual(data, Data([1, 2, 3]))
            XCTAssertEqual(pid, 100)
            XCTAssertEqual(timeout, 0.1, accuracy: 0.0001)
            return .success(())
        }
        try result.get()
    }

    func testLateReplyIsNotReportedAsSuccess() {
        var now = 0.0
        assertFailure(makeRequest().perform(focusPID: { 100 }, now: { now }, connect: { .success($0) }) { _, _, _ in
            now = 0.4
            return .success(())
        }, .timedOut)
    }

    func testReplyIsRevalidatedAfterMainQueueDelay() throws {
        let request = makeRequest()
        try request.perform(focusPID: { 100 }, now: { 0.1 }, connect: { .success($0) }) { _, _, _ in
            .success(())
        }.get()

        XCTAssertEqual(request.validationFailure(focusPID: { 100 }, now: { 0.4 }), .timedOut)
        XCTAssertEqual(request.validationFailure(focusPID: { 200 }, now: { 0.2 }), .focusChanged)
        request.cancel()
        XCTAssertEqual(request.validationFailure(focusPID: { 100 }, now: { 0.2 }), .cancelled)
    }

    func testTransportFailureIsPreservedWithoutRetry() {
        var sends = 0
        assertFailure(makeRequest().perform(focusPID: { 100 }, now: { 0 }, connect: { .success($0) }) { _, _, _ in
            sends += 1
            return .failure(.transport(-2))
        }, .transport(-2))
        XCTAssertEqual(sends, 1)
    }

    func testCancellationDuringPortLookupPreventsSending() {
        let request = makeRequest()
        let result = request.perform(focusPID: { 100 }, now: { 0 }, connect: { pid in
            request.cancel()
            return .success(pid)
        }) { _, _, _ in
            XCTFail("Sent an activation after cancellation during port lookup")
            return .success(())
        }
        assertFailure(result, .cancelled)
    }

    func testFocusChangeDuringPortLookupPreventsSending() {
        var focus: pid_t = 100
        let result = makeRequest().perform(focusPID: { focus }, now: { 0 }, connect: { pid in
            focus = 200
            return .success(pid)
        }) { _, _, _ in
            XCTFail("Sent an activation after focus moved during port lookup")
            return .success(())
        }
        assertFailure(result, .focusChanged)
    }

    func testDeadlineExpiryDuringPortLookupPreventsSending() {
        var now = 0.0
        let result = makeRequest().perform(focusPID: { 100 }, now: { now }, connect: { pid in
            now = 0.4
            return .success(pid)
        }) { _, _, _ in
            XCTFail("Sent an activation after the deadline expired during port lookup")
            return .success(())
        }
        assertFailure(result, .timedOut)
    }

    func testPortLookupTimeIsDeductedFromSendBudget() throws {
        var now = 0.0
        let result = makeRequest().perform(focusPID: { 100 }, now: { now }, connect: { pid in
            XCTAssertEqual(pid, 100)
            now = 0.2
            return .success("connected port")
        }) { port, _, timeout in
            XCTAssertEqual(port, "connected port")
            XCTAssertEqual(timeout, 0.1, accuracy: 0.0001)
            return .success(())
        }
        try result.get()
    }

    func testMissingPortDoesNotSend() {
        let result = makeRequest().perform(
            focusPID: { 100 }, now: { 0 }, connect: { _ -> Result<Int, Selector.Failure> in .failure(.noPort) }
        ) { _, _, _ in
            XCTFail("Sent an activation without a port")
            return .success(())
        }
        assertFailure(result, .noPort)
    }

    func testReplyRequiresAnExplicitZeroTSMStatus() throws {
        try Selector.parseReply(reply(status: 0)).get()
        assertFailure(Selector.parseReply(try reply(status: -50)), .rejected(-50))
        assertFailure(Selector.parseReply(nil), .invalidReply)
        assertFailure(Selector.parseReply(Data("invalid".utf8)), .invalidReply)
        for invalid: Any in [false, "0", 0.5, Int64(Int32.max) + 1] {
            assertFailure(Selector.parseReply(try reply(status: invalid)), .invalidReply)
        }
        let missingStatus = try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0)
        assertFailure(Selector.parseReply(missingStatus), .invalidReply)
    }

    @MainActor
    func testBackupRoundTripsAllThreeStrategiesWithoutChangingTheDefault() throws {
        XCTAssertEqual(CJKVFixStrategy.defaultStrategy, .previousInputSourceShortcut)
        for value in ["previousInputSourceShortcut", "temporaryInputWindow", "directActivation"] {
            let data = try JSONSerialization.data(withJSONObject: ["cJKVFixStrategy": value])
            let backup = try JSONDecoder().decode(SettingsBackupPreferences.self, from: data)
            XCTAssertEqual(backup.cJKVFixStrategy?.rawValue, value)
            let encoded = try JSONEncoder().encode(backup)
            let restored = try JSONDecoder().decode(SettingsBackupPreferences.self, from: encoded)
            XCTAssertEqual(restored.cJKVFixStrategy?.rawValue, value)
        }
        let olderBackup = try JSONDecoder().decode(SettingsBackupPreferences.self, from: Data("{}".utf8))
        XCTAssertNil(olderBackup.cJKVFixStrategy)
    }

    @MainActor
    func testNewSelectionWaitsForPrivateReplyAndOnlyLatestRequestRuns() {
        var queue = InputSourceSwitcher.PrivateSelectionQueue<String>()
        let first = queue.begin(target: "CH", current: "EN")
        var selected: [String] = []
        queue.enqueue(target: "JP", current: "EN") { selected.append("JP") }
        queue.enqueue(target: "EN", current: "EN") { selected.append("EN") }
        XCTAssertTrue(selected.isEmpty)
        let next = queue.finish(first, current: "CH")
        XCTAssertFalse(queue.isBusy)
        next?()
        XCTAssertEqual(selected, ["EN"])
        XCTAssertNil(queue.finish(first, current: "EN"))
    }

    @MainActor
    func testCancelledWaitingSelectionDoesNotRunAfterReply() {
        var queue = InputSourceSwitcher.PrivateSelectionQueue<String>()
        let first = queue.begin(target: "CH", current: "EN")
        queue.enqueue(target: "JP", current: "EN") { XCTFail("Cancelled waiting selection ran") }
        queue.discardPending()
        XCTAssertTrue(queue.isBusy)
        XCTAssertNil(queue.finish(first, current: "EN", fallback: { XCTFail("Cancelled fallback ran") }))
        XCTAssertFalse(queue.isBusy)
    }

    @MainActor
    func testOldReplyCannotReleaseAnotherInFlightSelection() {
        var queue = InputSourceSwitcher.PrivateSelectionQueue<String>()
        let first = queue.begin(target: "CH", current: "EN")
        _ = queue.finish(first, current: "CH")
        let second = queue.begin(target: "JP", current: "CH")
        var selected = false
        queue.enqueue(target: "EN", current: "CH") { selected = true }
        XCTAssertNil(queue.finish(first, current: "CH"))
        XCTAssertTrue(queue.isBusy)
        queue.finish(second, current: "JP")?()
        XCTAssertTrue(selected)
    }

    private func makeRequest() -> Selector.Request {
        Selector.Request(pid: 100, data: Data([1, 2, 3]), deadline: 0.3)
    }

    private func reply(status: Any) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["tsmInputModeReplyToServerErrorKey": status], format: .xml, options: 0
        )
    }

    private func assertFailure(
        _ result: Result<Void, Selector.Failure>,
        _ expected: Selector.Failure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failure(error) = result else {
            return XCTFail("Expected \(expected), got success", file: file, line: line)
        }
        XCTAssertEqual(error, expected, file: file, line: line)
    }
}

@MainActor
final class PrivateSelectionReconciliationTests: XCTestCase {
    func testAlreadyMatchingTabReplacesOlderQueuedSelectionInSameProcess() {
        let harness = Harness(cache: ["B": "JP", "C": "EN"])
        harness.actions.send(.switchInputSourceByShortcut("CH"))
        harness.actions.send(.appChanged("B"))
        harness.actions.send(.appChanged("C"))

        harness.receivePrivateActivation()
        XCTAssertEqual(harness.state.inputSource, "EN")
        harness.finishPrivateActivation()

        XCTAssertEqual(harness.actual, "EN")
        XCTAssertEqual(harness.activated, ["CH", "EN"])
        XCTAssertEqual(harness.cache["C"], "EN")
    }

    func testSupersededActivationDoesNotOverwriteQueuedTabsRememberedSource() {
        let harness = Harness(cache: ["B": "JP", "C": "FR"])
        harness.actions.send(.switchInputSourceByShortcut("CH"))
        harness.actions.send(.appChanged("B"))
        harness.observe()
        XCTAssertEqual(harness.cache["B"], "JP")

        harness.receivePrivateActivation()
        XCTAssertEqual(harness.cache["B"], "JP")
        XCTAssertEqual(harness.state.inputSource, "JP")
        harness.actions.send(.appChanged("C"))
        harness.finishPrivateActivation()
        harness.actions.send(.appChanged("B"))

        XCTAssertEqual(harness.actual, "JP")
        XCTAssertEqual(harness.cache["B"], "JP")
        XCTAssertEqual(harness.activated, ["CH", "FR", "JP"])
    }

    func testTabWithoutRuleAlsoInvalidatesQueuedSelection() {
        let harness = Harness(cache: ["B": "JP"])
        harness.actions.send(.switchInputSourceByShortcut("CH"))
        harness.actions.send(.appChanged("B"))
        harness.actions.send(.appChanged("C"))
        harness.receivePrivateActivation()
        harness.finishPrivateActivation()

        XCTAssertEqual(harness.actual, "EN")
        XCTAssertEqual(harness.cache["C"], "EN")
        XCTAssertEqual(harness.activated, ["CH", "EN"])
    }

    func testExternalSourceReplacesQueuedSelectionAndSurvivesOldActivation() {
        let harness = Harness(cache: ["B": "JP"])
        harness.actions.send(.switchInputSourceByShortcut("CH"))
        harness.actions.send(.appChanged("B"))
        harness.actual = "FR"
        harness.observe()

        XCTAssertEqual(harness.state.inputSource, "FR")
        XCTAssertEqual(harness.cache["B"], "FR")

        harness.receivePrivateActivation()
        XCTAssertEqual(harness.state.inputSource, "FR")
        harness.finishPrivateActivation()

        XCTAssertEqual(harness.actual, "FR")
        XCTAssertEqual(harness.state.inputSource, "FR")
        XCTAssertEqual(harness.cache["B"], "FR")
        XCTAssertEqual(harness.activated, ["CH", "FR"])
    }

    func testExternalSourceSupersedesActiveSelectionWithoutQueuedRequest() {
        let harness = Harness()
        harness.actions.send(.switchInputSourceByShortcut("CH"))
        harness.actual = "FR"
        harness.observe()
        harness.receivePrivateActivation()
        harness.finishPrivateActivation()

        XCTAssertEqual(harness.actual, "FR")
        XCTAssertEqual(harness.state.inputSource, "FR")
        XCTAssertEqual(harness.cache["A"], "FR")
    }

    func testExternalSwitchBackToOriginalSourceSupersedesEarlierExternalChoice() {
        let harness = Harness(cache: ["B": "JP"])
        harness.actions.send(.switchInputSourceByShortcut("CH"))
        harness.actions.send(.appChanged("B"))
        harness.actual = "FR"
        harness.observe()
        harness.actual = "EN"
        harness.observe()
        XCTAssertEqual(harness.state.inputSource, "EN")

        harness.receivePrivateActivation()
        harness.finishPrivateActivation()

        XCTAssertEqual(harness.actual, "EN")
        XCTAssertEqual(harness.cache["B"], "EN")
        XCTAssertEqual(harness.activated, ["CH", "EN"])
    }

    func testSourcePresentBeforeNewRequestDoesNotSupersedeThatRequest() {
        let harness = Harness()
        harness.actions.send(.switchInputSourceByShortcut("CH"))
        harness.actual = "FR"
        harness.actions.send(.switchInputSourceByShortcut("JP"))
        harness.observe()
        XCTAssertEqual(harness.state.inputSource, "JP")

        harness.receivePrivateActivation()
        harness.finishPrivateActivation()

        XCTAssertEqual(harness.actual, "JP")
        XCTAssertEqual(harness.cache["A"], "JP")
        XCTAssertEqual(harness.activated, ["CH", "JP"])
    }

    func testTimedOutActivationReconcilesActualSourceAfterCompletion() {
        let harness = Harness()
        harness.actions.send(.switchInputSourceByShortcut("CH"))
        harness.observe()
        XCTAssertEqual(harness.state.inputSource, "CH")
        harness.finishPrivateActivation(allowFallback: false)

        XCTAssertEqual(harness.actual, "EN")
        XCTAssertEqual(harness.state.inputSource, "EN")
        XCTAssertEqual(harness.cache["A"], "EN")
    }

    func testCompletionBeforeNotificationPreservesNewerManualSource() {
        let harness = Harness()
        harness.actions.send(.switchInputSourceByShortcut("CH"))
        harness.actual = "FR"
        harness.finishPrivateActivation()

        XCTAssertEqual(harness.actual, "FR")
        XCTAssertEqual(harness.state.inputSource, "FR")
        XCTAssertEqual(harness.cache["A"], "FR")
        XCTAssertTrue(harness.activated.isEmpty)
    }

    func testCompletionBeforeNotificationDiscardsQueuedSelectionForNewerManualSource() {
        let harness = Harness(cache: ["B": "JP"])
        harness.actions.send(.switchInputSourceByShortcut("CH"))
        harness.actions.send(.appChanged("B"))
        harness.actual = "FR"
        harness.finishPrivateActivation()

        XCTAssertEqual(harness.actual, "FR")
        XCTAssertEqual(harness.state.inputSource, "FR")
        XCTAssertEqual(harness.cache["B"], "FR")
        XCTAssertTrue(harness.activated.isEmpty)
    }

    func testCompletionFallsBackWhenTheActualSourceHasNotChanged() {
        let harness = Harness()
        harness.actions.send(.switchInputSourceByShortcut("CH"))
        harness.finishPrivateActivation()

        XCTAssertEqual(harness.actual, "CH")
        XCTAssertEqual(harness.state.inputSource, "CH")
        XCTAssertEqual(harness.cache["A"], "CH")
        XCTAssertEqual(harness.activated, ["CH"])
    }

    func testNoRuleContextKeepsAlreadyObservedActivation() {
        let harness = Harness()
        harness.actions.send(.switchInputSourceByShortcut("CH"))
        harness.receivePrivateActivation()
        harness.actions.send(.appChanged("B"))
        XCTAssertEqual(harness.state.inputSource, "CH")
        XCTAssertEqual(harness.cache["B"], "CH")
        harness.finishPrivateActivation()

        XCTAssertEqual(harness.actual, "CH")
        XCTAssertEqual(harness.cache["B"], "CH")
    }

    func testNoRuleContextSamplesActivationBeforeItsNotification() {
        let harness = Harness()
        harness.actions.send(.switchInputSourceByShortcut("CH"))
        harness.actual = "CH"
        harness.actions.send(.appChanged("B"))
        harness.finishPrivateActivation()

        XCTAssertEqual(harness.actual, "CH")
        XCTAssertEqual(harness.cache["B"], "CH")
    }

    func testNoRuleContextKeepsExternalChoiceAfterSupersededActivation() {
        let harness = Harness()
        harness.actions.send(.switchInputSourceByShortcut("CH"))
        harness.actual = "FR"
        harness.observe()
        harness.receivePrivateActivation()
        harness.actions.send(.appChanged("B"))
        XCTAssertEqual(harness.state.inputSource, "FR")
        harness.finishPrivateActivation()

        XCTAssertEqual(harness.actual, "FR")
        XCTAssertEqual(harness.cache["B"], "FR")
    }

    @MainActor
    private final class Harness {
        typealias Action = SourceReconciliationCore.Action<String, String>
        typealias Snapshot = SourceReconciliationCore.Snapshot<String, String, String>

        let actions = SourceReconciliationCore.SerializedActionRelay<Action>(onFault: { XCTFail("Unexpected fault: \($0)") })
        var actual = "EN"
        var cache: [String: String]
        private(set) var activated: [String] = []
        @Published private(set) var state = Snapshot(appKind: "A", inputSource: "EN", inputSourceChangeReason: "noChanges")

        private var queue = InputSourceSwitcher.PrivateSelectionQueue<String>()
        private var transactionID: UUID?
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
                        readActual: { self.readActual() },
                        rule: { context in self.cache[context].map { ($0, "cached") } },
                        select: { source, _ in self.select(source) },
                        cache: { context, source in self.cache[context] = source },
                        noChanges: "noChanges", system: "system", shortcut: "shortcut",
                        prepareForContextChange: { _ in
                            let wasBusy = self.queue.isBusy
                            self.queue.discardPending(current: self.actual)
                            return wasBusy
                        }
                    )
                },
                sameContext: ==
            )
            .assign(to: &$state)
            observations = SourceReconciliationCore.observations(
                tokens: tokens.eraseToAnyPublisher(),
                readActual: { [unowned self] in readActual() },
                observed: { _ in }
            )
            .sink { [weak self] in self?.actions.send(.inputSourceChanged($0)) }
        }

        func observe() {
            tokens.send(())
        }

        func receivePrivateActivation() {
            actual = "CH"
            activated.append("CH")
            observe()
        }

        func finishPrivateActivation(allowFallback: Bool = true) {
            guard let id = transactionID else { return XCTFail("No private activation in flight") }
            transactionID = nil
            let fallback: (() -> Void)? = allowFallback && actual != "CH" ? { self.activate("CH") } : nil
            let next = queue.finish(id, current: actual, fallback: fallback)
            next?()
            observe()
        }

        private func readActual() -> String {
            if queue.isUnexpectedSource(actual) { select(actual) }
            return queue.sourceForReconciliation(actual)
        }

        private func select(_ source: String) {
            queue.discardPending(current: actual)
            if queue.isBusy {
                queue.enqueue(target: source, current: actual) { [weak self] in self?.apply(source) }
            } else {
                apply(source)
            }
        }

        private func apply(_ source: String) {
            if source == "CH" {
                transactionID = queue.begin(target: source, current: actual)
            } else {
                activate(source)
            }
        }

        private func activate(_ source: String) {
            actual = source
            activated.append(source)
        }
    }
}
