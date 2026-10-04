import AppKit
import Carbon
import Combine
import AXSwift

/// Optional cursor support, activated only after helper setup succeeds.
@MainActor
final class CaretPalette {
    static let shared = CaretPalette()
    private let updates = PassthroughSubject<Void, Never>()
    private(set) var isEnabled = false
    var resumeSource: (() -> Void)?

    var changes: AnyPublisher<Void, Never> { updates.eraseToAnyPublisher() }

    private let sourceID = "dev.inputsourcepro.inputmethod.PaletteControl"
    private var sample: Sample?
    private var pendingConfirmation: Confirmation?
    private var focusConfirmation: Confirmation?
    private var focusID: String?
    private var focusObserver: AXSwift.Observer?
    private var focusApplication: NSRunningApplication?
    private var focusedElement: UIElement?
    private var textFocus = TextFocus.unknown
    private var session: String?
    private var focusedAt = ProcessInfo.processInfo.systemUptime
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var activitySubscription: AnyCancellable?
    private var suspension = Suspension()

    enum TextFocus {
        case input, nonInput, unknown

        init(role: Role?) {
            switch role {
            case .textArea, .textField, .comboBox:
                self = .input
            case .webArea, .button, .checkBox, .radioButton, .popUpButton,
                 .menuItem, .toolbar, .staticText, .image, .link:
                self = .nonInput
            default:
                // Custom editors such as Zed expose only a window or group.
                self = .unknown
            }
        }

        var permitsCaret: Bool { self != .nonInput }
    }

    struct Confirmation {
        let pid: pid_t
        let uptime: TimeInterval

        func isCurrent(for pid: pid_t, now: TimeInterval, focusedAt: TimeInterval) -> Bool {
            self.pid == pid && uptime >= focusedAt && now >= uptime && now - uptime < 0.75
        }
    }

    struct Suspension {
        enum Reason: Hashable { case systemSleep, displaySleep, inactiveSession }
        private var reasons: Set<Reason> = []
        var isSuspended: Bool { !reasons.isEmpty }

        mutating func set(_ reason: Reason, suspended: Bool) {
            if suspended { reasons.insert(reason) } else { reasons.remove(reason) }
        }
    }

    struct Sample {
        let rect: CGRect
        let pid: pid_t
        let uptime: TimeInterval

        func point(for pid: pid_t, now: TimeInterval, focusedAt: TimeInterval, screens: [CGRect]) -> CGPoint? {
            guard self.pid == pid, uptime >= focusedAt, now >= uptime, now - uptime < 0.75,
                  [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite),
                  rect.width >= 0, rect.width <= 10, rect.height > 0, rect.height <= 200,
                  screens.contains(where: { $0.intersects(rect.insetBy(dx: -1, dy: 0)) })
            else { return nil }
            // IMK returns AppKit screen coordinates, already bottom-left based.
            return CGPoint(x: rect.minX, y: rect.maxY + 6)
        }
    }

    private func source() -> TISInputSource? {
        CaretInputSource.find(sourceID)
    }

