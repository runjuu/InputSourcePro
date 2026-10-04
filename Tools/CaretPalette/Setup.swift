import Cocoa
import Carbon
import Darwin

private let sourceID = "com.runjuu.Input-Source-Pro.inputmethod.PaletteControl"
private let appName = "ISP Palette Control.app"
private let destination = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Input Methods/\(appName)")

private struct SetupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func source() -> TISInputSource? {
    CaretInputSource.find(sourceID)
}

private func flag(_ key: CFString) -> Bool {
    guard let source = source() else { return false }
    return TISGetInputSourceProperty(source, key) == Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
}

private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw SetupError(message: "\(operation) failed (OSStatus \(status)).") }
}

private func wait(_ seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

private func status(json: Bool = false) {
    if json {
        let values = ["installed": FileManager.default.fileExists(atPath: destination.path),
                      "registered": source() != nil, "enabled": flag(kTISPropertyInputSourceIsEnabled),
                      "selected": flag(kTISPropertyInputSourceIsSelected)]
        let data = try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        return
    }
    print("Installed: \(FileManager.default.fileExists(atPath: destination.path))")
    print("Registered: \(source() != nil)")
    print("Enabled: \(flag(kTISPropertyInputSourceIsEnabled))")
    print("Selected: \(flag(kTISPropertyInputSourceIsSelected))")
}

private func verify(_ app: URL) throws {
    guard Bundle(url: app)?.bundleIdentifier == sourceID,
          FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/CaretControl").path)
    else { throw SetupError(message: "Not an ISP caret palette bundle: \(app.path)") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["--verify", "--strict", app.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw SetupError(message: "The helper's code signature is invalid.") }
}

private func install(_ builtApp: URL) throws {
    try verify(builtApp)
    let manager = FileManager.default
    let parent = destination.deletingLastPathComponent()
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    if manager.fileExists(atPath: destination.path) {
        guard Bundle(url: destination)?.bundleIdentifier == sourceID else {
            throw SetupError(message: "A different app occupies \(destination.path); it was not replaced.")
        }
    }
    let stage = parent.appendingPathComponent(".isp-caret-install-\(UUID().uuidString).app")
    try manager.copyItem(at: builtApp, to: stage)
    defer { try? manager.removeItem(at: stage) }
    try verify(stage)
    let wasSelected = flag(kTISPropertyInputSourceIsSelected)
    if let source = source(), wasSelected { try check(TISDeselectInputSource(source), "Deselect") }
    defer {
        if wasSelected, flag(kTISPropertyInputSourceIsEnabled), let source = source() {
            let result = TISSelectInputSource(source)
            if result != noErr { fputs("Could not reselect the palette (\(result)). Run setup start.\n", stderr) }
        }
    }
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: sourceID) {
        guard app.terminate() else { throw SetupError(message: "Quit ISP Palette Control before installing.") }
        let deadline = Date().addingTimeInterval(3)
        while !app.isTerminated && Date() < deadline { wait(0.1) }
        guard app.isTerminated else { throw SetupError(message: "The helper is still running; installation stopped.") }
    }
    let backup: URL?
    if manager.fileExists(atPath: destination.path) {
        let backupDirectory = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/InputSourcePro/CaretPaletteBackups/\(UUID().uuidString)")
        backup = backupDirectory.appendingPathComponent(appName)
    } else {
        backup = nil
    }
    try CaretHelperFiles.install(staged: stage, destination: destination, backup: backup) { url in
        try check(TISRegisterInputSource(url as CFURL), "Registration")
        guard source() != nil else {
            throw SetupError(message: "macOS has not registered the cursor helper. Sign out and back in, then try again.")
        }
    }
    if let backup = backup { print("Previous helper saved at \(backup.path)") }
    print("Installed \(destination.path)")
}

private func uninstall() throws {
    let manager = FileManager.default
    let backups = manager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/InputSourcePro/CaretPaletteBackups")
    let bundles = try CaretHelperFiles.removalCandidates(destination: destination, backups: backups)
    if let source = source() {
        if flag(kTISPropertyInputSourceIsSelected) { try check(TISDeselectInputSource(source), "Deselect") }
        if flag(kTISPropertyInputSourceIsEnabled) { try check(TISDisableInputSource(source), "Disable") }
    }
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: sourceID) {
        guard app.terminate() else { throw SetupError(message: "The cursor helper could not quit. Try again.") }
        let deadline = Date().addingTimeInterval(3)
        while !app.isTerminated && Date() < deadline { wait(0.1) }
        guard app.isTerminated else { throw SetupError(message: "The cursor helper is still running. Try again.") }
    }
    for bundle in bundles {
        try manager.removeItem(at: bundle)
        // Only remove an empty installer-created backup directory.
        let parent = bundle.deletingLastPathComponent()
        if parent.path != destination.deletingLastPathComponent().path,
           try manager.contentsOfDirectory(atPath: parent.path).isEmpty {
            try manager.removeItem(at: parent)
        }
    }
    guard !manager.fileExists(atPath: destination.path),
          NSRunningApplication.runningApplications(withBundleIdentifier: sourceID).isEmpty else {
        throw SetupError(message: "The helper could not be fully removed. Try again.")
    }
    refreshInputMenu()
    print("Cursor helper uninstalled.")
}

