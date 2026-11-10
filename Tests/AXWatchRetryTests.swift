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
        var registration: (([AXNotification]) throws -> [AXNotification]?)?
        private var pendingTimers: [PassthroughSubject<Date, Never>] = []
        private var subscription: AnyCancellable?

        func subscribe() {
            subscription = AXWatchRetry.publisher(
                pid: 42,
                isAlive: { [weak self] in self?.isAlive == true },
                isTrusted: { [weak self] in self?.isTrusted == true },
                attach: { [weak self] send -> AnyCancellable? in
                    guard let self else { return nil }
                    attachCount += 1
                    guard !failingAttempts.contains(attachCount) else { return nil }
                    if let registration, (try? registration([.windowCreated])) == nil { return nil }
                    self.send = send
                    return AnyCancellable { [weak self] in self?.liveCancelled += 1 }
                },
                delay: { [weak self] seconds in
                    let timer = PassthroughSubject<Date, Never>()
                    self?.requestedDelays.append(seconds)
                    self?.pendingTimers.append(timer)
                    return timer.eraseToAnyPublisher()
                }
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

    func testRegisterSkipsUnsupportedNotificationsAndKeepsTheRest() throws {
        var added: [AXNotification] = []
        let registered = try AXWatchRetry.register(
            role: "AXApplication",
            validRoles: [.application],
            notifications: [.windowCreated, .titleChanged, .focusedUIElementChanged],
            add: { notification in
                if notification == .titleChanged { throw AXError.notificationUnsupported }
                if notification == .focusedUIElementChanged { throw AXError.notificationAlreadyRegistered }
                added.append(notification)
            }
        )
        XCTAssertEqual(added, [.windowCreated])
        XCTAssertEqual(registered, [.windowCreated, .focusedUIElementChanged])
    }

    func testRegisterIgnoresExcludedRolesAndRethrowsOtherErrors() throws {
        XCTAssertEqual(
            try AXWatchRetry.register(role: "AXButton", validRoles: [.window], notifications: [.windowCreated], add: { _ in XCTFail("must not register") }),
            []
        )
        XCTAssertEqual(
            try AXWatchRetry.register(role: "AXCustomThing", validRoles: [.window], notifications: [.windowCreated], add: { _ in XCTFail("must not register") }),
            []
        )
        XCTAssertThrowsError(
            try AXWatchRetry.register(role: "AXWindow", validRoles: [.window], notifications: [.windowCreated], add: { _ in throw AXError.cannotComplete })
        )
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
