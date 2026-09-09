import Cocoa
import Alamofire
import LaunchAtLogin

class AppDelegate: NSObject, NSApplicationDelegate {
    var navigationVM: NavigationVM!
    var indicatorVM: IndicatorVM!
    var preferencesVM: PreferencesVM!
    var permissionsVM: PermissionsVM!
    var applicationVM: ApplicationVM!
    var inputSourceVM: InputSourceVM!
    var feedbackVM: FeedbackVM!
    var indicatorWindowController: IndicatorWindowController!
    var statusItemController: StatusItemController!

    /// `false` until the view models are ready in `applicationDidFinishLaunching`.
    /// URLs that arrive before then are queued in `pendingURLs` and drained once.
    private var isReadyForURLs = false
    private var pendingURLs: [URL] = []

    /// Timestamp of the most recent `inputsourcepro://` action. An activation that
    /// lands within `urlActivationSuppressionWindow` of it is the foregrounding
    /// `open` triggers, so it must not also pop Preferences. A timestamp (vs. a
    /// one-shot flag) auto-expires — it can't linger and swallow a later genuine
    /// activation — and it absorbs every activation in the same `open` burst.
    private var lastURLActionAt: Date?

    /// How recently a URL action must have happened for an activation to be
    /// attributed to it.
    static let urlActivationSuppressionWindow: TimeInterval = 2

    /// `open <url>` activates the app a beat *before* it delivers the URL, so the
    /// activation handler waits this long before deciding whether to open
    /// Preferences — giving an incoming URL action time to arrive and cancel it.
    static let urlActivationGrace: TimeInterval = 0.35

    /// Whether an activation observed at `now` should be attributed to a URL
    /// action at `lastURLActionAt` (and so skip opening Preferences). Pure, so the
    /// window logic can be unit-tested without driving the AppKit lifecycle.
    static func shouldSuppressPreferences(
        lastURLActionAt: Date?,
        now: Date,
        window: TimeInterval = urlActivationSuppressionWindow
    ) -> Bool {
        guard let last = lastURLActionAt else { return false }
        let elapsed = now.timeIntervalSince(last)
        return elapsed >= 0 && elapsed < window
    }

    private var accessibilityWaitTimer: Timer?
    private var accessibilityWaitingStatusItem: NSStatusItem?
    private var suppressPreferencesFromAccessibilityFlow = false

    func applicationDidFinishLaunching(_: Notification) {
        feedbackVM = FeedbackVM()
        navigationVM = NavigationVM()
        permissionsVM = PermissionsVM()
        preferencesVM = PreferencesVM(permissionsVM: permissionsVM)

        if PermissionsVM.checkAccessibility(prompt: false) {
            permissionsVM.isAccessibilityEnabled = true
            bootstrapAppServices()
        } else {
            ISPFileLog.startSession()
            ISPFileLog.event(
                "boot",
                "blocked — Accessibility not granted path=\(Bundle.main.bundleURL.path)",
                includeSnapshot: false
            )
            showAccessibilityRequiredAlert()
        }
    }

