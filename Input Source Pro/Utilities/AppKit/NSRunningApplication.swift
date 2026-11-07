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
    guard let registered = try? AXWatchRetry.register(
        role: try element.attribute(.role),
        validRoles: validRoles,
        notifications: notifications,
        add: { try observer.addNotification($0, forElement: element) }
    ) else { return nil }
    return AnyCancellable {
        for notification in registered {
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
/// or when this process is not trusted yet. Attempts are made after 0.5s, 1s, 2s, 4s, then every 5s:
/// the 0.5s first delay is what `watchAX` has always used (initial commit, no recorded reason beyond
/// letting a freshly activated app settle), the doubling catches an app that finishes launching within a
/// few seconds, and the 5s cap keeps a permanently denied permission at one cheap `AXIsProcessTrusted`
/// call per five seconds per app instead of a retry storm.
///
/// Contract: retries until the first successful attach; a later loss of the observer (while the pid stays
/// alive) is not detected. Retries stop when the app terminates (publisher completes) or the subscription
/// is cancelled. Subscribe, ticks and cancel all run on the main thread: ticks come from `Timer.delay` on
/// the main run loop, `Observer.stop()` uses `RunLoop.current`, and `CancelBag` is not thread-safe. The
/// `delay` publisher must emit asynchronously (as `Timer.delay` does).
enum AXWatchRetry {
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        min(0.5 * pow(2, Double(attempt - 1)), 5)
    }

    /// Registers `notifications` one by one on an element with the given raw role.
    /// Returns `nil` when the element is not ready yet (no role: AXSwift documents this for elements still
    /// initializing), `[]` for a role outside `validRoles`, otherwise the notifications that registered.
    /// Notifications the element does not support are skipped; any other error is rethrown so the attach
    /// is retried instead of keeping a partial registration.
    static func register(
        role: String?,
        validRoles: [Role],
        notifications: [AXNotification],
        add: (AXNotification) throws -> Void
    ) throws -> [AXNotification]? {
        guard let role else { return nil }
        guard let role = Role(rawValue: role), validRoles.contains(role) else { return [] }
        var registered: [AXNotification] = []
        for notification in notifications {
            do {
                try add(notification)
                registered.append(notification)
            } catch AXError.notificationUnsupported {
                continue
            } catch AXError.notificationAlreadyRegistered {
                registered.append(notification)
            }
        }
        return registered
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

            func attempt(_ n: Int) {
                latestAttempt = n
                let pending = delay(Self.delay(forAttempt: n)).sink { _ in
                    guard !isCancelled else { return }
                    let result: String
                    if !isAlive() {
                        result = "terminated"
                        subscriber.send(completion: .finished)
                    } else if !isTrusted() {
                        result = "untrusted"
                    } else if let observer = attach(subscriber.send) {
                        result = "attached"
                        observer.store(in: cancelBag)
                    } else {
                        result = "not-ready"
                    }
                    // Log first-attempt failures, late successes, then about once a minute while failing.
                    let isNoteworthy = n == 1 ? result != "attached" : result == "attached"
                    if isNoteworthy || n % 12 == 0 {
                        IndicatorDiagnostics.record("ax.watch pid=\(pid) attempt=\(n) result=\(result)")
                    }
                    if result == "untrusted" || result == "not-ready" {
                        attempt(n + 1)
                    }
                }
                // A synchronous emission would already have scheduled the next attempt; keep that timer.
                if latestAttempt == n { timer = pending }
            }
            attempt(1)

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
