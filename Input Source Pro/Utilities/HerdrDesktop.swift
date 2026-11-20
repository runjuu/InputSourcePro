import AppKit
import Combine

/// The bundled Herdr mod reports the terminal actually shown, including a
/// sub-agent swapped into an existing pane. It runs only while Herdr is watched.
enum HerdrDesktop {
    struct Focus: Codable, Equatable {
        let pane: String?
        let terminal: String?
        var pid: pid_t?
        var executable: String?
        var toast: String?
        var overlayTerminal: Bool?
    }

    private struct Report: Decodable {
        let token: String
        let focus: Focus
    }

    static let modName = "input-source-pro"
    private static let bridgeQueue = DispatchQueue(label: "dev.inputsourcepro.herdr-mod", qos: .utility)

    /// Each Herdr window serves one socket in its own HERDR_APP_HOME. Use the
    /// frontmost process's listener, including when several instances are open.
    struct Endpoint {
        let pid: pid_t
        let socket: URL
        var directory: URL { socket.deletingLastPathComponent() }

        static func resolve(pid: pid_t) -> Self? {
            let paths = TerminalProcess.unixSocketPaths(ofPID: pid, listening: true)
                .filter { $0.hasPrefix("/") && ($0 as NSString).lastPathComponent == "herdr-app.sock" }
            guard paths.count == 1, let path = paths.first else { return nil }
            return Self(pid: pid, socket: URL(fileURLWithPath: path))
        }

        /// Herdr's control protocol is one newline-delimited JSON request and reply.
        /// Check the connected process too, in case a new window reused the path.
        func request(_ payload: [String: Any]) -> Data? {
            TerminalWatcher.Environment.withUnixPeer(at: socket.path) { fd, peer in
                guard peer == pid else { return nil }
                return TerminalWatcher.Environment.jsonReply(to: payload, on: fd)
            }
        }

        func command(_ name: String, arguments: [String: String] = [:]) -> Bool {
            guard let reply = request(["do": name, "args": arguments]),
                  let result = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return false }
            return result["error"] == nil
        }

        func status() -> Status? {
            request(["status": true]).flatMap { try? JSONDecoder().decode(Status.self, from: $0) }
        }

        func report(_ key: String, token: String) -> Focus? {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("shared.json")) else { return nil }
            return HerdrDesktop.report(in: data, key: key, token: token)
        }
    }

    struct Status: Decodable {
        let overlays: [String?]
        var errors: [String]?
        var running: Bool { overlays.contains(modName) }
        var failed: Bool { errors?.contains { $0.hasPrefix("mod " + modName + ":") } == true }

        /// A mod dialog can own the keyboard while focused() still names the pane under it.
        func focus(_ reported: Focus?) -> Focus? {
            guard running && !failed else { return nil }
            if let top = overlays.last(where: { $0 != modName && $0 != (reported?.toast ?? "toast") }) {
                // A peek identifies its keyboard terminal directly. A dialog can leave
                // the model pane beneath it in focused() even while editing an input.
                guard top == "layout", reported?.overlayTerminal == true, overlays.filter({ $0 == "layout" }).count == 1 else {
                    return Focus(pane: nil, terminal: nil)
                }
            }
            return reported
        }
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

    static func queryFocus(pid: pid_t) -> Focus? {
        let token = UUID().uuidString
        guard let endpoint = Endpoint.resolve(pid: pid),
              endpoint.command(modName + ".query-" + token) else { return nil }
        // Mod commands are queued and shared state is saved off Herdr's UI thread.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        repeat {
            if let focus = endpoint.report("query", token: token) {
                return endpoint.status()?.focus(focus)
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return nil
    }

    static func watch(pid: pid_t, send: @escaping (Focus?) -> Void) -> AnyCancellable? {
        guard let resource = Bundle.main.url(forResource: modName, withExtension: nil) else { return nil }
        let flag = CancelFlag()
        let timer = DispatchSource.makeTimerSource(queue: bridgeQueue)
        // Confined to bridgeQueue. Checking status also detects overlay changes
        // which Herdr doesn't publish to mods or write into shared.json.
        var endpoint: Endpoint?
        var token = UUID().uuidString
        var observation: AnyCancellable?
        var installed = false
        var activated = false
        var last: Focus?
        func publish(_ focus: Focus?) {
            guard focus != last else { return }
            last = focus
            DispatchQueue.main.async { if !flag.isCancelled { send(focus) } }
        }
        var nextAttempt: TimeInterval = 0
        var nextRenewal: TimeInterval = 0
        timer.setEventHandler {
            guard !flag.isCancelled else { return }
            if endpoint == nil { endpoint = Endpoint.resolve(pid: pid) }
            guard let endpoint, let status = endpoint.status() else { publish(nil); return }
            if !status.running || !installed {
                publish(nil)
                let now = ProcessInfo.processInfo.systemUptime
                guard now >= nextAttempt else { return }
                nextAttempt = now + 2
                if !installed {
                    do {
                        try install(from: resource, into: endpoint.directory.appendingPathComponent("mods"))
                        installed = true
                    } catch {
                        IndicatorDiagnostics.record("terminal.herdr mod install failed: \(error)")
                        return
                    }
                }
                if !status.running {
                    observation = nil
                    token = UUID().uuidString
                    guard !flag.isCancelled, endpoint.command("mod.open", arguments: ["name": modName]) else { return }
                }
                activated = true
            }
            guard !status.failed else { publish(nil); return }
            if observation == nil {
                // Directory notifications follow Herdr's atomic file replacements. Read
                // the nonce captured by this observation, and discard superseded watches.
                let observedToken = token
                observation = TerminalWatcher.Environment.watchDirectory(
                    endpoint.directory.path, receiveOn: bridgeQueue,
                    read: { () }
                ) { _ in
                    guard !flag.isCancelled, token == observedToken else { return }
                    let report = endpoint.report("watch", token: observedToken)
                    publish(endpoint.status()?.focus(report))
                }
            }
            let report = endpoint.report("watch", token: token)
            publish(report.flatMap(status.focus))
            let now = ProcessInfo.processInfo.systemUptime
            if report == nil || now >= nextRenewal {
                if endpoint.command(modName + ".watch-" + token) { nextRenewal = now + 2 }
            }
        }
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(50))
        timer.resume()
        return AnyCancellable {
            flag.cancel()
            timer.cancel()
            bridgeQueue.async {
                observation?.cancel()
                if activated { _ = endpoint?.command("overlay.close", arguments: ["id": "mod-" + modName]) }
            }
        }
    }
}
