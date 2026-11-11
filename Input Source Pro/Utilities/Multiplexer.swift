import Foundation

/// Terminal multiplexers whose focused pane Terminal Rules look into, so a rule
/// follows the program inside tmux rather than the multiplexer itself. Each is
/// asked through its own CLI at a fixed path: ISP runs without a login PATH.
// shortcut: only tmux's default server is asked (no -L/-S socket); upgrade when that setup is in use.
enum Multiplexer: String {
    case tmux

    /// Nesting limit, e.g. a tmux client running in a tmux pane.
    static let maxDepth = 3

    var executable: String { "/opt/homebrew/bin/" + rawValue }

    /// The tty of the focused pane of the client running on `clientTTY`, or nil
    /// when the multiplexer can't be asked. A multiplexer that answered is noted
    /// in `trail`, so `TerminalWatcher` can listen to it.
    func focusedPaneTTY(clientTTY: String, trail: inout TerminalTrail) -> String? {
        switch self {
        case .tmux:
            // The program is tmux, so a server is up or starting: the control-mode client retries until it answers.
            trail.tmux = true
            // A space, not a tab: without a UTF-8 locale (an app launched at login has none) tmux prints control characters as "_".
            return run(["list-clients", "-F", "#{client_tty} #{pane_tty}"])
                .flatMap { Self.paneTTY(fromTmuxClients: $0, clientTTY: clientTTY) }
        }
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
    static func paneTTY(fromTmuxClients output: String, clientTTY: String) -> String? {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0] == clientTTY, fields[1].hasPrefix("/dev/") else { continue }
            return String(fields[1])
        }
        return nil
    }
}
