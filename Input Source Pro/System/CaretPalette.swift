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
    private(set) var isConnected = false
    var resumeSource: (() -> Void)?

    var changes: AnyPublisher<Void, Never> { updates.eraseToAnyPublisher() }

    private let sourceID = "com.runjuu.Input-Source-Pro.inputmethod.PaletteControl"
    private var sample: Sample?
    /// When the focused pane changed after `sample` was taken: the helper resamples within
    /// `staleGrace`, so until then a stale sample is waited on rather than shown.
    private var staleSince: TimeInterval?
    static let staleGrace: TimeInterval = 0.1
    private var pendingConfirmation: Confirmation?
    private var focus = FocusReadiness()
    private var focusID: String?
    private var focusObserver: CaretFocusObserver?
    private var focusGeneration = 0
    private var focusApplication: NSRunningApplication?
    private var textFocus: TextFocus { focus.state }
    private var focusedAt = ProcessInfo.processInfo.systemUptime
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var activitySubscription: AnyCancellable?
    private var restorationSubscription: AnyCancellable?
    private var channel: CaretChannel?
    private var channelGeneration = UUID()
    private var suspension = Suspension()

    enum TextFocus {
        case input, nonInput, unknown, pending, unavailable

        init(role: Role?, subrole: String? = nil) {
            if subrole == "AXSecureTextField" { self = .nonInput; return }
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

        var permitsCaret: Bool { self == .input || self == .unknown }
    }

    struct Confirmation {
        let pid: pid_t
        let uptime: TimeInterval

        func isCurrent(for pid: pid_t, now: TimeInterval, focusedAt: TimeInterval) -> Bool {
            self.pid == pid && uptime >= focusedAt && now >= uptime && now - uptime < 0.75
        }
    }

    struct FocusReadiness {
        private(set) var state: TextFocus = .unknown
        private(set) var needsRefresh = false
        var confirmation: Confirmation?

        mutating func begin(pid: pid_t?, at uptime: TimeInterval) {
            state = .pending
            needsRefresh = false
            confirmation = pid.map { Confirmation(pid: $0, uptime: uptime) }
        }

        mutating func receive(
            _ update: CaretFocusObserver.Update,
            generation: Int,
            pid: pid_t?,
            since uptime: TimeInterval,
            frontmostPID: pid_t?
        ) -> Bool {
            guard update.isCurrent(generation: generation, pid: pid, since: uptime) else { return false }
            guard frontmostPID == update.pid else {
                // The observer caches this result even when temporary focus prevents us from using it.
                needsRefresh = true
                return false
            }
            resolve(update.state, pid: update.pid, at: update.uptime)
            return true
        }

        mutating func resolve(_ state: TextFocus, pid: pid_t?, at uptime: TimeInterval) {
            self.state = state
            confirmation = state.permitsCaret ? pid.map { Confirmation(pid: $0, uptime: uptime) } : nil
        }

        /// Handles a helper report without a caret; returns whether it is current.
        /// The report's session is not checked: an app getting focus back, for example after a floating
        /// panel such as Raycast closes, starts a new helper session whose first report is this one.
        mutating func receiveMissingCaret(
            at uptime: TimeInterval,
            after lastUptime: TimeInterval,
            focusedAt: TimeInterval,
            isTemporaryInputWindowInProgress: Bool,
            pid: pid_t?
        ) -> Bool {
            // A report from before the current focus would replace its wait with one that is never current.
            guard uptime >= lastUptime, uptime >= focusedAt, !isTemporaryInputWindowInProgress else { return false }
            // Wait for the helper's next sample rather than falling back to the mouse. Custom editors
            // such as Zed expose no text field to Accessibility, so `unknown` focus waits too.
            if state.permitsCaret, let pid { confirmation = Confirmation(pid: pid, uptime: uptime) }
            return true
        }

        func isAwaitingConfirmation(for pid: pid_t, now: TimeInterval, focusedAt: TimeInterval) -> Bool {
            (state == .pending || state.permitsCaret)
                && confirmation?.isCurrent(for: pid, now: now, focusedAt: focusedAt) == true
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
            return CGPoint(x: rect.midX, y: rect.maxY + 6)
        }
    }

    private func source() -> TISInputSource? {
        CaretInputSource.find(sourceID, bundleIdentifier: sourceID)
    }

    func start() {
        guard !isEnabled,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        else { return }
        let generation = UUID()
        channelGeneration = generation
        do {
            let channel = try CaretChannel(role: .application, onMessage: { [weak self] message in
                MainActor.assumeIsolated {
                    guard let self = self, self.channelGeneration == generation else { return }
                    switch message {
                    case .ready:
                        self.isConnected = true
                        self.sendActivity(isInputEvent: false)
                        self.updates.send(())
                    case let .position(position):
                        self.receive(position)
                    case .activity: break
                    }
                }
            }, onConnectionChange: { [weak self] connected in
                MainActor.assumeIsolated {
                    guard let self = self, self.channelGeneration == generation else { return }
                    self.sample = nil
                    self.pendingConfirmation = nil
                    if !connected { self.isConnected = false }
                    if connected { self.sendActivity(isInputEvent: false) }
                    self.updates.send(())
                }
            })
            try channel.start()
            self.channel = channel
        } catch {
            NSLog("Could not start the private cursor-helper connection: %@", String(describing: error))
            return
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                // The temporary input window briefly activates this app, and the previous app's reactivation
                // can arrive while frontmostApplication still reports this app; rebind once restoration completes.
                // That reactivation can also arrive after restoration completed: keep the bound app's state,
                // as the restoration subscriber does.
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if InputSourceSwitcher.isTemporaryInputWindowInProgress { return }
                if let app, InputSourceSwitcher.isHandlingTemporaryInputWindowActivation,
                   InputSourceSwitcher.isTemporaryInputWindowApplicationActivation(app)
                    || app.processIdentifier == self?.focusApplication?.processIdentifier
                { return }
                self?.watchTextFocus()
            }
        })
        restorationSubscription = InputSourceSwitcher.temporaryInputWindowRestored
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self = self,
                      !InputSourceSwitcher.isTemporaryInputWindowInProgress,
                      self.focus.needsRefresh ||
                        NSWorkspace.shared.frontmostApplication?.processIdentifier != self.focusApplication?.processIdentifier
                else { return }
                self.watchTextFocus()
            }
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
            MainActor.assumeIsolated {
                self?.sendActivity(isInputEvent: false)
                self?.updates.send(())
            }
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

    func startAndWaitForConnection() async -> Bool {
        start()
        let generation = channelGeneration
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while isEnabled, generation == channelGeneration {
            if isConnected { return true }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { return false }
        }
        return false
    }

    private func sendActivity(isInputEvent: Bool = true) {
        guard isEnabled else { return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let permitsTracking = !suspension.isSuspended && !IsSecureEventInputEnabled()
            && pid != ProcessInfo.processInfo.processIdentifier && pid == focusApplication?.processIdentifier
            && textFocus.permitsCaret
        channel?.send(.activity(CaretActivity(pid: pid, uptime: ProcessInfo.processInfo.systemUptime,
                                             focusID: focusID ?? "", permitsTracking: permitsTracking,
                                             isInputEvent: isInputEvent)))
    }

    private func watchTextFocus() {
        focusGeneration += 1
        sample = nil
        pendingConfirmation = nil
        focusID = nil
        focusedAt = ProcessInfo.processInfo.systemUptime
        focusApplication = NSWorkspace.shared.frontmostApplication
        focus.begin(pid: focusApplication?.processIdentifier, at: focusedAt)
        guard isEnabled, !suspension.isSuspended,
              focusApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            focusApplication = nil
            focusObserver?.watch(pid: nil, generation: focusGeneration)
            focus.resolve(.nonInput, pid: nil, at: focusedAt)
            updates.send(())
            return
        }
        sendActivity(isInputEvent: false)
        if focusObserver == nil {
            focusObserver = CaretFocusObserver { [weak self] update in
                Task { @MainActor in self?.receiveFocus(update) }
            }
        }
        focusObserver?.watch(pid: focusApplication?.processIdentifier, generation: focusGeneration)
        updates.send(())
    }

    private func receiveFocus(_ update: CaretFocusObserver.Update) {
        guard isEnabled, !suspension.isSuspended,
              focus.receive(update, generation: focusGeneration, pid: focusApplication?.processIdentifier,
                            since: focusedAt, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        else { return }
        focusedAt = update.uptime
        IndicatorDiagnostics.record("helper.focus pid=\(update.pid) kind=\(textFocus) focusedAt=\(focusedAt)")
        sample = nil
        pendingConfirmation = nil
        // Wait for geometry belonging to this field, not an AX fallback or the old field.
        focusID = textFocus == .input ? UUID().uuidString : nil
        updates.send(())
        sendActivity()
    }

    private func handleLifecycleEvent(reason: Suspension.Reason, suspended: Bool) {
        suspension.set(reason, suspended: suspended)
        sample = nil
        pendingConfirmation = nil
        focus.confirmation = nil
        focusID = nil
        focusedAt = ProcessInfo.processInfo.systemUptime
        updates.send(())
        if suspension.isSuspended {
            focusGeneration += 1
            focusObserver?.watch(pid: nil, generation: focusGeneration)
        } else {
            watchTextFocus()
        }
        sendActivity(isInputEvent: false)
        // Wake/session activation can deselect auxiliary sources. Never switch the keyboard
        // or re-enable revoked permission, and wait until all suspension reasons have ended.
        if isEnabled, !suspension.isSuspended { resumeSource?() }
    }

    func stop() {
        guard isEnabled else { return }
        isEnabled = false
        isConnected = false
        channelGeneration = UUID()
        channel?.stop()
        channel = nil
        activitySubscription?.cancel()
        activitySubscription = nil
        restorationSubscription = nil
        timer?.invalidate()
        timer = nil
        sample = nil
        pendingConfirmation = nil
        focusID = nil
        focusGeneration += 1
        focusObserver = nil
        focusApplication = nil
        focus = FocusReadiness()
        suspension = Suspension()
        if let source = source() { TISDeselectInputSource(source) }
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        updates.send(())
    }

    private func receive(_ position: CaretPosition) {
        guard isEnabled, !suspension.isSuspended, !IsSecureEventInputEnabled() else { return }
        let rectString = position.rect
        let pid = Int(position.pid)
        let uptime = position.uptime
        let pending = position.pending
        IndicatorDiagnostics.record("helper.receive pid=\(pid) rect=\(NSRectFromString(rectString)) empty=\(rectString.isEmpty) pending=\(pending) sampleUptime=\(uptime) focus=\(textFocus) focusedAt=\(focusedAt) session=\(position.session.prefix(8))")
        let lastUptime = max(sample?.uptime ?? 0, pendingConfirmation?.uptime ?? 0)
        if let focusID = focusID, position.focusID != focusID {
            IndicatorDiagnostics.record("helper.rejected reason=focus-token-mismatch pid=\(pid)")
            // The helper may have activated after the focus notification was sent.
            if Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) == pid {
                sendActivity()
            }
            return
        }
        if rectString.isEmpty && !pending {
            // The temporary input window's focus steal makes the helper report focus loss;
            // the sample stays valid for the app that gets focus back. A floating panel such as Raycast
            // taking key focus also leaves the caret where it was, so the sample is kept and serves the app
            // while fresh; a field change within the app clears it through the focus update.
            if focus.receiveMissingCaret(
                at: uptime, after: lastUptime, focusedAt: focusedAt,
                isTemporaryInputWindowInProgress: InputSourceSwitcher.isTemporaryInputWindowInProgress,
                pid: focusApplication?.processIdentifier
            ) {
                pendingConfirmation = nil
            }
        } else if textFocus.permitsCaret, let owner = pid_t(exactly: pid),
                  // The temporary input window may hold focus while the helper reports the app it took it from.
                  Self.holdsFocus(owner),
                  uptime >= focusedAt, uptime <= ProcessInfo.processInfo.systemUptime,
                  uptime >= lastUptime {
            if pending {
                pendingConfirmation = Confirmation(pid: owner, uptime: uptime)
            } else {
                pendingConfirmation = nil
                sample = Sample(rect: NSRectFromString(rectString), pid: owner, uptime: uptime)
                staleSince = nil
                if sample?.point(for: owner, now: uptime, focusedAt: focusedAt,
                                 screens: NSScreen.screens.map(\.frame)) != nil {
                    focus.confirmation = nil
                }
            }
        } else {
            IndicatorDiagnostics.record("helper.rejected reason=focus-pid-or-time pid=\(pid) lastUptime=\(lastUptime) frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
        }
        updates.send(())
    }

    /// Whether `pid` is the app the user is typing in: frontmost, or the app the
    /// temporary input window took focus from while it holds it.
    private static func holdsFocus(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            || InputSourceSwitcher.temporaryInputWindowPreviousPID == pid
    }

    func point(for app: NSRunningApplication) -> CGPoint? {
        guard isEnabled, !suspension.isSuspended, !IsSecureEventInputEnabled(), textFocus.permitsCaret,
              focusApplication?.processIdentifier == app.processIdentifier,
              Self.holdsFocus(app.processIdentifier)
        else {
            IndicatorDiagnostics.record("helper.unavailable pid=\(app.processIdentifier) enabled=\(isEnabled) suspended=\(suspension.isSuspended) focus=\(textFocus) frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
            return nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        if isWaitingOnStaleSample(for: app.processIdentifier, now: now) {
            IndicatorDiagnostics.record("helper.lookup pid=\(app.processIdentifier) point=nil reason=stale-pane-sample")
            return nil
        }
        let point = sample?.point(
            for: app.processIdentifier, now: now,
            focusedAt: focusedAt, screens: NSScreen.screens.map(\.frame)
        )
        IndicatorDiagnostics.record("helper.lookup pid=\(app.processIdentifier) point=\(String(describing: point)) samplePID=\(sample?.pid ?? 0) ageMs=\(sample.map { (now - $0.uptime) * 1000 } ?? -1) sampleRect=\(String(describing: sample?.rect)) focusedAt=\(focusedAt)")
        return point
    }

    /// The terminal's focused pane changed: the last sample shows the previous pane's caret.
    func markSampleStale() {
        guard sample != nil, staleSince == nil else { return }
        staleSince = ProcessInfo.processInfo.systemUptime
        // Re-query once the grace ends so a pane switch the helper never resamples (no key event) still shows.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.staleGrace) { [weak self] in self?.updates.send(()) }
    }

    private func isWaitingOnStaleSample(for pid: pid_t, now: TimeInterval) -> Bool {
        guard let staleSince, let sample, sample.pid == pid, sample.uptime < staleSince else { return false }
        if now - staleSince < Self.staleGrace { return true }
        guard let pending = pendingConfirmation, pending.uptime > sample.uptime else { return false }
        return pending.isCurrent(for: pid, now: now, focusedAt: focusedAt)
    }

    func suppressesAccessibilityFallback(for app: NSRunningApplication) -> Bool {
        if isEnabled && IsSecureEventInputEnabled() { return true }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        guard isEnabled, !suspension.isSuspended,
              Self.holdsFocus(app.processIdentifier)
        else { return false }
        return focusApplication?.processIdentifier != app.processIdentifier
            || !textFocus.permitsCaret || isAwaitingConfirmation(for: app)
    }

    func isAwaitingConfirmation(for app: NSRunningApplication) -> Bool {
        guard isEnabled, !suspension.isSuspended,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              Self.holdsFocus(app.processIdentifier)
        else { return false }
        // The indicator's activation subscriber can run before our workspace observer.
        if focusApplication?.processIdentifier != app.processIdentifier { return true }
        let now = ProcessInfo.processInfo.systemUptime
        if focus.isAwaitingConfirmation(for: app.processIdentifier, now: now, focusedAt: focusedAt) { return true }
        if isWaitingOnStaleSample(for: app.processIdentifier, now: now) { return true }
        return textFocus.permitsCaret && pendingConfirmation?.isCurrent(
            for: app.processIdentifier, now: now, focusedAt: focusedAt
        ) == true
    }
}
