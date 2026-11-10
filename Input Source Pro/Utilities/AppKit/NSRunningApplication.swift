import AppKit
import AXSwift
import Combine

/// Registers `notifications` on `element` when its role is one of `validRoles`.
/// Returns the cancellable that unregisters them, an empty cancellable for roles we ignore,
/// and `nil` when the element could not be watched yet (no role, role unreadable or registration failed).
private func notify(
    _ observer: Observer,
    _ validRoles: [Role],
    _ element: UIElement,
    _ notifications: [AXNotification]
) -> AnyCancellable? {
    guard let registration = try? AXWatchRetry.register(
        role: try element.attribute(.role),
        validRoles: validRoles,
        notifications: notifications,
        add: { try observer.addNotification($0, forElement: element) }
    ) else { return nil }
    return AnyCancellable {
        for notification in registration.registered {
            try? observer.removeNotification(notification, forElement: element)
        }
    }
}

extension NSRunningApplication {
    typealias WatchAXOutput = (runningApp: NSRunningApplication, notification: AXNotification)

    func watchAX(
        _ notifications: [AXNotification],
        _ validRoles: [Role]
    ) -> AnyPublisher<WatchAXOutput, Never> {
        guard processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return Empty().eraseToAnyPublisher()
        }
        let pid = processIdentifier
        return AXWatchRetry.publisher(
            pid: pid,
            isAlive: { [weak self] in self?.isTerminated == false },
            attach: { [weak self] send -> AnyCancellable? in
                guard let runningApplication = self,
                      let app = Application(runningApplication)
                else { return nil }
                // A hung target would otherwise block the main thread for the global 0.5s AX timeout on
                // every retry; 0.25s matches CaretFocusObserver and is still far above a live app's reply.
                app.messagingTimeout = 0.25

                let cancelBag = CancelBag()
                let appObserver: Observer
                do {
                    appObserver = try Observer(processID: pid) { (_ appObserver: Observer, _ element: UIElement, _ event: AXNotification) in
                        // Watch events on new windows
                        if event == .windowCreated {
                            notify(appObserver, validRoles, element, notifications)?.store(in: cancelBag)
                        }
                        send((runningApplication, event))
                    }
                } catch {
                    return nil
                }

                guard let registration = notify(appObserver, validRoles, app, notifications)
                else { return nil }
                registration.store(in: cancelBag)
                runningApplication.activateAccessibilities()

                return AnyCancellable {
                    cancelBag.cancel()
                    appObserver.stop()
                }
            }
        )
    }
}

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
        attach: @escaping (_ send: @escaping (Output) -> Void) -> AnyCancellable?,
        delay: @escaping (TimeInterval) -> AnyPublisher<Date, Never> = { Timer.delay(seconds: $0) }
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
                    var retryCap: TimeInterval?
                    if !isAlive() {
                        result = "terminated"
                        subscriber.send(completion: .finished)
                    } else if !isTrusted() {
                        result = "untrusted"
                        retryCap = untrustedDelayCap
                    } else if let observer = attach(subscriber.send) {
                        result = "attached"
                        observer.store(in: cancelBag)
                    } else {
                        result = "not-ready"
                        retryCap = notReadyDelayCap
                    }
                    // Log first-attempt failures, late successes, then about once a minute while failing.
                    waitedSinceLog += wait
                    let isNoteworthy = n == 1 ? result != "attached" : result == "attached"
                    if isNoteworthy || waitedSinceLog >= 60 {
                        waitedSinceLog = 0
                        IndicatorDiagnostics.record("ax.watch pid=\(pid) attempt=\(n) result=\(result)")
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

extension NSRunningApplication {
    var ruleDisplayName: String {
        if NSApplication.isSpotlightApp(bundleIdentifier) {
            return "Spotlight"
        }

        return localizedName ?? bundleId() ?? description
    }

    func bundleId() -> String? {
        if let bundleIdentifier = bundleIdentifier {
            return bundleIdentifier
        }

        if let url = bundleURL ?? executableURL {
            return url.bundleId()
        }

        return nil
    }
}

extension NSRunningApplication {
    // For performance reasons Chromium only makes the webview accessible when there it detects voiceover through the `AXEnhancedUserInterface` attribute on the Chrome application itself:
    // http://dev.chromium.org/developers/design-documents/accessibility
    // Similarly, electron uses `AXManualAccessibility`:
    // https://electronjs.org/docs/tutorial/accessibility#assistive-technology
    func activateAccessibilities() {
        guard processIdentifier != ProcessInfo.processInfo.processIdentifier,
              bundleIdentifier?.starts(with: "com.apple.") != true else { return }

        activateAccessibility(attribute: "AXEnhancedUserInterface")
        activateAccessibility(attribute: "AXManualAccessibility")
    }

    func activateAccessibility(attribute: String) {
        if let application = Application(self),
           let isSettable = try? application.attributeIsSettable(attribute),
           isSettable
        {
            if let rawValue: AnyObject = try? application.attribute(attribute),
               CFBooleanGetTypeID() == CFGetTypeID(rawValue),
               let enabled = rawValue as? Bool, enabled
            {
                return
            }

            try? application.setAttribute(attribute, value: true)
        }
    }
}