private func refreshInputMenu() {
    // The menu agent can retain palette rows after removal or visibility changes.
    // macOS relaunches it on demand with the current input-source list.
    let executable = "/System/Library/CoreServices/TextInputMenuAgent.app/Contents/MacOS/TextInputMenuAgent"
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextInputMenuAgent") {
        guard app.executableURL?.path == executable else { continue }
        if kill(app.processIdentifier, SIGTERM) != 0 && errno != ESRCH {
            fputs("The input menu could not refresh. Sign out and back in if the helper's old entry remains.\n", stderr)
        }
    }
}

private func authorize(reopenSettings: Bool, checkOnly: Bool) throws {
    guard let source = source() else { throw SetupError(message: "Install the helper first.") }
    if !checkOnly && flag(kTISPropertyInputSourceIsEnabled) {
        print("Already enabled; no permission request needed.")
        return
    }
    typealias Flatten = @convention(c) (TISInputSource, UnsafeMutablePointer<Unmanaged<CFDictionary>?>) -> Bool
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CreateFlattenedInputSource") else {
        throw SetupError(message: "This macOS version does not expose the required permission-request API.")
    }
    let flatten = unsafeBitCast(symbol, to: Flatten.self)
    var result: Unmanaged<CFDictionary>?
    guard flatten(source, &result), let result = result else {
        throw SetupError(message: "macOS could not create the input-source permission descriptor.")
    }
    let descriptor = result.takeRetainedValue()
    let payload: [String: Any] = [
        "tabID": "com.apple.IntlKeyboard",
        "inputSourceToBeEnabled": descriptor,
        "localizedSenderName": "Input Source Pro",
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
    if checkOnly {
        guard let unflattenSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CreateUnflattenedInputSource") else {
            throw SetupError(message: "Cannot validate the permission descriptor on this macOS version.")
        }
        typealias Unflatten = @convention(c) (CFDictionary) -> Unmanaged<TISInputSource>?
        let unflatten = unsafeBitCast(unflattenSymbol, to: Unflatten.self)
        guard let roundTrip = unflatten(descriptor)?.takeRetainedValue(),
              let idPointer = TISGetInputSourceProperty(roundTrip, kTISPropertyInputSourceID),
              Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String == sourceID
        else { throw SetupError(message: "The consent descriptor did not round-trip to this helper.") }
        print("Permission descriptor validated; no Settings changes made.")
        return
    }
    if reopenSettings {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences") {
            guard app.terminate() else { throw SetupError(message: "Close System Settings and try again.") }
            let deadline = Date().addingTimeInterval(4)
            while !app.isTerminated && Date() < deadline { wait(0.1) }
            guard app.isTerminated else { throw SetupError(message: "System Settings is still running. Close it and try again.") }
        }
    }
    let parameters = NSAppleEventDescriptor.list()
    guard let pane = NSAppleEventDescriptor(descriptorType: 0x70726566,
        data: Data("com.apple.Keyboard-Settings.extension".utf8)),
        let payloadDescriptor = NSAppleEventDescriptor(descriptorType: 0x70747275, data: data)
    else { throw SetupError(message: "Could not encode the Settings request.") }
    parameters.insert(pane, at: 1)
    parameters.insert(payloadDescriptor, at: 2)
    let settingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app") as CFURL
    var specification = LSLaunchURLSpec(appURL: .passUnretained(settingsURL), itemURLs: nil,
        passThruParams: parameters.aeDesc, launchFlags: [.defaults, .dontAddToRecents], asyncRefCon: nil)
    let launchStatus = withExtendedLifetime((settingsURL, parameters)) {
        LSOpenFromURLSpec(&specification, nil)
    }
    try check(launchStatus, "Open native permission request")
    print("Approve the native Allow dialog in System Settings. Waiting up to 30 seconds…")
    fflush(stdout)
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        wait(0.25)
        if flag(kTISPropertyInputSourceIsEnabled) {
            print("macOS reports the palette enabled. Run setup status in a fresh process to verify persistence.")
            return
        }
    }
    throw SetupError(message: "Permission has not been enabled. If the Allow dialog did not appear, close System Settings and try again. The helper stays off until permission is granted.")
}

@main
enum CaretSetupCommand {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            switch arguments.first {
            case "install":
                guard arguments.count == 2 else { throw SetupError(message: "Usage: setup install <built .app path>") }
                try install(URL(fileURLWithPath: arguments[1]).standardizedFileURL)
                status()
            case "authorize":
                guard arguments.count == 1 || arguments == ["authorize", "--reopen-settings"] || arguments == ["authorize", "--check-request"] else {
                    throw SetupError(message: "Usage: setup authorize [--reopen-settings | --check-request]")
                }
                try authorize(reopenSettings: arguments.contains("--reopen-settings"), checkOnly: arguments.contains("--check-request"))
            case "status": status(json: arguments.contains("--json"))
            case "uninstall": try uninstall()
            case "start":
                guard let source = source(), flag(kTISPropertyInputSourceIsEnabled) else {
                    throw SetupError(message: "Run setup authorize first.")
                }
                try check(TISSelectInputSource(source), "Select")
                guard flag(kTISPropertyInputSourceIsSelected) else { throw SetupError(message: "macOS did not select the palette.") }
                status()
            case "stop":
                if let source = source(), flag(kTISPropertyInputSourceIsSelected) { try check(TISDeselectInputSource(source), "Deselect") }
                status()
            default:
                throw SetupError(message: "Usage: setup install <app> | authorize [--reopen-settings | --check-request] | status [--json] | start | stop | uninstall")
            }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
