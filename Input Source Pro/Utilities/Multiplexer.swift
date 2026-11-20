import Foundation

/// Terminal multiplexers whose focused pane Terminal Rules look into, so a rule
/// follows the program inside tmux, zellij or the herdr TUI rather than the
/// multiplexer itself. Herdr reports focus through its socket. The other
/// multiplexers use their CLIs, looked up where package managers install them.
// Only tmux's default server is asked (no -L/-S socket); zellij's CLI identifies the first client.
enum Multiplexer: String {
    case tmux, zellij, herdr

    /// Nesting limit, e.g. Herdr → tmux → zellij.
    static let maxDepth = 3

    /// What a multiplexer's focused pane holds: a tty to read further (with
    /// the pane's label), or, for zellij, which names no tty, the program
    /// itself (nil for a shell) with the pane's label.
    enum Pane: Equatable {
        case tty(String, label: String)
        case program(TerminalProgram?, label: String)
        /// Keep the client's own Terminal Rule; this mode cannot establish a local pane tty.
        case clientOnly
    }

    /// Where the CLI is installed, nil when it is in none of the usual places.
    var executable: String? {
        return TerminalProcess.executable(named: rawValue)
    }

    /// The focused pane of the client running on `clientTTY` with `arguments`
    /// (its argv), or nil when the multiplexer can't be asked. A multiplexer
    /// that answered is noted in `trail`, so `TerminalWatcher` can listen to it.
    func focusedPane(clientPID: pid_t, clientTTY: String, arguments: [String], trail: inout TerminalTrail) -> Pane? {
        switch self {
        case .tmux:
            // The program is tmux, so a server is up or starting: the control-mode client retries until it answers.
            // Without the CLI there is nothing to ask or attach with.
            trail.tmux = executable != nil
            // A space, not a tab: without a UTF-8 locale (an app launched at login has none) tmux prints control characters as "_".
            return run(["list-clients", "-F", "#{client_tty} #{pane_tty}"])
                .flatMap { Self.pane(fromTmuxClients: $0, clientTTY: clientTTY) }
        case .zellij:
            // shortcut: a pane running a multiplexer inside zellij names no tty, so nesting stops there; upgrade if that setup shows up.
            // Each way of naming the client's session can miss, so the first one zellij answers
            // for counts. The server socket names the session the client is in now, where the
            // socket is named after it (before zellij 0.46; since then it is a hash). argv keeps
            // the session the client started with, after a switch to another one inside it.
            // A bare `zellij` on 0.46 names it neither way: the only running session is asked.
            let named = [
                Self.zellijSession(fromSocketPeers: TerminalProcess.unixSocketPeers(ofPID: clientPID)),
                Self.zellijSession(fromArguments: arguments),
            ].compactMap { $0 }
            let answered = Self.firstAnswer(for: named, ask: Self.zellijPane(session:))
                ?? run(["list-sessions", "-n"])
                .flatMap(Self.onlySession(fromList:))
                .flatMap { named.contains($0) ? nil : Self.firstAnswer(for: [$0], ask: Self.zellijPane(session:)) }
            guard let (session, pane) = answered else { return nil }
            trail.zellij = TerminalTrail.Zellij(session: session, pane: pane)
            return pane
        case .herdr:
            guard let environment = TerminalProcess.environment(ofPID: clientPID, keys: [
                "HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "HERDR_SESSION", "HERDR_SOCKET_PATH", "HERDR_CLIENT_SOCKET_PATH",
            ]) else { return nil }
            return Self.herdrPane(arguments: arguments, environment: environment, trail: &trail) { socket, trail in
                Self.herdrFocusedPane(socket: socket, clientPID: clientPID, trail: &trail)
            }
        }
    }

