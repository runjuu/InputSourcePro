import Cocoa
import Combine
import SwiftUI
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

    private var lastURLActionAt: Date?
    private var pendingPreferencesOpen: DispatchWorkItem?
    static let urlActivationSuppressionWindow: TimeInterval = 2
    static let urlActivationGrace: TimeInterval = 0.35

    static func shouldSuppressPreferences(
        lastURLActionAt: Date?,
        now: Date,
        window: TimeInterval = urlActivationSuppressionWindow
    ) -> Bool {
        guard let last = lastURLActionAt else { return false }
        let elapsed = now.timeIntervalSince(last)
        return elapsed >= 0 && elapsed < window
    }

    @MainActor
    var isUserInitiatedUpdateSessionInProgress: Bool {
        preferencesVM?.isUserInitiatedUpdateSessionInProgress ?? false
    }

    @MainActor
    var updateCheckGeneration: Int {
        preferencesVM?.updateCheckGeneration ?? 0
    }

    func applicationDidFinishLaunching(_: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        // Global AX timeout (system default is seconds-long): a hung frontmost app must not freeze every synchronous AX read on the main thread.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)

        feedbackVM = FeedbackVM()
        navigationVM = NavigationVM()
        permissionsVM = PermissionsVM()
        preferencesVM = PreferencesVM(permissionsVM: permissionsVM)
        CaretHelperManager.shared.configure(preferences: preferencesVM, permissions: permissionsVM)
        applicationVM = ApplicationVM(preferencesVM: preferencesVM)
        inputSourceVM = InputSourceVM(preferencesVM: preferencesVM)
        indicatorVM = IndicatorVM(permissionsVM: permissionsVM, preferencesVM: preferencesVM, applicationVM: applicationVM, inputSourceVM: inputSourceVM)

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
        openPreferencesAtFirstLaunch(
            previousBuildVersion: preferencesVM.preferences.prevInstalledBuildVersion,
            currentBuildVersion: preferencesVM.preferences.buildVersion
        )
        sendLaunchPing()
        updateInstallVersionInfo()

        isReadyForURLs = true
        let queuedURLs = pendingURLs
        pendingURLs.removeAll()
        queuedURLs.forEach(handleIncomingURL)
    }

    func applicationDidBecomeActive(_: Notification) {
        guard !InputSourceSwitcher.isHandlingTemporaryInputWindowActivation else { return }
        // Sparkle activates the app for its dialogs. Check before scheduling so
        // dismissing an update dialog during the grace period cannot open Settings.
        guard !isUserInitiatedUpdateSessionInProgress else { return }
        let updateCheckGeneration = self.updateCheckGeneration

        // URL opens can activate the app before delivering the URL action.
        pendingPreferencesOpen?.cancel()
        let openPreferences = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPreferencesOpen = nil
            guard !self.isUserInitiatedUpdateSessionInProgress else { return }
            // A check may have started and finished while this activation was pending.
            guard self.updateCheckGeneration == updateCheckGeneration else { return }
            guard !Self.shouldSuppressPreferences(lastURLActionAt: self.lastURLActionAt, now: Date()) else { return }
            self.openPreferences()
        }
        pendingPreferencesOpen = openPreferences
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.urlActivationGrace, execute: openPreferences)
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        pendingPreferencesOpen?.cancel()
        pendingPreferencesOpen = nil
        openPreferences()
        return false
    }

    /// Handles `inputsourcepro://` URLs delivered by `open` (e.g. for CLI-driven
    /// config import). AppKit calls this on the main thread for both already-running
    /// and freshly-launched instances.
    func application(_: NSApplication, open urls: [URL]) {
        urls.forEach(handleIncomingURL)
    }

    @MainActor
    func openPreferencesAtFirstLaunch(previousBuildVersion: Int, currentBuildVersion: Int) {
        if previousBuildVersion != currentBuildVersion {
            openPreferences()
        }
    }

    @MainActor
    func openPreferences() {
        statusItemController?.openPreferences()
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

        lastURLActionAt = Date()

        guard isReadyForURLs else {
            pendingURLs.append(url)
            return
        }

        switch action {
        case .unsupported:
            break
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
