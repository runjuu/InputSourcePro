import Foundation

/// Herdr's desktop app, read with no setup: `view.json` names the
/// focused pane and is rewritten on every pane, tab or space switch; the
/// `herdr-app` and `hc` CLIs lead from that pane to its terminal and a pid.
enum HerdrDesktop {
    static let directory = ("~/.config/herdr-app" as NSString).expandingTildeInPath
    static let viewFile = directory + "/view.json"
    static let herdrApp = ("~/.local/bin/herdr-app" as NSString).expandingTildeInPath
    static let hc = ("~/.local/bin/hc" as NSString).expandingTildeInPath

    /// The focused pane `view.json` names now, nil when it can't be read.
    static func focusedPane() -> String? {
        FileManager.default.contents(atPath: viewFile).flatMap(focusedPane(fromView:))
    }

    /// The address of the terminal `pane` shows (`herdr-app ls`), nil when
    /// Herdr can't tell. Spawns a process, so call it off the main thread.
    static func terminal(ofPane pane: String, run: (_ path: String, _ arguments: [String]) -> String? = runCLI) -> String? {
        guard let list = run(herdrApp, ["ls"]) else {
            record("pane=\(pane) failed=ls")
            return nil
        }
        guard let terminal = terminal(ofPane: pane, fromList: list) else {
            record("pane=\(pane) failed=pane")
            return nil
        }
        record("pane=\(pane) terminal=\(terminal)")
        return terminal
    }

    /// The pid to read `terminal`'s tty from (`hc get`), nil when Herdr can't
    /// tell. Spawns a process, so call it off the main thread.
    static func pid(ofTerminal terminal: String, run: (_ path: String, _ arguments: [String]) -> String? = runCLI) -> pid_t? {
        guard let pid = run(hc, ["get", terminal, "--json"]).flatMap(pid(fromTerminal:)) else {
            record("terminal=\(terminal) failed=get")
            return nil
        }
        return pid
    }

    static func record(_ message: String) {
        IndicatorDiagnostics.record("terminal.view bundle=\(Terminal.herdr.rawValue) \(message)")
    }

    /// Runs a Herdr CLI; nil when it is missing, fails, or hangs.
    static func runCLI(_ path: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return TerminalProcess.output(of: path, arguments: arguments)
    }
}

// MARK: - Parsing

extension HerdrDesktop {
    /// `view.json`: the focused pane is `tabs[spaces[active]].focused`.
    static func focusedPane(fromView data: Data) -> String? {
        struct View: Decodable {
            struct Tab: Decodable { let focused: String? }
            let active: String
            let spaces: [String: String]
            let tabs: [String: Tab]
        }

        guard let view = try? JSONDecoder().decode(View.self, from: data),
              let tab = view.spaces[view.active]
        else { return nil }
        return view.tabs[tab]?.focused
    }

    /// `herdr-app ls`: the address of the terminal `pane` shows.
    static func terminal(ofPane pane: String, fromList output: String) -> String? {
        struct List: Decodable {
            struct Space: Decodable { let tabs: [Tab] }
            struct Tab: Decodable { let terminals: [Entry] }
            struct Entry: Decodable {
                let terminal: String
                let pane: String
            }

            let spaces: [Space]
        }

        return (try? JSONDecoder().decode(List.self, from: Data(output.utf8)))?
            .spaces.lazy
            .flatMap(\.tabs)
            .flatMap(\.terminals)
            .first { $0.pane == pane }?
            .terminal
    }

    /// `hc get <terminal> --json`: the foreground process's pid, else the shell's.
    static func pid(fromTerminal output: String) -> pid_t? {
        struct Info: Decodable {
            struct Foreground: Decodable { let pid: pid_t? }
            let pid: pid_t?
            let foreground: Foreground?
        }

        guard let info = try? JSONDecoder().decode(Info.self, from: Data(output.utf8)),
              let pid = info.foreground?.pid ?? info.pid,
              pid > 0
        else { return nil }
        return pid
    }
}
