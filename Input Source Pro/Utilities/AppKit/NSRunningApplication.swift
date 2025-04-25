import AppKit
import AXSwift
import Combine

private func notify(
    _ observer: Observer?,
    _ validRoles: [Role],
    _ element: UIElement,
    _ notifications: [AXNotification],
    _ indetify: String?
) -> AnyCancellable {
    guard let role = try? element.role(),
          validRoles.contains(role)
    else { return AnyCancellable {} }

    do {
        try notifications.forEach {
            try observer?.addNotification($0, forElement: element)
        }

        return AnyCancellable {
            for notification in notifications {
                try? observer?.removeNotification(notification, forElement: element)
            }
        }
    } catch {
        let role = role.rawValue
        let msg = "\(indetify ?? "nil"): Could not watch [\(element)] with role \(role): \(error)"

        #if DEBUG
            print(msg)
        #endif

        return AnyCancellable {}
    }
}

extension NSRunningApplication {
    typealias WatchAXOutput = (runningApp: NSRunningApplication, notification: AXNotification)

    func watchAX(
        elm: UIElement? = nil,
        _ notifications: [AXNotification],
        _ validRoles: [Role]
    ) -> AnyPublisher<WatchAXOutput, Never> {
        return Timer.delay(seconds: 0.5)
            .receive(on: DispatchQueue.main)
            .flatMapLatest { _ -> AnyPublisher<WatchAXOutput, Never> in
                AnyPublisher.create { [weak self] observer in
                    let cancelBag = CancelBag()

                    self?.activateAccessibilities()

                    guard
                        let runningApplication = self,
                        let app = Application(runningApplication)
                    else { return AnyCancellable {} }

                    let appObserver = app.createObserver { (_ appObserver: Observer, _ element: UIElement, _ event: AXNotification) in
                        // Watch events on new windows
                        if event == .windowCreated {
                            notify(
                                appObserver,
                                validRoles,
                                element,
                                notifications,
                                runningApplication.bundleIdentifier
                            )
                            .store(in: cancelBag)
                        }

                        observer.send((runningApplication, event))
                    }

                    notify(
                        appObserver,
                        validRoles,
                        elm ?? app,
                        notifications,
                        runningApplication.bundleIdentifier
                    )
                    .store(in: cancelBag)

                    return AnyCancellable {
                        cancelBag.cancel()
                        appObserver?.stop()
                    }
                }
            }
            .eraseToAnyPublisher()
    }
}

extension NSRunningApplication {
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
        guard bundleIdentifier?.starts(with: "com.apple.") != true else { return }

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