    /// The focused pane of the herdr TUI client with `arguments`. Its socket is
    /// noted before asking, as tmux's server is: a server that doesn't answer
    /// yet is still subscribed to, and its handshake reads the pane again.
    static func herdrPane(
        arguments: [String],
        environment: [String: String],
        trail: inout TerminalTrail,
        read: (String, inout TerminalTrail) -> Pane?
    ) -> Pane? {
        guard let launch = HerdrLaunch(arguments: arguments) else { return .clientOnly }
        guard let home = environment["HOME"] else { return nil }
        let session = launch.session ?? environment["HERDR_SESSION"]
        let config = environment["XDG_CONFIG_HOME"] ?? home + "/.config"
        let state = environment["XDG_STATE_HOME"] ?? home + "/.local/state"
        guard config.hasPrefix("/"), state.hasPrefix("/") else { return nil }
        let socket: String
        if launch.session == nil, let override = environment["HERDR_SOCKET_PATH"] {
            guard override.hasPrefix("/") else { return nil }
            socket = override
        } else {
            // A client-only override can route input to a different server than its API.
            guard launch.session != nil || environment["HERDR_CLIENT_SOCKET_PATH"] == nil else { return .clientOnly }
            guard let path = herdrSocket(session: session, config: config) else { return nil }
            socket = path
        }

        // Saved machines share the local server socket even while a remote receives input.
        // Selection belongs to each live client; the persisted selection can be another's.
        let catalog = state + "/herdr/client/endpoints.json"
        let local = herdrIsLocalOnly(catalog: catalog)
        trail.herdrCatalogs[catalog] = local
        guard local else { return .clientOnly }
        trail.herdrSockets.append(socket)
        return read(socket, &trail)
    }

    /// Match the server's sole client connection to this exact TUI process.
    struct HerdrClient: Hashable {
        let pid: pid_t
        let server: pid_t
        let socket: String

        func isOnlyClient() -> Bool {
            let accepted = TerminalProcess.unixSockets(ofPID: server).filter { !$0.listening && $0.path == socket }
            let peers = Set(accepted.map(\.peerID))
            guard peers.count == 1, let peer = peers.first, peer != 0 else { return false }
            return TerminalProcess.unixSockets(ofPID: pid).contains { $0.id == peer && $0.peerPath == socket }
        }
    }

    static func herdrFocusedPane(socket: String, clientPID: pid_t, trail: inout TerminalTrail) -> Pane? {
        TerminalWatcher.Environment.withUnixPeer(at: socket) { fd, server in
            // Herdr inserts "-client" before the API socket's extension, even for custom paths.
            let clientSocket = (socket as NSString).deletingPathExtension + "-client.sock"
            let client = HerdrClient(pid: clientPID, server: server, socket: clientSocket)
            func verifyClient() -> Bool {
                let only = client.isOnlyClient()
                trail.herdrClients[client] = only
                return only
            }
            guard verifyClient() else { return .clientOnly }
            // Keep the baseline from before the snapshot so a concurrent split or
            // popup still wakes the watcher even when this inventory cannot be used.
            let devices = TerminalProcess.ptyMasters(ofPID: server) ?? []
            let query: [String: Any] = ["id": "isp", "method": "session.snapshot", "params": [:]]
            guard let snapshot = TerminalWatcher.Environment.jsonReply(to: query, on: fd) else {
                // An established subscription may stay quiet when this server recovers.
                trail.herdrInventoryIncomplete = true
                return nil
            }
            guard let view = herdrView(inSnapshot: snapshot) else { return .clientOnly }
            trail.herdrMasters[server] = devices
            guard devices.count == view.panes.count else { return .clientOnly }
            let tty: String
            switch herdrTTY(in: view, server: server, socket: socket, masters: devices) {
            case let .verified(path): tty = path
            case .unavailable: return .clientOnly
            case .incomplete:
                trail.herdrInventoryIncomplete = true
                return nil
            }
            guard trail.confirmHerdrMasters(ofPID: server) else { return nil }
            guard verifyClient() else { return .clientOnly }
            return .tty(tty, label: "herdr:" + socket + "/" + view.focusedPaneId)
        }
    }

    /// Accessed only on TerminalProcess.queue. Keep the last view's split shell
    /// identities so refreshing an unchanged session needs no request per split.
    private static var herdrTTYs: (server: pid_t, byTerminal: [String: TerminalProcess.PaneTTY]) = (0, [:])

    private enum HerdrTTY { case verified(String), unavailable, incomplete }