    @MainActor
    private func showAccessibilityRequiredAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Accessibility Required Title".i18n()
        alert.informativeText =
            "Input Source Pro needs Accessibility to switch and remember keyboard layouts. Without this permission the app will not start.\n\nOpen System Settings → Privacy & Security → Accessibility, enable Input Source Pro, then return — or Quit."
        alert.addButton(withTitle: "Open Accessibility Settings".i18n())
        alert.addButton(withTitle: "Quit".i18n())

        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            suppressPreferencesFromAccessibilityFlow = true
            NSWorkspace.shared.openAccessibilityPreferences()
            showAccessibilityWaitingStatusItem()
            waitForAccessibilityThenBootstrap()
        } else {
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private func showAccessibilityWaitingStatusItem() {
        guard accessibilityWaitingStatusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(named: "MenuBarIcon")
        item.button?.image?.size = NSSize(width: 16, height: 16)
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(
                title: "Open Accessibility Settings".i18n(),
                target: self,
                action: #selector(reopenAccessibilitySettings),
                keyEquivalent: ""
            )
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit".i18n(),
                action: #selector(NSApplication.shared.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        item.menu = menu
        accessibilityWaitingStatusItem = item
    }

    @MainActor
    private func removeAccessibilityWaitingStatusItem() {
        guard let item = accessibilityWaitingStatusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        accessibilityWaitingStatusItem = nil
    }

    @objc private func reopenAccessibilitySettings() {
        NSWorkspace.shared.openAccessibilityPreferences()
    }

    @MainActor
    private func bootstrapAppServices() {
        guard applicationVM == nil else { return }

        accessibilityWaitTimer?.invalidate()
        accessibilityWaitTimer = nil
        removeAccessibilityWaitingStatusItem()

        applicationVM = ApplicationVM(preferencesVM: preferencesVM)
        inputSourceVM = InputSourceVM(preferencesVM: preferencesVM)
        indicatorVM = IndicatorVM(
            permissionsVM: permissionsVM,
            preferencesVM: preferencesVM,
            applicationVM: applicationVM,
            inputSourceVM: inputSourceVM
        )

        indicatorWindowController = IndicatorWindowController(
            permissionsVM: permissionsVM,
            preferencesVM: preferencesVM,
            indicatorVM: indicatorVM,
            applicationVM: applicationVM,
            inputSourceVM: inputSourceVM
        )

        statusItemController = StatusItemController(
            navigationVM: navigationVM,
            permissionsVM: permissionsVM,
            preferencesVM: preferencesVM,
            applicationVM: applicationVM,
            indicatorVM: indicatorVM,
            feedbackVM: feedbackVM,
            inputSourceVM: inputSourceVM
        )

        LaunchAtLogin.migrateIfNeeded()
        ISPFileLog.startSession()
        preferencesVM.logStartupSettings()
        if !suppressPreferencesFromAccessibilityFlow {
            openPreferencesAtFirstLaunch()
        }
        sendLaunchPing()
        updateInstallVersionInfo()

        isReadyForURLs = true
        let queuedURLs = pendingURLs
        pendingURLs.removeAll()
        queuedURLs.forEach(handleIncomingURL)

        clearAccessibilityPreferencesSuppressionSoon()
    }

    @MainActor
    private func waitForAccessibilityThenBootstrap() {
        accessibilityWaitTimer?.invalidate()
        // Target/selector avoids capturing non-Sendable `self` in a @Sendable Timer closure.
        let timer = Timer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(accessibilityWaitTick),
            userInfo: nil,
            repeats: true
        )
        accessibilityWaitTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor
    @objc private func accessibilityWaitTick() {
        guard applicationVM == nil else {
            accessibilityWaitTimer?.invalidate()
            accessibilityWaitTimer = nil
            return
        }
        guard PermissionsVM.checkAccessibility(prompt: false) else { return }
        accessibilityWaitTimer?.invalidate()
        accessibilityWaitTimer = nil
        permissionsVM.isAccessibilityEnabled = true
        ISPFileLog.event("boot", "Accessibility granted — starting", includeSnapshot: false)
        bootstrapAppServices()
        suppressPreferencesFromAccessibilityFlow = false
        statusItemController.openPreferences()
    }

    private func clearAccessibilityPreferencesSuppressionSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.suppressPreferencesFromAccessibilityFlow = false
        }
    }

    func applicationDidBecomeActive(_: Notification) {
        guard statusItemController != nil else { return }
        guard !suppressPreferencesFromAccessibilityFlow else { return }
        guard !InputSourceSwitcher.isHandlingTemporaryInputWindowActivation else { return }

        // `open <url>` activates the app a beat *before* it delivers the URL
        // (measured: AppKit calls this ~10–200ms ahead of `application(open:)`),
        // so we can't tell synchronously whether this is a genuine user
        // activation or the side effect of an incoming URL action. Defer by the
        // grace window; a URL action that lands in the meantime records its
        // timestamp and cancels the Preferences open.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.urlActivationGrace) { [weak self] in
            guard let self else { return }
            if Self.shouldSuppressPreferences(lastURLActionAt: self.lastURLActionAt, now: Date()) {
                return
            }
            self.statusItemController.openPreferences()
        }
    }

    /// Handles `inputsourcepro://` URLs delivered by `open` (e.g. for CLI-driven
    /// config import). AppKit calls this on the main thread for both already-running
    /// and freshly-launched instances.
    func application(_: NSApplication, open urls: [URL]) {
        urls.forEach(handleIncomingURL)
    }

    @MainActor
    func openPreferencesAtFirstLaunch() {
        if preferencesVM.preferences.prevInstalledBuildVersion != preferencesVM.preferences.buildVersion {
            statusItemController.openPreferences()
        }
    }

    @MainActor
    func updateInstallVersionInfo() {
        preferencesVM.preferences.prevInstalledBuildVersion = preferencesVM.preferences.buildVersion
    }
    
    @MainActor
    func sendLaunchPing() {
        let url = "https://inputsource.pro/api/launch"
        let launchData: [String: String] = [
            "prevInstalledBuildVersion": "\(preferencesVM.preferences.prevInstalledBuildVersion)",
            "shortVersion": Bundle.main.shortVersion,
            "buildVersion": "\(Bundle.main.buildVersion)",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        
        AF.request(
            url,
            method: .post,
            parameters: launchData,
            encoding: JSONEncoding.default
        )
        .response { response in
            switch response.result {
            case .success:
                print("Launch ping sent successfully.")
            case let .failure(error):
                print("Failed to send launch ping:", error)
            }
        }
    }

    @MainActor
    private func handleIncomingURL(_ url: URL) {
        let action = AppURLAction(url: url)
        guard action != .unsupported else { return }

        // `open` also activates the app; record the moment so the activation it
        // triggers doesn't also pop Preferences on top of the result alert. The
        // queued path re-enters here on drain, re-anchoring the window near the
        // alert.
        lastURLActionAt = Date()

        guard isReadyForURLs else {
            pendingURLs.append(url)
            return
        }

        switch action {
        case .unsupported:
            break // unreachable: guarded out above before activation was suppressed
        case .importInvalidPath:
            presentResultAlert(
                title: "Import Settings Failed".i18n(),
                message: "No valid file path was provided. Use an absolute path, e.g. inputsourcepro://import?path=/path/to/settings.json".i18n(),
                style: .critical
            )
        case let .importSettings(fileURL, silent):
            importSettings(from: fileURL, silent: silent)
        }
    }

    /// Imports a settings backup without the interactive confirmation the GUI
    /// uses — this path is meant for non-interactive provisioning. The current
    /// settings are backed up first so a bad import stays recoverable. When
    /// `silent` is `true` the success alert is skipped (for unattended runs), but
    /// a failure always alerts so it can't pass unnoticed.
    @MainActor
    private func importSettings(from fileURL: URL, silent: Bool) {
        do {
            let backup = try preferencesVM.readSettingsBackup(from: fileURL)
            backUpCurrentSettings()
            try preferencesVM.importSettingsBackup(backup)
            indicatorVM.refreshShortcut()
            guard !silent else { return }
            presentResultAlert(
                title: "Settings Imported".i18n(),
                message: "Settings Imported Message".i18n(),
                style: .informational
            )
        } catch {
            presentResultAlert(
                title: "Import Settings Failed".i18n(),
                message: error.localizedDescription,
                style: .critical
            )
        }
    }

    /// Best-effort snapshot of the current settings written to Application Support
    /// before a destructive import. Never blocks the import if it fails.
    @MainActor
    private func backUpCurrentSettings() {
        do {
            let data = try preferencesVM.exportSettingsBackupData()
            let directory = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Input Source Pro", isDirectory: true)
                .appendingPathComponent("Backups", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let fileURL = directory
                .appendingPathComponent("settings-backup-\(formatter.string(from: Date())).json")

            try data.write(to: fileURL, options: .atomic)
            pruneSettingsBackups(in: directory, keeping: 10)
        } catch {
            print("Failed to write pre-import settings backup: \(error.localizedDescription)")
        }
    }

    /// Keeps only the most recent `keeping` pre-import backups so they don't grow
    /// without bound. Best-effort: the timestamped `settings-backup-…json` names
    /// sort chronologically, so this is a lexicographic sort + trim of the tail.
    @MainActor
    private func pruneSettingsBackups(in directory: URL, keeping: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        let backups = files
            .filter { $0.lastPathComponent.hasPrefix("settings-backup-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for stale in backups.dropFirst(keeping) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    @MainActor
    private func presentResultAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
