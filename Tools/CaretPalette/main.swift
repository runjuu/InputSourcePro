import Cocoa
import Carbon
import InputMethodKit

let sourceID = "com.runjuu.Input-Source-Pro.inputmethod.PaletteControl"
let helperConnection = CaretHelperConnection()

final class CaretHelperConnection {
    weak var controller: CaretProbeController?
    private(set) var connected = false
    private var channel: CaretChannel?

    func start() throws {
        let channel = try CaretChannel(role: .helper, onMessage: { [weak self] message in
            guard case let .activity(activity) = message else { return }
            self?.controller?.receiveActivity(activity)
        }, onConnectionChange: { [weak self] connected in
            self?.connected = connected
            if connected { self?.channel?.send(.ready) }
            else { self?.controller?.suspendTracking() }
        })
        try channel.start()
        self.channel = channel
    }

    func publish(_ position: CaretPosition) {
        guard connected else { return }
        channel?.send(.position(position))
    }
}

@objc(CaretProbeController)
final class CaretProbeController: IMKInputController {
    private var timer: Timer?
    private let session = UUID().uuidString
    private var isActive = false
    private var refreshScheduled = false
    private var polling = CaretPollingSchedule()
    private var geometryFilter = CaretGeometryFilter()
    private var geometryPID: pid_t = 0
    private var activity: CaretActivity?
    private var lastPublishedRect: NSRect?
    private var lastPublishedPID: pid_t = 0
    private var lastPublishedAt: TimeInterval = 0
    private var lastPublishedPending = false
    private var lastActivityAt: TimeInterval = 0
    private var focusID = ""

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        timer?.invalidate()
        timer = nil
        isActive = true
        geometryFilter = CaretGeometryFilter()
        helperConnection.controller = self
        // Wait for an authenticated activity/heartbeat before querying any client.
        activity = nil
    }

    func receiveActivity(_ activity: CaretActivity) {
        guard helperConnection.connected, activity.uptime.isFinite,
              activity.uptime <= ProcessInfo.processInfo.systemUptime else { return }
        self.activity = activity
        if activity.focusID != focusID {
            focusID = activity.focusID
            geometryFilter = CaretGeometryFilter()
            lastPublishedAt = 0
        }
        guard activity.permitsTracking, !IsSecureEventInputEnabled() else {
            suspendTracking()
            return
        }
        if activity.isInputEvent { refreshAfterActivity() }
        else if timer == nil { refresh() }
    }

    func suspendTracking() {
        activity = nil
        timer?.invalidate()
        timer = nil
        geometryFilter = CaretGeometryFilter()
        publish(rect: nil, pid: 0)
    }

    override func deactivateServer(_ sender: Any!) {
        stopTracking()
        super.deactivateServer(sender)
    }

    override func inputControllerWillClose() {
        stopTracking()
        super.inputControllerWillClose()
    }

    override func recognizedEvents(_ sender: Any!) -> Int { 0 }

    private func stopTracking() {
        isActive = false
        suspendTracking()
        if helperConnection.controller === self { helperConnection.controller = nil }
    }

    private func refreshAfterActivity() {
        guard isActive else { return }
        lastActivityAt = ProcessInfo.processInfo.systemUptime
        polling.noteActivity(at: lastActivityAt)
        if !refreshScheduled {
            refreshScheduled = true
            // Let the foreground app process input before querying its updated caret.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.refreshScheduled = false
                self.refresh()
            }
        }
    }

    private func refresh() {
        guard isActive, helperConnection.connected, let activity = activity,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              activity.permitsQuery(pid: pid, now: ProcessInfo.processInfo.systemUptime,
                                    secureInput: IsSecureEventInputEnabled()) else {
            suspendTracking()
            return
        }
        publishPosition()
        timer?.invalidate()
        let interval = polling.interval(at: ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = interval == CaretPollingSchedule.idleInterval ? 0.025 : 0.001
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func publishPosition() {
        guard isActive, let client = client(),
              let app = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = app.bundleIdentifier,
              client.bundleIdentifier() == bundleIdentifier
        else { return }

        var rect = NSRect.zero
        // This index is relative to the inline session, not the document.
        // The auxiliary palette owns no inline text; zero queries the current selection.
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        if rect != lastPublishedRect || app.processIdentifier != lastPublishedPID {
            // Follow ongoing programmatic movement after the idle poll discovers it.
            polling.noteActivity(at: ProcessInfo.processInfo.systemUptime)
        }
        if app.processIdentifier != geometryPID {
            geometryFilter = CaretGeometryFilter()
            geometryPID = app.processIdentifier
        }
        if let position = geometryFilter.accept(
            rect, at: ProcessInfo.processInfo.systemUptime,
            // Codex can briefly return wrong geometry even within one character's width.
            confirmEveryChange: bundleIdentifier == "com.openai.codex", activityAt: lastActivityAt
        ) {
            publish(rect: position, pid: app.processIdentifier)
        } else {
            publish(rect: nil, pid: app.processIdentifier, pending: true)
        }
    }

    private func publish(rect: NSRect?, pid: pid_t, pending: Bool = false) {
        guard helperConnection.connected else { return }
        let rect = IsSecureEventInputEnabled() ? nil : rect
        let pending = IsSecureEventInputEnabled() ? false : pending
        let now = ProcessInfo.processInfo.systemUptime
        // Send movement immediately; unchanged geometry only needs a freshness heartbeat.
        guard (rect == nil && !pending) || rect != lastPublishedRect || pid != lastPublishedPID ||
            pending != lastPublishedPending || now - lastPublishedAt >= 0.25
        else { return }
        lastPublishedRect = rect
        lastPublishedPID = pid
        lastPublishedAt = now
        lastPublishedPending = pending
        helperConnection.publish(CaretPosition(session: session, pid: pid, uptime: now,
                                                rect: rect.map(NSStringFromRect) ?? "",
                                                pending: pending, focusID: focusID))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try helperConnection.start() }
        catch {
            NSLog("Cursor Helper could not create its private connection: %@", String(describing: error))
            NSApplication.shared.terminate(nil)
            return
        }
        server = IMKServer(name: "com_runjuu_Input_Source_Pro_PaletteControl_Connection", bundleIdentifier: sourceID)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