    private static func herdrTTY(in view: HerdrView, server: pid_t, socket: String, masters: Set<UInt32>) -> HerdrTTY {
        let previous = herdrTTYs.server == server ? herdrTTYs.byTerminal : [:]
        var verified: [String: TerminalProcess.PaneTTY] = [:]
        defer { herdrTTYs = (server, verified) }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        var focused: String?
        for pane in view.panes {
            let tty: TerminalProcess.PaneTTY
            if let cached = previous[pane.terminalId], TerminalProcess.paneTTY(ofPID: cached.owner.pid) == cached {
                tty = cached
            } else {
                // Each request needs a fresh connection; keep it on the original server.
                guard ProcessInfo.processInfo.systemUptime < deadline else { return .incomplete }
                let reply: Data? = TerminalWatcher.Environment.withUnixPeer(at: socket) { fd, peer in
                    guard peer == server else { return nil }
                    let query: [String: Any] = ["id": "isp", "method": "pane.process_info", "params": ["pane_id": pane.paneId]]
                    return TerminalWatcher.Environment.jsonReply(to: query, on: fd)
                }
                guard let reply else { return .incomplete }
                guard let shell = herdrShell(fromProcessInfo: reply), shell.pane == pane.paneId,
                      let current = TerminalProcess.paneTTY(ofPID: shell.pid) else { return .unavailable }
                tty = current
            }
            verified[pane.terminalId] = tty
            if pane.paneId == view.focusedPaneId { focused = tty.path }
        }
        // An unlisted master belongs to a popup or another unrepresented terminal.
        guard Set(verified.values.map(\.minor)) == masters, let focused else { return .unavailable }
        return .verified(focused)
    }

    /// Herdr's client checks this catalog once a second and can add machines without a restart.
    static func herdrIsLocalOnly(catalog: String) -> Bool {
        struct Catalog: Decodable {
            struct SSH: Decodable { let enabled: Bool }
            let ssh: [SSH]?
            let version: Int
        }
        do {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: catalog))
            let catalog = try JSONDecoder().decode(Catalog.self, from: bytes)
            return catalog.version == 1 && catalog.ssh?.contains(where: \.enabled) != true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return true
        } catch {
            return false
        }
    }

    /// The first of `sessions` that `ask` answers for, with its answer; each is asked at most once.
    static func firstAnswer<Answer>(for sessions: [String], ask: (String) -> Answer?) -> (session: String, answer: Answer)? {
        var asked: Set<String> = []
        for session in sessions where asked.insert(session).inserted {
            if let answer = ask(session) { return (session, answer) }
        }
        return nil
    }

    /// The focused pane of zellij `session`'s first client, nil when zellij can't be asked.
    static func zellijPane(session: String) -> Pane? {
        Multiplexer.zellij.run(["-s", session, "action", "list-clients"])
            .flatMap { pane(fromZellijClients: $0, session: session) }
    }

    /// Runs the multiplexer's CLI and returns its output, or nil when it is
    /// missing, fails, or hangs.
    private func run(_ arguments: [String]) -> String? {
        executable.flatMap { TerminalProcess.output(of: $0, arguments: arguments) }
    }
}

// MARK: - Parsing

