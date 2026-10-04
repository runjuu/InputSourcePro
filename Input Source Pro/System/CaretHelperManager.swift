import AppKit
import Combine

@MainActor
final class CaretHelperManager: ObservableObject {
    static let shared = CaretHelperManager()

    struct Status: Decodable, Equatable {
        var installed = false
        var registered = false
        var enabled = false
        var selected = false
        var legacyInstalled: Bool?
        var isReady: Bool { installed && registered && enabled }
        var hasRemovableHelpers: Bool { installed || legacyInstalled == true }
    }

    enum Operation: Equatable {
        case installing, permission, activating, removing
        var title: String {
            switch self {
            case .installing: return "Installing helper…"
            case .permission: return "Waiting for permission…"
            case .activating: return "Starting cursor support…"
            case .removing: return "Uninstalling helper…"
            }
        }
    }

    @Published private(set) var status = Status()
    @Published private(set) var operation: Operation?
    @Published private(set) var error: String?
    @Published private(set) var isActive = false
    private var enhancedMode = false
    private var accessibilityAllowed = false
    private var subscriptions = Set<AnyCancellable>()
    private var configured = false
    private var runningProcess: Process?
    private var refreshTask: Task<Void, Never>?
    private var setupCancelled = false
    private var revision = 0
    private let command: (([String]) async throws -> String)?
    private let helperURL: URL?
    private let installedURL: URL?
    private let startTracking: @MainActor () -> Bool
    private let stopTracking: @MainActor () -> Void

    var isBusy: Bool { operation != nil }
    var canActivate: Bool { enhancedMode && accessibilityAllowed }

    init(command: (([String]) async throws -> String)? = nil,
         helperURL: URL? = nil, installedURL: URL? = nil,
         startTracking: @escaping @MainActor () -> Bool = { CaretPalette.shared.start(); return CaretPalette.shared.isEnabled },
         stopTracking: @escaping @MainActor () -> Void = { CaretPalette.shared.stop() }) {
        self.command = command
        self.helperURL = helperURL
        self.installedURL = installedURL
        self.startTracking = startTracking
        self.stopTracking = stopTracking
    }

