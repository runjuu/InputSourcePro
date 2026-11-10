import AppKit
import AXSwift
import Combine

/// Registers `notifications` on `element` when its role is one of `validRoles`.
/// Returns the cancellable that unregisters them (an empty one for roles we ignore) with the
/// notifications the element refused for good, and `nil` when the element has no role yet.
/// Throws when the role could not be read or the registration should be retried.
private func notify(
    _ observer: Observer,
    _ validRoles: [Role],
    _ element: UIElement,
    _ notifications: [AXNotification]
) throws -> (cancellable: AnyCancellable, rejected: [AXNotification])? {
    guard let registration = try AXWatchRetry.register(
        role: try element.attribute(.role),
        validRoles: validRoles,
        notifications: notifications,
        add: { try observer.addNotification($0, forElement: element) }
    ) else { return nil }
    let cancellable = AnyCancellable {
        for notification in registration.registered {
            try? observer.removeNotification(notification, forElement: element)
        }
    }
    return (cancellable, registration.rejected)
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
            attach: { [weak self] send -> AXWatchRetry.Attach in
                guard let runningApplication = self,
                      let app = Application(runningApplication)
                else { return .notReady(reason: "gone") }
                // The probe has just seen the target answer, so this only bounds the block when it hangs
                // in between. It covers the role read and registration on `app`; elements of windows
                // created later and the warm-up below still use the global AX timeout.
                app.messagingTimeout = AXWatchRetry.messagingTimeout

                let cancelBag = CancelBag()
                let appObserver: Observer
                do {
                    appObserver = try Observer(processID: pid) { (_ appObserver: Observer, _ element: UIElement, _ event: AXNotification) in
                        // Watch events on new windows
                        if event == .windowCreated {
                            (try? notify(appObserver, validRoles, element, notifications))?
                                .cancellable.store(in: cancelBag)
                        }
                        send((runningApplication, event))
                    }
                } catch {
                    return .notReady(reason: "observer-\(error)")
                }

                let rejected: [AXNotification]
                do {
                    guard let watch = try notify(appObserver, validRoles, app, notifications)
                    else { return .notReady(reason: "no-role") }
                    watch.cancellable.store(in: cancelBag)
                    rejected = watch.rejected
                } catch {
                    return .notReady(reason: "\(error)")
                }
                runningApplication.activateAccessibilities()

                return .attached(AnyCancellable {
                    cancelBag.cancel()
                    appObserver.stop()
                }, rejected: rejected)
            }
        )
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