extension Multiplexer {
    /// `tmux list-clients -F '#{client_tty} #{pane_tty}'`: one line per client
    /// with its session's active pane. The line for `clientTTY` names the
    /// pane; `display-message -c` can't be used instead, since its pane comes
    /// from the latest session, not the client's.
    static func pane(fromTmuxClients output: String, clientTTY: String) -> Pane? {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0] == clientTTY, fields[1].hasPrefix("/dev/") else { continue }
            let tty = String(fields[1])
            return .tty(tty, label: tty)
        }
        return nil
    }

    /// The session a zellij client attached to, from its argv: `zellij -s X`,
    /// `--session X`, `--session=X`, `attach X` or `a X` (attach flags skipped).
    static func zellijSession(fromArguments arguments: [String]) -> String? {
        var index = 1 // skip argv[0]
        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "-s", "--session":
                return index < arguments.endIndex ? arguments[index] : nil
            case "attach", "a":
                return arguments[index...].first { !$0.hasPrefix("-") }
            default:
                if argument.hasPrefix("--session=") { return String(argument.dropFirst("--session=".count)) }
            }
        }
        return nil
    }

    /// The session a zellij client is connected to, from the peer paths of its
    /// unix sockets: the server listens at `…/zellij-<uid>/<contract>/<session>`.
    static func zellijSession(fromSocketPeers peers: [String]) -> String? {
        peers.lazy
            .map { $0 as NSString }
            .first { $0.deletingLastPathComponent.contains("/zellij-") }
            .map { $0.lastPathComponent }
    }

    /// Only the full local UI follows the server's focused pane. Direct terminal/agent
    /// attaches route keyboard input to their explicit target; other subcommands run a CLI.
    struct HerdrLaunch {
        let session: String?

        init?(arguments: [String]) {
            guard !arguments.isEmpty else { return nil }
            let args = Array(arguments.dropFirst())
            if args.starts(with: ["session", "attach"]) {
                guard args.count == 3 else { return nil }
                session = args[2]
                return
            }
            // Herdr removes global session selectors before dispatching the client command.
            var selected: String?
            var command: [String] = []
            var iterator = args.makeIterator()
            while let argument = iterator.next() {
                if argument == "--session" {
                    guard let value = iterator.next() else { return nil }
                    selected = value
                } else if argument.hasPrefix("--session=") {
                    selected = String(argument.dropFirst("--session=".count))
                } else {
                    command.append(argument)
                }
            }
            guard command.isEmpty || command == ["client"] else { return nil }
            session = selected
        }
    }

    /// Herdr uses the unnamed server for both a bare launch and an explicit "default".
    static func herdrSocket(session: String?, config: String = FileManager.default.homeDirectoryForCurrentUser.path + "/.config") -> String? {
        let herdr = URL(fileURLWithPath: config).appendingPathComponent("herdr")
        guard let session, session != "default" else { return herdr.appendingPathComponent("herdr.sock").path }
        guard !session.isEmpty, !session.contains("/"), session != ".", session != ".." else { return nil }
        return herdr.appendingPathComponent("sessions/\(session)/herdr.sock").path
    }

    /// `zellij list-sessions -n`: `name [Created …]`, with `(EXITED - attach to resurrect)` after
    /// sessions that are gone but resurrectable; the name when exactly one session is running.
    static func onlySession(fromList output: String) -> String? {
        let names = output
            .split(whereSeparator: \.isNewline)
            .filter { !$0.contains("(EXITED") }
            .compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
        return names.count == 1 ? names[0] : nil
    }

    /// `zellij action list-clients`: a header row, then `CLIENT_ID ZELLIJ_PANE_ID
    /// RUNNING_COMMAND` per client. RUNNING_COMMAND is the foreground process's
    /// argv, so its first word is the typed command (`claude`), not `p_comm`.
    static func pane(fromZellijClients output: String, session: String) -> Pane? {
        let rows = output.split(whereSeparator: \.isNewline)
        guard rows.count >= 2, rows[0].hasPrefix("CLIENT_ID") else { return nil }
        let columns = rows[1].split(whereSeparator: \.isWhitespace)
        guard columns.count >= 2 else { return nil }

        let paneID = String(columns[1])
        let label = "zellij:\(session)/\(paneID)"
        // A shell pane lists its command as "N/A", which must not read as a program named "A".
        guard !paneID.hasPrefix("plugin_"), columns.count >= 3, columns[2] != "N/A" else { return .program(nil, label: label) }
        let command = (String(columns[2]) as NSString).lastPathComponent
        let key = TerminalProcess.program(comm: command, arguments: columns[2...].map(String.init)).key
        guard !key.isEmpty, !TerminalProcess.shells.contains(key) else { return .program(nil, label: label) }
        return .program(TerminalProgram(key: key, pane: label), label: label)
    }

    /// Sessions can retain another client's selected tab after it disconnects. In
    /// a single tab, pane focus is shared and the snapshot identifies its pane.
    struct HerdrView: Decodable {
        struct Workspace: Decodable { let tabCount: Int }
        struct Pane: Decodable { let paneId: String; let terminalId: String }
        let workspaces: [Workspace]
        let focusedPaneId: String
        let panes: [Pane]
    }

    static func herdrView(inSnapshot output: Data) -> HerdrView? {
        struct Reply: Decodable {
            struct Result: Decodable { let snapshot: HerdrView }
            let result: Result
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let snapshot = (try? decoder.decode(Reply.self, from: output))?.result.snapshot,
              snapshot.workspaces.count == 1, snapshot.workspaces[0].tabCount == 1 else { return nil }
        return snapshot
    }

    /// `herdr pane process-info`: the requested pane's shell pid and pane id. An
    /// error reply (`server_not_running`) has no `result`.
    static func herdrShell(fromProcessInfo output: Data) -> (pid: pid_t, pane: String)? {
        struct Reply: Decodable {
            struct Result: Decodable { let processInfo: Info }
            struct Info: Decodable {
                let shellPid: pid_t
                let paneId: String
            }

            let result: Result
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let info = (try? decoder.decode(Reply.self, from: output))?.result.processInfo,
              info.shellPid > 0
        else { return nil }
        return (info.shellPid, info.paneId)
    }
}