    func configure(preferences: PreferencesVM, permissions: PermissionsVM) {
        guard !configured, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        configured = true
        CaretPalette.shared.resumeSource = { [weak self] in
            Task { await self?.resume() }
        }
        preferences.$preferences.map(\.isEnhancedModeEnabled)
            .combineLatest(permissions.$isAccessibilityEnabled)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] enhanced, allowed in
                guard let self = self else { return }
                self.updateAvailability(enhanced: enhanced, allowed: allowed)
                Task { await self.restore() }
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { await self?.refresh() } }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.stopSourceOnExit() }
            .store(in: &subscriptions)
    }

    func updateAvailability(enhanced: Bool, allowed: Bool) {
        enhancedMode = enhanced
        accessibilityAllowed = allowed
        if !canActivate {
            stopTracking()
            isActive = false
            Task {
                guard !canActivate, !isBusy else { return }
                do { _ = try await run(["stop"]) }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    func refresh() async {
        if let refreshTask = refreshTask {
            await refreshTask.value
            return
        }
        guard !isBusy else { return }
        let task = Task { await self.refreshStatus() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func refreshStatus() async {
        guard !isBusy else { return }
        let requestedRevision = revision
        do {
            let newStatus = try await readStatus()
            guard !isBusy, requestedRevision == revision else { return }
            status = newStatus
            if !status.isReady || !status.selected {
                stopTracking()
                isActive = false
            }
            if status.isReady, canActivate, !isActive, error == nil, !setupCancelled {
                await activate(allowPermission: false)
            }
        } catch {
            if requestedRevision == revision { self.error = error.localizedDescription }
        }
    }

    func setup(reopenSettings: Bool = false) async {
        await activate(allowPermission: true, reopenSettings: reopenSettings)
    }

    func cancelPermissionRequest() {
        guard operation == .permission else { return }
        setupCancelled = true
        runningProcess?.terminate()
    }

    func restore() async {
        await refresh()
    }

    private func activate(allowPermission: Bool, reopenSettings: Bool = false) async {
        guard !isBusy, canActivate else { return }
        error = nil
        setupCancelled = false
        revision += 1
        operation = .activating
        defer { operation = nil }
        do {
            status = try await readStatus()
            let helper = try bundledHelper()
            let installed = installedURL ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Input Methods/ISP Palette Control.app")
            if !status.installed || !Self.sameVersion(helper, installed) {
                // Automatic activation must never reinstall a removed helper.
                guard status.installed || allowPermission else {
                    throw Failure("The cursor helper is missing. Choose Set up to install it again.")
                }
                operation = .installing
                stopTracking()
                isActive = false
                _ = try await run(["install", helper.path])
                status = try await readStatus()
            }
            if !status.enabled {
                guard allowPermission else {
                    throw Failure("Cursor support needs permission. Choose Set up to allow the helper.")
                }
                operation = .permission
                _ = try await run(reopenSettings ? ["authorize", "--reopen-settings"] : ["authorize"])
                guard !setupCancelled else { return }
                status = try await readStatus()
            }
            guard canActivate, status.isReady else {
                throw Failure("Cursor support could not start. Check Enhanced Mode and the helper permission, then try again.")
            }
            operation = .activating
            _ = try await run(["start"])
            status = try await readStatus()
            guard canActivate, status.isReady, status.selected else {
                throw Failure("The cursor helper could not start. Try again.")
            }
            let started = startTracking()
            guard canActivate, started, status.selected else {
                throw Failure("The cursor helper could not start. Try again.")
            }
            isActive = true
        } catch {
            stopTracking()
            isActive = false
            if !setupCancelled { self.error = error.localizedDescription }
            do { _ = try await run(["stop"]) }
            catch { if self.error == nil && !setupCancelled { self.error = error.localizedDescription } }
            if let current = try? await readStatus() { status = current }
        }
    }

    private func resume() async {
        guard canActivate, !isBusy else { return }
        revision += 1
        operation = .activating
        defer { operation = nil }
        do {
            status = try await readStatus()
            guard status.isReady else { throw Failure("Cursor support needs permission. Choose Set up to allow the helper.") }
            if !status.selected { _ = try await run(["start"]) }
            status = try await readStatus()
            isActive = status.selected && canActivate
            if !isActive { stopTracking() }
        } catch {
            stopTracking()
            isActive = false
            self.error = error.localizedDescription
        }
    }

    private func stopSourceOnExit() {
        guard isActive else { return }
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CaretPalette/setup")
        process.arguments = ["stop"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { NSLog("Could not stop cursor helper: %@", error.localizedDescription) }
    }

    func uninstall() async {
        guard !isBusy else { return }
        operation = .removing
        revision += 1
        error = nil
        stopTracking()
        isActive = false
        defer { operation = nil }
        do {
            _ = try await run(["uninstall"])
            status = try await readStatus()
            guard !status.hasRemovableHelpers else { throw Failure("The helper could not be removed. Try again.") }
        } catch {
            self.error = error.localizedDescription
            if let current = try? await readStatus() { status = current }
        }
    }

    static func sameVersion(_ first: URL, _ second: URL) -> Bool {
        // Build-generated source fingerprint also detects updates within a single app version.
        guard let firstInfo = NSDictionary(contentsOf: first.appendingPathComponent("Contents/Info.plist")),
              let secondInfo = NSDictionary(contentsOf: second.appendingPathComponent("Contents/Info.plist")),
              let version = firstInfo["ISPCaretBuild"] as? String else { return false }
        return version == secondInfo["ISPCaretBuild"] as? String
    }

    private func bundledHelper() throws -> URL {
        let url = helperURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CaretPalette/ISP Palette Control.app")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure("This copy of the app is missing its cursor helper. Reinstall the app and try again.")
        }
        return url
    }

    private func readStatus() async throws -> Status {
        try JSONDecoder().decode(Status.self, from: Data(try await run(["status", "--json"]).utf8))
    }

    private func run(_ arguments: [String]) async throws -> String {
        if let command = command { return try await command(arguments) }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CaretPalette/setup")
        let process = Process()
        let pipe = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = errors
        try process.run()
        runningProcess = process
        defer { if runningProcess === process { runningProcess = nil } }
        return try await Task.detached(priority: .userInitiated) {
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: diagnostics, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationReason == .uncaughtSignal {
                    throw Failure("The cursor setup tool stopped unexpectedly (signal \(process.terminationStatus)). Close and reopen the app, then try again.")
                }
                throw Failure(detail.isEmpty ? "The cursor helper could not complete this action. Try again." : detail)
            }
            return message
        }.value
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }
}
