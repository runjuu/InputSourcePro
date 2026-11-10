import AXSwift
import Combine
import XCTest
@testable import Input_Source_Pro

@MainActor
final class AXWatchRetryTests: XCTestCase {
    /// Drives `AXWatchRetry.publisher` with hand-fired timers instead of real delays.
    private final class Harness {
        var requestedDelays: [TimeInterval] = []
        var attachCount = 0
        var liveCancelled = 0
        var received: [Int] = []
        var completed = false
        var isAlive = true
        var isTrusted = true
        /// Attempts (1-based) that fail; every other attempt attaches.
        var failingAttempts: Set<Int> = []
        var send: ((Int) -> Void)?
        /// When set, attach succeeds only if this returns a non-nil registration.
        var registration: (([AXNotification]) throws -> AXWatchRetry.Registration?)?
        var logged: [String] = []
        /// What the readiness probe answers; `nil` means the target is ready.
        var probeReason: String?
        /// When set, probe answers are held until `answerProbe()`.
        var holdsProbes = false
        private var pendingProbes: [(String?) -> Void] = []
        private var pendingTimers: [PassthroughSubject<Date, Never>] = []
        private var subscription: AnyCancellable?

        func subscribe() {
            subscription = AXWatchRetry.publisher(
                pid: 42,
                isAlive: { [weak self] in self?.isAlive == true },
                isTrusted: { [weak self] in self?.isTrusted == true },
                probe: { [weak self] pid, done in
                    XCTAssertEqual(pid, 42)
                    guard let self else { return }
                    if holdsProbes { pendingProbes.append(done) } else { done(probeReason) }
                },
                attach: { [weak self] send -> AXWatchRetry.Attach in
                    guard let self else { return .notReady(reason: "gone") }
                    attachCount += 1
                    guard !failingAttempts.contains(attachCount) else { return .notReady(reason: "failing") }
                    var rejected: [AXNotification] = []
                    if let registration {
                        guard let result = try? registration([.windowCreated]) else { return .notReady(reason: "no-role") }
                        rejected = result.rejected
                    }
                    self.send = send
                    return .attached(AnyCancellable { [weak self] in self?.liveCancelled += 1 }, rejected: rejected)
                },
                delay: { [weak self] seconds in
                    let timer = PassthroughSubject<Date, Never>()
                    self?.requestedDelays.append(seconds)
                    self?.pendingTimers.append(timer)
                    return timer.eraseToAnyPublisher()
                },
                log: { [weak self] in self?.logged.append($0) }
            )
            .sink(
                receiveCompletion: { [weak self] _ in self?.completed = true },
                receiveValue: { [weak self] in self?.received.append($0) }
            )
        }

        func fireTimer() {
            XCTAssertFalse(pendingTimers.isEmpty, "No retry pending")
            pendingTimers.removeFirst().send(Date())
        }

        var pendingTimerCount: Int { pendingTimers.count }

        var pendingProbeCount: Int { pendingProbes.count }

        func answerProbe() {
            XCTAssertFalse(pendingProbes.isEmpty, "No probe pending")
            pendingProbes.removeFirst()(probeReason)
        }

        func cancel() { subscription = nil }
    }

    func testBackoffSchedule() {
        XCTAssertEqual(
            (0...6).map { AXWatchRetry.delay(afterFailures: $0, cap: AXWatchRetry.untrustedDelayCap) },
            [0.5, 1, 2, 4, 5, 5, 5]
        )
        XCTAssertEqual(
            (0...7).map { AXWatchRetry.delay(afterFailures: $0, cap: AXWatchRetry.notReadyDelayCap) },
            [0.5, 1, 2, 4, 8, 16, 30, 30]
        )
    }

    func testRetriesUntilAttachSucceedsThenDeliversEvents() {
        let harness = Harness()
        harness.failingAttempts = [1, 2]
        harness.subscribe()
        XCTAssertEqual(harness.attachCount, 0, "First attempt waits for its delay")

        harness.fireTimer()
        harness.fireTimer()
        XCTAssertEqual(harness.attachCount, 2)
        XCTAssertNil(harness.send)

        harness.fireTimer()
        XCTAssertEqual(harness.attachCount, 3)
        XCTAssertEqual(harness.requestedDelays, [0.5, 1, 2])
        XCTAssertEqual(harness.pendingTimerCount, 0, "No retry after success")

        harness.send?(7)
        XCTAssertEqual(harness.received, [7])
        XCTAssertFalse(harness.completed)
    }

