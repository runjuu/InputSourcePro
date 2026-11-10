import AppKit
import AXSwift
import Combine

/// Retry policy for attaching AX observers.
///
/// An attach fails when the target app is not serving Accessibility yet (boot race, app still launching)
/// or when this process is not trusted yet. The first attempt is made after 0.5s, which is what
/// `watchAX` has always used (initial commit, no recorded reason beyond letting a freshly activated app
/// settle). Each failure doubles the wait, up to a cap that depends on what the failure costs:
///
/// - Not trusted: 5s. The check is one `AXIsProcessTrusted` call and no AX message, so a permission
///   granted later is picked up within five seconds for free.
/// - Target not ready: 30s. Every attempt messages the target on the main thread and blocks for the
///   messaging timeout when the target is hung, so a permanently unresponsive app must not be probed
///   every few seconds. The doubling still catches an app that finishes launching within seconds.
///
/// The doubling restarts when the kind of failure changes, so an app first probed after a long wait
/// for the permission is retried quickly again.
///
/// Contract: retries until the first successful attach; a later loss of the observer (while the pid stays
/// alive) is not detected. Retries stop when the app terminates (publisher completes) or the subscription
/// is cancelled. Subscribe, ticks and cancel all run on the main thread: ticks come from `Timer.delay` on
/// the main run loop, `Observer.stop()` uses `RunLoop.current`, and `CancelBag` is not thread-safe. The
/// `delay` publisher must emit asynchronously (as `Timer.delay` does).
enum AXWatchRetry {
    enum Attach {
        /// The observer is live; `rejected` lists notifications the app refused for good.
        case attached(AnyCancellable, rejected: [AXNotification])
        /// Try again later; `reason` goes to the diagnostics log and must not contain spaces.
        case notReady(reason: String)
    }

    static let untrustedDelayCap: TimeInterval = 5
    static let notReadyDelayCap: TimeInterval = 30

    /// The wait before the next attempt, after `failures` consecutive failures of the same kind.
    static func delay(afterFailures failures: Int, cap: TimeInterval) -> TimeInterval {
        min(0.5 * pow(2, Double(failures)), cap)
    }

    struct Registration: Equatable {
        var registered: [AXNotification] = []
        /// Notifications the element refused with an error that retrying would not clear.
        var rejected: [AXNotification] = []
    }

    /// Whether `error` means the target could not be reached, so the same call may succeed later.
    /// Everything else is the target's answer to the request and would be the same on every retry.
    static func isTransient(_ error: AXError) -> Bool {
        error == .cannotComplete || error == .apiDisabled || error == .invalidUIElement
    }

    /// Registers `notifications` one by one on an element with the given raw role.
    /// Returns `nil` when the element is not ready yet (no role: AXSwift documents this for elements still
    /// initializing) and an empty registration for a role outside `validRoles`.
    /// A notification the element does not support is skipped, and one it refuses with any other
    /// permanent error is reported as rejected; the remaining notifications are still registered.
    /// A transient error is rethrown so the whole attach is retried.
    static func register(
        role: String?,
        validRoles: [Role],
        notifications: [AXNotification],
        add: (AXNotification) throws -> Void
    ) throws -> Registration? {
        guard let role else { return nil }
        var registration = Registration()
        guard let role = Role(rawValue: role), validRoles.contains(role) else { return registration }
        for notification in notifications {
            do {
                try add(notification)
                registration.registered.append(notification)
            } catch AXError.notificationUnsupported {
                continue
            } catch let error as AXError where !isTransient(error) {
                registration.rejected.append(notification)
            }
        }
        return registration
    }

    static func publisher<Output>(
        pid: pid_t,
        isAlive: @escaping () -> Bool,
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        attach: @escaping (_ send: @escaping (Output) -> Void) -> Attach,
        delay: @escaping (TimeInterval) -> AnyPublisher<Date, Never> = { Timer.delay(seconds: $0) },
        log: @escaping (String) -> Void = { IndicatorDiagnostics.record($0) }
    ) -> AnyPublisher<Output, Never> {
        AnyPublisher.create { subscriber in
            let cancelBag = CancelBag()
            var timer: AnyCancellable?
            var latestAttempt = 0
            var isCancelled = false
            var lastFailure: String?
            var failureStreak = 0
            var waitedSinceLog: TimeInterval = 0

            func attempt(_ n: Int, after wait: TimeInterval) {
                latestAttempt = n
                let pending = delay(wait).sink { _ in
                    guard !isCancelled else { return }
                    let result: String
                    var detail = ""
                    var retryCap: TimeInterval?
                    if !isAlive() {
                        result = "terminated"
                        subscriber.send(completion: .finished)
                    } else if !isTrusted() {
                        result = "untrusted"
                        retryCap = untrustedDelayCap
                    } else {
                        switch attach(subscriber.send) {
                        case let .attached(observer, rejected):
                            result = "attached"
                            observer.store(in: cancelBag)
                            if !rejected.isEmpty {
                                detail = " rejected=" + rejected.map(\.rawValue).joined(separator: ",")
                            }
                        case let .notReady(reason):
                            result = "not-ready"
                            detail = " reason=\(reason)"
                            retryCap = notReadyDelayCap
                        }
                    }
                    // Stay silent on a clean first-attempt attach. Log anything else on the first attempt,
                    // the end of every retry sequence, and about once a minute while still failing.
                    waitedSinceLog += wait
                    let isNoteworthy = n == 1 ? result != "attached" || !detail.isEmpty : retryCap == nil
                    if isNoteworthy || waitedSinceLog >= 60 {
                        waitedSinceLog = 0
                        log("ax.watch pid=\(pid) attempt=\(n) result=\(result)\(detail)")
                    }
                    if let retryCap {
                        failureStreak = result == lastFailure ? failureStreak + 1 : 1
                        lastFailure = result
                        attempt(n + 1, after: Self.delay(afterFailures: failureStreak, cap: retryCap))
                    }
                }
                // A synchronous emission would already have scheduled the next attempt; keep that timer.
                if latestAttempt == n { timer = pending }
            }
            attempt(1, after: Self.delay(afterFailures: 0, cap: notReadyDelayCap))

            return AnyCancellable {
                isCancelled = true
                timer = nil
                cancelBag.cancel()
            }
        }
    }
}
