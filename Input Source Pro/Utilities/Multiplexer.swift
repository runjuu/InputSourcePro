import Foundation

/// Terminal multiplexers whose focused pane Terminal Rules look into, so a rule
/// follows the program inside tmux or zellij rather than the multiplexer
/// itself. Each is asked through its own CLI at a fixed path: ISP runs without
/// a login PATH.
// shortcut: only tmux's default server is asked (no -L/-S socket), and for a multiplexer with several clients only the first one counts; upgrade when those setups are in use.
enum Multiplexer: String {
    case tmux, zellij

    /// Nesting limit, e.g. a tmux client running in a tmux pane.
    static let maxDepth = 3

    /// What a multiplexer's focused pane holds: a tty to read further (with
    /// the pane's label), or, for zellij, which names no tty, the program
    /// itself (nil for a shell) with the pane's label.
    enum Pane: Equatable {
        case tty(String, label: String)
        case program(TerminalProgram?, label: String)
    }

    var executable: String { "/opt/homebrew/bin/" + rawValue }

    /// The focused pane of the client running on `clientTTY` with `arguments`
    /// (its argv), or nil when the multiplexer can't be asked. A multiplexer
    /// that answered is noted in `trail`, so `TerminalWatcher` can listen to it.
    func focusedPane(clientPID: pid_t, clientTTY: String, arguments: [String], trail: inout TerminalTrail) -> Pane? {
        switch self {
        case .tmux:
            // The program is tmux, so a server is up or starting: the control-mode client retries until it answers.
            trail.tmux = true
            // A space, not a tab: without a UTF-8 locale (an app launched at login has none) tmux prints control characters as "_".
            return run(["list-clients", "-F", "#{client_tty} #{pane_tty}"])
                .flatMap { Self.pane(fromTmuxClients: $0, clientTTY: clientTTY) }
        case .zellij:
            // shortcut: a pane running a multiplexer inside zellij names no tty, so nesting stops there; upgrade if that setup shows up.
            // A bare `zellij` names its session only through the server socket it talks to.
            guard let session = Self.zellijSession(fromArguments: arguments)
                ?? Self.zellijSession(fromSocketPeers: TerminalProcess.unixSocketPeers(ofPID: clientPID))
                ?? run(["list-sessions", "-n"]).flatMap(Self.onlySession(fromList:)),
                let pane = Self.zellijPane(session: session)
            else { return nil }
            trail.zellij = TerminalTrail.Zellij(session: session, pane: pane)
            return pane
        }
    }

    /// The focused pane of zellij `session`'s first client, nil when zellij can't be asked.
    static func zellijPane(session: String) -> Pane? {
        Multiplexer.zellij.run(["-s", session, "action", "list-clients"])
            .flatMap { pane(fromZellijClients: $0, session: session) }
    }

    /// Runs the multiplexer's CLI and returns its output, or nil when it is
    /// missing, fails, or hangs.
    private func run(_ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        return TerminalProcess.output(of: executable, arguments: arguments)
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
}
