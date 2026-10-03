import Cocoa
import Carbon
import InputMethodKit

let sourceID = "dev.inputsourcepro.inputmethod.PaletteControl"
let notificationName = Notification.Name("dev.inputsourcepro.caretPalette.position")

@objc(CaretProbeController)
final class CaretProbeController: IMKInputController {
    private var timer: Timer?
    private let session = UUID().uuidString
    private var isActive = false
    private var refreshScheduled = false
    private var polling = CaretPollingSchedule()
    private var geometryFilter = CaretGeometryFilter()
    private var geometryPID: pid_t = 0
    private var activityObserver: NSObjectProtocol?
    private var lastPublishedRect: NSRect?
    private var lastPublishedPID: pid_t = 0
    private var lastPublishedAt: TimeInterval = 0
    private var lastPublishedPending = false
    private var lastActivityAt: TimeInterval = 0
    private var focusID = ""

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        timer?.invalidate()
        isActive = true
        geometryFilter = CaretGeometryFilter()
        if activityObserver == nil {
            activityObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("dev.inputsourcepro.caretPalette.activity"),
                object: sourceID, queue: .main
            ) { [weak self] notification in
                let now = ProcessInfo.processInfo.systemUptime
                guard let values = notification.userInfo,
                      let pid = values["pid"] as? Int,
                      let uptime = values["uptime"] as? Double,
                      uptime <= now, now - uptime < 0.25,
                      let app = NSWorkspace.shared.frontmostApplication,
                      Int(app.processIdentifier) == pid
                else { return }
                if let focusID = values["focusID"] as? String, focusID != self?.focusID {
                    self?.focusID = focusID
                    self?.geometryFilter = CaretGeometryFilter()
                    self?.lastPublishedAt = 0
                }
                self?.refreshAfterActivity()
            }
        }
        polling.noteActivity(at: ProcessInfo.processInfo.systemUptime)
        refresh()
    }

    override func deactivateServer(_ sender: Any!) {
        stopTracking()
        super.deactivateServer(sender)
    }

    override func inputControllerWillClose() {
        stopTracking()
        super.inputControllerWillClose()
    }

    override func recognizedEvents(_ sender: Any!) -> Int { Int(NSEvent.EventTypeMask.keyDown.rawValue) }
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        refreshAfterActivity()
        return false
    }

    private func stopTracking() {
        isActive = false
        geometryFilter = CaretGeometryFilter()
        timer?.invalidate()
        timer = nil
        if let activityObserver = activityObserver {
            DistributedNotificationCenter.default().removeObserver(activityObserver)
        }
        activityObserver = nil
        publish(rect: nil, pid: 0)
    }

    private func refreshAfterActivity() {
        guard isActive else { return }
        lastActivityAt = ProcessInfo.processInfo.systemUptime
        polling.noteActivity(at: lastActivityAt)
        if !refreshScheduled {
            refreshScheduled = true
            // Return the key to the client before querying its updated caret.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.refreshScheduled = false
                self.refresh()
            }
        }
    }

    private func refresh() {
        guard isActive else { return }
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
        let now = ProcessInfo.processInfo.systemUptime
        // Send movement immediately; unchanged geometry only needs a freshness heartbeat.
        guard (rect == nil && !pending) || rect != lastPublishedRect || pid != lastPublishedPID ||
            pending != lastPublishedPending || now - lastPublishedAt >= 0.25
        else { return }
        lastPublishedRect = rect
        lastPublishedPID = pid
        lastPublishedAt = now
        lastPublishedPending = pending
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: sourceID,
            userInfo: [
                "session": session,
                "pid": Int(pid),
                "uptime": now,
                "rect": rect.map(NSStringFromRect) ?? "",
                "pending": pending,
                "focusID": focusID,
            ],
            deliverImmediately: true
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        server = IMKServer(name: "dev_inputsourcepro_PaletteControl_Connection", bundleIdentifier: sourceID)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