    func testKeepsRetryingAtCapWhileAttachFails() {
        let harness = Harness()
        harness.failingAttempts = Set(1...8)
        harness.subscribe()
        for _ in 1...8 { harness.fireTimer() }

        XCTAssertEqual(harness.attachCount, 8)
        XCTAssertEqual(harness.requestedDelays, [0.5, 1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertEqual(harness.pendingTimerCount, 1)
    }

    func testKeepsCheckingTrustEveryFiveSeconds() {
        let harness = Harness()
        harness.isTrusted = false
        harness.subscribe()
        for _ in 1...6 { harness.fireTimer() }

        XCTAssertEqual(harness.attachCount, 0)
        XCTAssertEqual(harness.requestedDelays, [0.5, 1, 2, 4, 5, 5, 5])
    }

    func testBackoffRestartsWhenTheKindOfFailureChanges() {
        let harness = Harness()
        harness.isTrusted = false
        harness.failingAttempts = [1, 2]
        harness.subscribe()
        for _ in 1...6 { harness.fireTimer() }
        XCTAssertEqual(harness.requestedDelays.last, 5)

        // Trusted at last, but the target is not ready: probe it quickly again instead of at the cap.
        harness.isTrusted = true
        harness.fireTimer()
        harness.fireTimer()
        XCTAssertEqual(harness.attachCount, 2)
        XCTAssertEqual(Array(harness.requestedDelays.suffix(2)), [1, 2])
    }

    func testCancelMidRetryStopsFurtherAttempts() {
        let harness = Harness()
        harness.failingAttempts = [1]
        harness.subscribe()
        harness.fireTimer()
        XCTAssertEqual(harness.pendingTimerCount, 1)

        harness.cancel()
        harness.fireTimer()
        XCTAssertEqual(harness.attachCount, 1)
        XCTAssertEqual(harness.pendingTimerCount, 0)
    }

    func testCancelAfterAttachReleasesObserver() {
        let harness = Harness()
        harness.subscribe()
        harness.fireTimer()
        XCTAssertEqual(harness.liveCancelled, 0)

        harness.cancel()
        XCTAssertEqual(harness.liveCancelled, 1)
    }

    func testWaitsForAccessibilityTrustBeforeAttaching() {
        let harness = Harness()
        harness.isTrusted = false
        harness.subscribe()
        harness.fireTimer()
        harness.fireTimer()
        XCTAssertEqual(harness.attachCount, 0, "No AX calls while untrusted")
        XCTAssertEqual(harness.requestedDelays, [0.5, 1, 2])

        harness.isTrusted = true
        harness.fireTimer()
        XCTAssertEqual(harness.attachCount, 1)
        XCTAssertEqual(harness.pendingTimerCount, 0)
    }

    func testTargetThatFailsTheProbeIsRetriedWithoutAttaching() {
        let harness = Harness()
        harness.probeReason = "AXError.CannotComplete"
        harness.subscribe()
        for _ in 1...3 { harness.fireTimer() }
        XCTAssertEqual(harness.attachCount, 0, "A target that does not answer must not reach the main-thread attach")
        XCTAssertEqual(harness.requestedDelays, [0.5, 1, 2, 4])
        XCTAssertEqual(harness.logged, ["ax.watch pid=42 attempt=1 result=not-ready reason=AXError.CannotComplete"])

        harness.probeReason = nil
        harness.fireTimer()
        XCTAssertEqual(harness.attachCount, 1)
        XCTAssertEqual(harness.pendingTimerCount, 0)
        XCTAssertEqual(harness.logged.last, "ax.watch pid=42 attempt=4 result=attached")
    }

    func testCancelWhileProbingNeitherAttachesNorRetries() {
        let harness = Harness()
        harness.holdsProbes = true
        harness.subscribe()
        harness.fireTimer()
        harness.cancel()

        harness.answerProbe()
        XCTAssertEqual(harness.attachCount, 0)
        XCTAssertEqual(harness.pendingTimerCount, 0)
        XCTAssertEqual(harness.logged, [])
    }

    func testProbeDoesNotRunWhileUntrustedOrAfterTermination() {
        let harness = Harness()
        harness.holdsProbes = true
        harness.isTrusted = false
        harness.subscribe()
        harness.fireTimer()
        harness.isAlive = false
        harness.fireTimer()
        XCTAssertTrue(harness.completed)
        XCTAssertEqual(harness.pendingProbeCount, 0, "Neither outcome may message the target")
        XCTAssertEqual(harness.attachCount, 0)
        XCTAssertEqual(harness.logged, [
            "ax.watch pid=42 attempt=1 result=untrusted",
            "ax.watch pid=42 attempt=2 result=terminated",
        ])
    }

    func testProbeAnswersOnTheMainThreadWithAReasonForAPidThatIsNotRunning() {
        let answered = expectation(description: "Probe answered")
        AXWatchRetry.probe(pid: pid_t.max) { reason in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNotNil(reason)
            XCTAssertEqual(reason?.contains(" "), false)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
    }

    func testMissingRoleIsRetriedUntilTheAppReportsOne() {
        var roles: [String?] = [nil, nil, "AXApplication"]
        let harness = Harness()
        harness.registration = { notifications in
            try AXWatchRetry.register(
                role: roles.removeFirst(),
                validRoles: [.application],
                notifications: notifications,
                add: { _ in }
            )
        }
        harness.subscribe()
        harness.fireTimer()
        harness.fireTimer()
        XCTAssertNil(harness.send, "No role yet: attach must report not-ready")

        harness.fireTimer()
        XCTAssertEqual(harness.attachCount, 3)
        XCTAssertNotNil(harness.send)
        XCTAssertEqual(harness.pendingTimerCount, 0)
    }

    func testRegisterSkipsRefusedNotificationsAndKeepsTheRest() throws {
        let registration = try AXWatchRetry.register(
            role: "AXApplication",
            validRoles: [.application],
            notifications: [.windowCreated, .titleChanged, .focusedUIElementChanged, .selectedTextChanged],
            add: { notification in
                if notification == .titleChanged { throw AXError.notificationUnsupported }
                if notification == .focusedUIElementChanged { throw AXError.failure }
            }
        )
        XCTAssertEqual(registration?.registered, [.windowCreated, .selectedTextChanged])
        XCTAssertEqual(registration?.rejected, [.focusedUIElementChanged])
    }

    func testRegisterIgnoresExcludedRoles() throws {
        for role in ["AXButton", "AXCustomThing"] {
            XCTAssertEqual(
                try AXWatchRetry.register(role: role, validRoles: [.window], notifications: [.windowCreated], add: { _ in XCTFail("must not register") }),
                AXWatchRetry.Registration()
            )
        }
    }

    func testRegisterRethrowsErrorsThatARetryCanClear() {
        struct Unrelated: Error {}
        let errors: [Error] = [AXError.cannotComplete, AXError.apiDisabled, AXError.invalidUIElement, Unrelated()]
        for error in errors {
            XCTAssertThrowsError(
                try AXWatchRetry.register(role: "AXWindow", validRoles: [.window], notifications: [.windowCreated], add: { _ in throw error }),
                "\(error)"
            )
        }
    }

    func testLogsNothingWhenTheFirstAttemptAttachesCleanly() {
        let harness = Harness()
        harness.subscribe()
        harness.fireTimer()
        XCTAssertNotNil(harness.send)
        XCTAssertEqual(harness.logged, [])
    }

    func testLogsTheFailureReasonAndTheLateAttach() {
        let harness = Harness()
        harness.failingAttempts = [1, 2]
        harness.subscribe()
        for _ in 1...3 { harness.fireTimer() }
        XCTAssertEqual(harness.logged, [
            "ax.watch pid=42 attempt=1 result=not-ready reason=failing",
            "ax.watch pid=42 attempt=3 result=attached",
        ])
    }

    func testLogsRejectedNotificationsEvenOnAFirstAttemptAttach() {
        let harness = Harness()
        harness.registration = { _ in AXWatchRetry.Registration(registered: [], rejected: [.titleChanged, .windowCreated]) }
        harness.subscribe()
        harness.fireTimer()
        XCTAssertNotNil(harness.send)
        XCTAssertEqual(harness.logged, ["ax.watch pid=42 attempt=1 result=attached rejected=AXTitleChanged,AXWindowCreated"])
    }

    func testLogsTerminationThatEndsARetrySequence() {
        let harness = Harness()
        harness.failingAttempts = [1]
        harness.subscribe()
        harness.fireTimer()
        harness.isAlive = false
        harness.fireTimer()
        XCTAssertTrue(harness.completed)
        XCTAssertEqual(harness.logged.last, "ax.watch pid=42 attempt=2 result=terminated")
    }

    func testLogsAboutOnceAMinuteWhileStillFailing() {
        let harness = Harness()
        harness.failingAttempts = Set(1...12)
        harness.subscribe()
        // Attempt 1 is logged as a first-attempt failure. The waits that follow are 1, 2, 4, 8, 16, 30
        // (61s, logged at attempt 7), then 30 and 30 (60s, logged at attempt 9).
        for _ in 1...10 { harness.fireTimer() }
        XCTAssertEqual(harness.logged.map { $0.components(separatedBy: " ")[2] }, ["attempt=1", "attempt=7", "attempt=9"])
    }

    func testTerminatedAppCompletesWithoutRetry() {
        let harness = Harness()
        harness.isAlive = false
        harness.subscribe()
        harness.fireTimer()

        XCTAssertTrue(harness.completed)
        XCTAssertEqual(harness.attachCount, 0)
        XCTAssertEqual(harness.pendingTimerCount, 0)
    }
}