    func start() {
        guard !isEnabled,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        else { return }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.inputsourcepro.caretPalette.position"),
            object: sourceID, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.receive(notification) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.watchTextFocus()
            }
        })
        let lifecycleEvents: [(Notification.Name, Suspension.Reason, Bool)] = [
            (NSWorkspace.willSleepNotification, .systemSleep, true),
            (NSWorkspace.didWakeNotification, .systemSleep, false),
            (NSWorkspace.screensDidSleepNotification, .displaySleep, true),
            (NSWorkspace.screensDidWakeNotification, .displaySleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .inactiveSession, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession, false),
        ]
        for (name, reason, suspended) in lifecycleEvents {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleLifecycleEvent(reason: reason, suspended: suspended)
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } })
        isEnabled = true
        // The setup utility selects the source and verifies it in a fresh process.
        // This process can retain a pre-installation TIS cache indefinitely.
        watchTextFocus()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            // Expire a stale sample even if the helper stops sending.
            MainActor.assumeIsolated { self?.updates.send(()) }
        }
        let activityEvents: NSEvent.EventTypeMask = [
            .keyDown, .flagsChanged, .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
        ]
        activitySubscription = NSEvent.watch(matching: activityEvents)
            .merge(with: NSEvent.watchLocal(matching: activityEvents))
            .map { _ in () }
            .throttle(for: .milliseconds(16), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.sendActivity() }
    }

    private func sendActivity() {
        guard isEnabled, !suspension.isSuspended,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("dev.inputsourcepro.caretPalette.activity"),
            object: sourceID,
            userInfo: ["pid": Int(app.processIdentifier), "uptime": ProcessInfo.processInfo.systemUptime,
                       "focusID": focusID ?? ""],
            deliverImmediately: true
        )
    }

    private func watchTextFocus() {
        focusObserver?.stop()
        focusObserver = nil
        focusedElement = nil
        textFocus = .unknown
        sample = nil
        pendingConfirmation = nil
        focusConfirmation = nil
        focusID = nil
        focusedAt = ProcessInfo.processInfo.systemUptime
        focusApplication = NSWorkspace.shared.frontmostApplication
        guard focusApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            focusApplication = nil
            textFocus = .nonInput
            updates.send(())
            return
        }
        if let app = focusApplication, let application = Application(app) {
            focusObserver = try? AXSwift.Observer(processID: app.processIdentifier) { [weak self] _, _, _ in
                MainActor.assumeIsolated { self?.refreshTextFocus() }
            }
            try? focusObserver?.addNotification(.focusedUIElementChanged, forElement: application)
            try? focusObserver?.addNotification(.focusedWindowChanged, forElement: application)
            refreshTextFocus()
        }
        updates.send(())
    }

    private func refreshTextFocus() {
        guard let app = focusApplication,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let application = Application(app)
        else { return }
        let element: UIElement? = try? application.attribute(.focusedUIElement)
        let state = TextFocus(role: try? element?.role())
        guard element != focusedElement || state != textFocus else { return }
        focusedElement = element
        textFocus = state
        focusedAt = ProcessInfo.processInfo.systemUptime
        IndicatorDiagnostics.record("helper.focus pid=\(app.processIdentifier) kind=\(state) focusedAt=\(focusedAt)")
        sample = nil
        pendingConfirmation = nil
        // Wait for geometry belonging to this field, not an AX fallback or the old field.
        focusConfirmation = state == .input ? Confirmation(pid: app.processIdentifier, uptime: focusedAt) : nil
        focusID = state == .input ? UUID().uuidString : nil
        updates.send(())
        sendActivity()
    }

    private func handleLifecycleEvent(reason: Suspension.Reason, suspended: Bool) {
        suspension.set(reason, suspended: suspended)
        sample = nil
        pendingConfirmation = nil
        focusConfirmation = nil
        focusID = nil
        session = nil
        focusedAt = ProcessInfo.processInfo.systemUptime
        updates.send(())
        if !suspension.isSuspended { watchTextFocus() }
        // Wake/session activation can deselect auxiliary sources. Never switch the keyboard
        // or re-enable revoked permission, and wait until all suspension reasons have ended.
        if isEnabled, !suspension.isSuspended { resumeSource?() }
    }

    func stop() {
        guard isEnabled else { return }
        isEnabled = false
        activitySubscription?.cancel()
        activitySubscription = nil
        timer?.invalidate()
        timer = nil
        sample = nil
        pendingConfirmation = nil
        focusConfirmation = nil
        focusID = nil
        focusObserver?.stop()
        focusObserver = nil
        focusApplication = nil
        focusedElement = nil
        textFocus = .unknown
        session = nil
        suspension = Suspension()
        if let source = source() { TISDeselectInputSource(source) }
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        updates.send(())
    }

    private func receive(_ notification: Notification) {
        guard isEnabled, !suspension.isSuspended, let values = notification.userInfo,
              let session = values["session"] as? String,
              let rectString = values["rect"] as? String,
              let pid = values["pid"] as? Int,
              let uptime = values["uptime"] as? Double
        else { return }
        let pending = values["pending"] as? Bool == true
        IndicatorDiagnostics.record("helper.receive pid=\(pid) rect=\(NSRectFromString(rectString)) empty=\(rectString.isEmpty) pending=\(pending) sampleUptime=\(uptime) focus=\(textFocus) focusedAt=\(focusedAt) sessionMatches=\(self.session == session)")
        let lastUptime = max(sample?.uptime ?? 0, pendingConfirmation?.uptime ?? 0)
        if let focusID = focusID, values["focusID"] as? String != focusID {
            IndicatorDiagnostics.record("helper.rejected reason=focus-token-mismatch pid=\(pid)")
            // The helper may have activated after the focus notification was sent.
            if Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) == pid {
                sendActivity()
            }
            return
        }
        if rectString.isEmpty && !pending {
            if self.session == session, uptime >= lastUptime {
                sample = nil
                pendingConfirmation = nil
                if textFocus == .input, let app = focusApplication {
                    focusConfirmation = Confirmation(pid: app.processIdentifier, uptime: uptime)
                }
            }
        } else if textFocus.permitsCaret, let app = NSWorkspace.shared.frontmostApplication,
                  Int(app.processIdentifier) == pid,
                  uptime >= focusedAt, uptime <= ProcessInfo.processInfo.systemUptime,
                  uptime >= lastUptime {
            self.session = session
            if pending {
                pendingConfirmation = Confirmation(pid: app.processIdentifier, uptime: uptime)
            } else {
                pendingConfirmation = nil
                sample = Sample(rect: NSRectFromString(rectString), pid: app.processIdentifier, uptime: uptime)
                if sample?.point(for: app.processIdentifier, now: uptime, focusedAt: focusedAt,
                                 screens: NSScreen.screens.map(\.frame)) != nil {
                    focusConfirmation = nil
                }
            }
        } else {
            IndicatorDiagnostics.record("helper.rejected reason=focus-pid-or-time pid=\(pid) lastUptime=\(lastUptime) frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
        }
        updates.send(())
    }

    func point(for app: NSRunningApplication) -> CGPoint? {
        guard isEnabled, !suspension.isSuspended, textFocus.permitsCaret,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        else {
            IndicatorDiagnostics.record("helper.unavailable pid=\(app.processIdentifier) enabled=\(isEnabled) suspended=\(suspension.isSuspended) focus=\(textFocus) frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
            return nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        let point = sample?.point(
            for: app.processIdentifier, now: now,
            focusedAt: focusedAt, screens: NSScreen.screens.map(\.frame)
        )
        IndicatorDiagnostics.record("helper.lookup pid=\(app.processIdentifier) point=\(String(describing: point)) samplePID=\(sample?.pid ?? 0) ageMs=\(sample.map { (now - $0.uptime) * 1000 } ?? -1) sampleRect=\(String(describing: sample?.rect)) focusedAt=\(focusedAt)")
        return point
    }

    func suppressesAccessibilityFallback(for app: NSRunningApplication) -> Bool {
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        guard isEnabled, !suspension.isSuspended,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        else { return false }
        return !textFocus.permitsCaret || isAwaitingConfirmation(for: app)
    }

    func isAwaitingConfirmation(for app: NSRunningApplication) -> Bool {
        guard isEnabled, !suspension.isSuspended, textFocus.permitsCaret,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        return focusConfirmation?.isCurrent(for: app.processIdentifier, now: now, focusedAt: focusedAt) == true || pendingConfirmation?.isCurrent(
            for: app.processIdentifier, now: now, focusedAt: focusedAt
        ) == true
    }
}
