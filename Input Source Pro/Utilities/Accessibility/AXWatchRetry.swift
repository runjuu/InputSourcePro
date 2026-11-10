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
/// - Target not ready: 30s. The doubling catches an app that finishes launching within seconds; an app
///   that still does not answer after that is hung or has no Accessibility support, and there is no
///   point asking it every few seconds.
///
/// Before each attach the target is probed off the main thread (`probe`), because a hung target blocks
/// the caller for the whole messaging timeout. The observer is only created, on the main thread, once
/// the probe has seen the target answer, so a target that never becomes ready costs the main thread
/// nothing however long it is watched.
///
/// The doubling restarts when the kind of failure changes, so an app first probed after a long wait
/// for the permission is retried quickly again.
///
/// Contract: retries until the first successful attach; a later loss of the observer (while the pid stays
/// alive) is not detected. Retries stop when the app terminates (publisher completes) or the subscription
/// is cancelled. Subscribe, ticks, probe results and cancel all run on the main thread: ticks come from
/// `Timer.delay` on the main run loop, `probe` reports back on the main queue, `Observer.stop()` uses
/// `RunLoop.current`, and `CancelBag` is not thread-safe.
enum AXWatchRetry {
    enum Attach {
        /// The observer is live; `registration` says what the application element accepted.
        case attached(AnyCancellable, registration: Registration)
        /// Try again later; `reason` goes to the diagnostics log.
        case notReady(reason: String)
    }

    /// Matches CaretFocusObserver; far above a live app's reply time and half the global AX timeout.
    static let messagingTimeout: Float = 0.25
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
    /// A transient error, or one that is not an `AXError`, is rethrown: the attach treats it as not ready
    /// and retries, while a window that fails this way after the attach is simply not watched.
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

    /// Why the app with `pid` cannot be watched yet, or `nil` when its application element answers
    /// with a role. Blocks for up to the messaging timeout when the target is hung.
    static func notReadyReason(pid: pid_t) -> String? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        var role: AnyObject?
        let error = AXUIElementCopyAttributeValue(application, kAXRoleAttribute as CFString, &role)
        switch error {
        case .success: return nil
        case .noValue, .attributeUnsupported: return "no-role"
        default: return "\(error)"
        }
    }

    /// Runs `notReadyReason` on a background queue and reports the answer on the main queue.
    static func probe(pid: pid_t, done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let reason = notReadyReason(pid: pid)
            DispatchQueue.main.async { done(reason) }
        }
    }

    static func publisher<Output>(
        pid: pid_t,
        isAlive: @escaping () -> Bool,
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        probe: @escaping (pid_t, @escaping (String?) -> Void) -> Void = AXWatchRetry.probe,
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
            var lastLoggedFailure: String?
            var isFinished = false

            func attempt(_ n: Int, after wait: TimeInterval) {
                latestAttempt = n
                let pending = delay(wait).sink { _ in
                    guard !isCancelled else { return }
                    if !isAlive() {
                        finish(n, wait, result: "terminated")
                        subscriber.send(completion: .finished)
                    } else if !isTrusted() {
                        finish(n, wait, result: "untrusted", retryCap: untrustedDelayCap)
                    } else {
                        probe(pid) { notReadyReason in
                            guard !isCancelled else { return }
                            if let notReadyReason {
                                finish(n, wait, result: "not-ready", detail: " reason=\(notReadyReason)", retryCap: notReadyDelayCap)
                                return
                            }
                            switch attach(subscriber.send) {
                            case let .attached(observer, registration):
                                observer.store(in: cancelBag)
                                var detail = registration.registered.isEmpty ? " registered=0" : ""
                                if !registration.rejected.isEmpty {
                                    detail += " rejected=" + registration.rejected.map(\.rawValue).joined(separator: ",")
                                }
                                finish(n, wait, result: "attached", detail: detail)
                            case let .notReady(reason):
                                finish(n, wait, result: "not-ready", detail: " reason=\(reason)", retryCap: notReadyDelayCap)
                            }
                        }
                    }
                }
                // A synchronous emission would already have scheduled the next attempt; keep that timer.
                if latestAttempt == n { timer = pending }
            }

            /// Logs the outcome of attempt `n` and schedules the next one when `retryCap` is set.
            func finish(_ n: Int, _ wait: TimeInterval, result: String, detail: String = "", retryCap: TimeInterval? = nil) {
                // The log is split on spaces by whoever reads it.
                let detail = detail.dropFirst().replacingOccurrences(of: " ", with: "_")
                let outcome = detail.isEmpty ? result : "\(result) \(detail)"
                // Stay silent on a clean first-attempt attach, the common case. While failing, log each
                // new kind of failure and then about once a minute. Always log how the sequence ended.
                waitedSinceLog += wait
                let isNoteworthy: Bool
                if retryCap == nil {
                    isFinished = true
                    isNoteworthy = result != "attached" || n > 1 || !detail.isEmpty
                } else {
                    isNoteworthy = outcome != lastLoggedFailure || waitedSinceLog >= 60
                    if isNoteworthy { lastLoggedFailure = outcome }
                }
                if isNoteworthy {
                    waitedSinceLog = 0
                    log("ax.watch pid=\(pid) attempt=\(n) result=\(outcome)")
                }
                if let retryCap {
                    failureStreak = result == lastFailure ? failureStreak + 1 : 1
                    lastFailure = result
                    attempt(n + 1, after: Self.delay(afterFailures: failureStreak, cap: retryCap))
                }
            }
            attempt(1, after: Self.delay(afterFailures: 0, cap: notReadyDelayCap))

            return AnyCancellable {
                // Close a logged run of failures; a watcher of the frontmost app usually ends this way.
                if !isCancelled, !isFinished, lastLoggedFailure != nil {
                    log("ax.watch pid=\(pid) attempt=\(latestAttempt) result=cancelled")
                }
                isCancelled = true
                timer = nil
                cancelBag.cancel()
            }
        }
    }
}
