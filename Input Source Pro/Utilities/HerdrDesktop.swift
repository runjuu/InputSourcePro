import AppKit
import Combine

/// The bundled Herdr mod reports the terminal actually shown, including a
/// sub-agent swapped into an existing pane. It runs only while Herdr is watched.
enum HerdrDesktop {
    struct Focus: Codable, Equatable {
        let pane: String?
        let terminal: String?
        var pid: pid_t?
    }

    private struct Report: Decodable {
        let token: String
        let focus: Focus
    }

    static let modName = "input-source-pro"
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/herdr-app")
    private static let bridgeQueue = DispatchQueue(label: "dev.inputsourcepro.herdr-mod", qos: .utility)
    private static let localBin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")

    private static func appCommand(_ arguments: [String]) -> String? {
        let path = NSRunningApplication.runningApplications(withBundleIdentifier: Terminal.herdr.rawValue).first?.executableURL?.path
            ?? localBin.appendingPathComponent("herdr-app").path
        return TerminalProcess.output(of: path, arguments: arguments)
    }

    /// Install into our own mod directory. Stage the first install so Herdr
    /// never discovers a half-installed mod. Never replace another mod.
    static func install(from resource: URL, into mods: URL) throws {
        let fm = FileManager.default
        let target = mods.appendingPathComponent(modName)
        let marker = "dev.inputsourcepro.herdr-mod"
        try fm.createDirectory(at: mods, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: target.path) {
            let staging = mods.deletingLastPathComponent().appendingPathComponent(".isp-mod-" + UUID().uuidString)
            try fm.copyItem(at: resource, to: staging)
            defer { try? fm.removeItem(at: staging) }
            try Data().write(to: staging.appendingPathComponent(marker))
            try fm.moveItem(at: staging, to: target)
            return
        }
        guard (try target.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
              fm.fileExists(atPath: target.appendingPathComponent(marker).path)
        else { throw CocoaError(.fileWriteFileExists) }
        for file in ["mod.json", "main.js"] {
            let destination = target.appendingPathComponent(file)
            let bytes = try Data(contentsOf: resource.appendingPathComponent(file))
            if (try? Data(contentsOf: destination)) != bytes { try bytes.write(to: destination, options: .atomic) }
        }
    }

    /// Shared state is persisted across launches. Only a report answering
    /// this watch (or this command probe) establishes keyboard focus.
    static func report(in data: Data, key: String, token: String) -> Focus? {
        struct Shared: Decodable {
            let watch: Report?
            let query: Report?
            enum CodingKeys: String, CodingKey {
                case watch = "input-source-pro.watch"
                case query = "input-source-pro.query"
            }
        }
        guard let shared = try? JSONDecoder().decode(Shared.self, from: data) else { return nil }
        let result = key == "watch" ? shared.watch : shared.query
        return result?.token == token ? result?.focus : nil
    }

    private static func report(_ key: String, token: String) -> Focus? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("shared.json")) else { return nil }
        return report(in: data, key: key, token: token)
    }

    static func queryFocus() -> Focus? {
        let token = UUID().uuidString
        guard appCommand(["do", modName + ".query-" + token]) != nil else { return nil }
        // Herdr queues mod commands and atomically saves shared state off its UI thread.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        repeat {
            if let focus = report("query", token: token) { return focus }
            Thread.sleep(forTimeInterval: 0.01)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return nil
    }

    static func watch(_ send: @escaping (Focus?) -> Void) -> AnyCancellable? {
        guard let resource = Bundle.main.url(forResource: modName, withExtension: nil) else { return nil }
        let token = UUID().uuidString
        let flag = CancelFlag()
        let timer = DispatchSource.makeTimerSource(queue: bridgeQueue)
        // State confined to bridgeQueue, including cleanup before a subsequent watch.
        var observation: AnyCancellable?
        var installed = false
        var activated = false
        let read = { report("watch", token: token) }
        timer.setEventHandler {
            guard !flag.isCancelled else { return }
            if !installed {
                do {
                    try install(from: resource, into: directory.appendingPathComponent("mods"))
                    installed = true
                } catch {
                    IndicatorDiagnostics.record("terminal.herdr mod install failed: \(error)")
                    return
                }
            }
            if observation == nil {
                observation = TerminalWatcher.Environment.watchDirectory(directory.path, read: read) { value in
                    if !flag.isCancelled { send(value) }
                }
            }
            guard read() == nil else { return }
            // mod.open toggles. Ask for a snapshot first to reuse an existing copy.
            let subscribe = ["do", modName + ".watch-" + token]
            if appCommand(subscribe) != nil { activated = true; return }
            struct Status: Decodable { let overlays: [String?] }
            guard let status = appCommand(["status"]),
                  let state = try? JSONDecoder().decode(Status.self, from: Data(status.utf8)),
                  !state.overlays.contains(modName), !flag.isCancelled,
                  appCommand(["do", "mod.open", "--name", modName]) != nil else { return }
            activated = true
            _ = appCommand(subscribe)
        }
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(200))
        timer.resume()
        return AnyCancellable {
            flag.cancel()
            timer.cancel()
            bridgeQueue.async {
                observation?.cancel()
                if activated { _ = appCommand(["do", "overlay.close", "--id", "mod-" + modName]) }
            }
        }
    }
}
