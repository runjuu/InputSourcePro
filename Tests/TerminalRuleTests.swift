import AppKit
import Combine
import XCTest
@testable import Input_Source_Pro

final class TerminalRuleTests: XCTestCase {
    func testRuleMatchesKeyOrNameIgnoringCaseAndWhitespace() {
        let rule = TerminalRule(program: "  Claude ")

        XCTAssertTrue(rule.matches(TerminalProgram(key: "claude", name: "Claude Code")))
        XCTAssertTrue(rule.matches(TerminalProgram(key: "program", name: "CLAUDE")))
        XCTAssertFalse(rule.matches(TerminalProgram(key: "claude-alt")))
    }

    func testEmptyRuleNeverMatches() {
        XCTAssertFalse(TerminalRule(program: " ").matches(TerminalProgram(key: " ")))
    }

    func testFirstEnabledMatchingRuleWins() {
        let disabled = TerminalRule(program: "nvim", disabled: true)
        let first = TerminalRule(program: "nvim")
        let second = TerminalRule(program: "Neovim")

        let rule = TerminalRule.firstEnabledRule(
            matching: TerminalProgram(key: "nvim", name: "Neovim"),
            in: [disabled, first, second]
        )

        XCTAssertEqual(rule, first)
    }

    func testRuleRoundTripsThroughJSON() throws {
        let rule = TerminalRule(program: "lazygit", inputSourceId: "com.apple.keylayout.ABC")
        let data = try JSONEncoder().encode([rule])

        XCTAssertEqual(try JSONDecoder().decode([TerminalRule].self, from: data), [rule])
    }

    func testARuleStoredWithoutLaterFieldsStillReads() throws {
        let rules = try JSONDecoder().decode([TerminalRule].self, from: Data(#"[{"program":"nvim"}]"#.utf8))
        XCTAssertEqual(rules.map(\.program), ["nvim"])
        XCTAssertEqual(rules.first?.disabled, false)
        XCTAssertNil(rules.first?.inputSourceId)
        XCTAssertThrowsError(try JSONDecoder().decode([TerminalRule].self, from: Data(#"[{"disabled":true}]"#.utf8)))
    }

    func testARuleCanBeRequiredToBeUsable() {
        let dead = TerminalRule(program: "claude", inputSourceId: "gone")
        let live = TerminalRule(program: "claude", inputSourceId: "installed")
        let claude = TerminalProgram(key: "claude")
        XCTAssertEqual(TerminalRule.firstEnabledRule(matching: claude, in: [dead, live]), dead)
        XCTAssertEqual(TerminalRule.firstEnabledRule(matching: claude, in: [dead, live]) { $0.inputSourceId != "gone" }, live)
        XCTAssertNil(TerminalRule.firstEnabledRule(matching: claude, in: [dead]) { $0.inputSourceId != "gone" })
    }
}

final class TerminalProcessTests: XCTestCase {
    private func process(_ pid: pid_t, pgid: pid_t, foreground: pid_t, start: TimeInterval, _ comm: String) -> TerminalProcess {
        TerminalProcess(pid: pid, pgid: pgid, foregroundPgid: foreground, startTime: start, comm: comm)
    }

    func testGroupLeaderWinsOverChildrenItSpawnedLater() {
        let processes = [
            process(100, pgid: 100, foreground: 200, start: 1, "zsh"),
            process(213, pgid: 200, foreground: 200, start: 5, "caffeinate"),
            process(200, pgid: 200, foreground: 200, start: 2, "2.1.318"),
            process(205, pgid: 200, foreground: 200, start: 3, "node"),
        ]

        XCTAssertEqual(TerminalProcess.foregroundProcess(in: processes)?.pid, 200)
    }

    func testShellLeaderYieldsToTheCommandItStarted() {
        let processes = [
            process(300, pgid: 300, foreground: 300, start: 1, "bash"),
            process(301, pgid: 300, foreground: 300, start: 2, "lazygit"),
        ]

        XCTAssertEqual(TerminalProcess.foregroundProcess(in: processes)?.comm, "lazygit")
    }

    func testShellPromptAndBackgroundJobsMeanNoProgram() {
        let processes = [
            process(400, pgid: 400, foreground: 400, start: 1, "-zsh"),
            process(410, pgid: 410, foreground: 400, start: 2, "sleep"),
        ]

        XCTAssertNil(TerminalProcess.foregroundProcess(in: processes))
    }

    func testSameStartTimeFallsBackToLowerPid() {
        let processes = [
            process(502, pgid: 500, foreground: 500, start: 1, "less"),
            process(501, pgid: 500, foreground: 500, start: 1, "cat"),
        ]

        XCTAssertEqual(TerminalProcess.foregroundProcess(in: processes)?.pid, 501)
    }

    func testProgramPrefersTypedCommandAndKeepsKernelName() {
        XCTAssertEqual(
            TerminalProcess.program(comm: "2.1.318", arguments: ["claude", "--resume"]),
            TerminalProgram(key: "claude", name: "2.1.318")
        )
        XCTAssertEqual(TerminalProcess.program(comm: "nvim", arguments: ["/opt/homebrew/bin/nvim"]), TerminalProgram(key: "nvim"))
        XCTAssertEqual(TerminalProcess.program(comm: "lazygit", arguments: []), TerminalProgram(key: "lazygit"))
    }

    func testInterpretedScriptIsNamedAfterTheScript() {
        XCTAssertEqual(TerminalProcess.program(comm: "bun", arguments: ["bun", "/Users/me/.bun/bin/omp", "status"]), TerminalProgram(key: "omp", name: "bun"))
        XCTAssertEqual(TerminalProcess.program(comm: "node", arguments: ["node", "--no-warnings", "/opt/tool/dist/cli.js"]), TerminalProgram(key: "cli", name: "node"))
        XCTAssertEqual(TerminalProcess.program(comm: "node", arguments: ["node"]), TerminalProgram(key: "node"))

        let package = "/Users/me/node_modules/@earendil-works/pi-coding-agent"
        let manifest: [String: Any] = ["name": "@earendil-works/pi-coding-agent", "bin": ["pi": "dist/bundle/cli.js"]]
        XCTAssertEqual(TerminalProcess.binName(in: manifest, packageDirectory: package, script: package + "/dist/bundle/cli.js"), "pi")
        XCTAssertNil(TerminalProcess.binName(in: manifest, packageDirectory: package, script: package + "/dist/other.js"))
        XCTAssertEqual(TerminalProcess.binName(in: ["name": "@scope/codex", "bin": "bin/codex.js"], packageDirectory: package, script: package + "/bin/codex.js"), "codex")
    }

    func testParsesArgumentsFromProcArgs() {
        var buffer = withUnsafeBytes(of: Int32(2)) { Array($0) }
        buffer += Array("/Users/me/.local/share/claude/versions/2.1.318".utf8) + [0, 0, 0]
        buffer += Array("claude".utf8) + [0] + Array("--resume".utf8) + [0]
        buffer += Array("HOME=/Users/me".utf8) + [0]

        XCTAssertEqual(TerminalProcess.arguments(fromProcArgs: buffer[...]), ["claude", "--resume"])
        XCTAssertEqual(TerminalProcess.arguments(fromProcArgs: ArraySlice<UInt8>([1, 0])), [])
    }

    func testReadsOwnProcessArguments() {
        XCTAssertFalse(TerminalProcess.arguments(pid: getpid()).isEmpty)
    }

    func testTTYPathOfOwnProcess() {
        // The test host usually has no controlling tty (stdin may still be one).
        let path = TerminalProcess.ttyPath(ofPID: getpid())
        XCTAssert(path == nil || path!.hasPrefix("/dev/"), "unexpected tty \(path ?? "nil")")

        let controlling = open("/dev/tty", O_RDONLY | O_NOCTTY)
        if controlling >= 0 {
            close(controlling)
            XCTAssertNotNil(path)
        }
    }

    func testTTYPathIsNilWithoutUsableProcess() {
        XCTAssertNil(TerminalProcess.ttyPath(ofPID: 1)) // launchd: root, no tty
        XCTAssertNil(TerminalProcess.ttyPath(ofPID: pid_t.max))
    }

    func testTTYOwnerWalksUpToTheNearestTTY() {
        let table: [pid_t: (ppid: pid_t, tty: String?, startTime: TimeInterval)] = [
            10: (9, nil, 10), 9: (8, "/dev/ttys1", 9), 8: (7, "/dev/ttys0", 8),
            20: (19, nil, 20), 19: (18, nil, 19), 18: (17, nil, 18), 17: (16, nil, 17), 16: (15, "/dev/ttys2", 16),
            30: (1, nil, 30),
        ]
        func owner(_ pid: pid_t, depth: Int = 4) -> pid_t? {
            TerminalProcess.ttyOwner(ofPID: pid, maxDepth: depth) { table[$0] }?.pid
        }
        XCTAssertEqual(owner(8), 8) // has a tty itself
        XCTAssertEqual(owner(10), 9) // the nearest one wins
        let helper = TerminalProcess.ttyOwner(ofPID: 10, maxDepth: 4) { table[$0] }
        XCTAssertEqual(helper?.writerStartTime, 10)
        XCTAssertEqual(owner(20), 16) // exactly maxDepth parents up
        XCTAssertNil(owner(20, depth: 3)) // one short
        XCTAssertNil(owner(30)) // stops at launchd
        XCTAssertNil(owner(99)) // gone
        if let own = TerminalProcess.ttyPath(ofPID: getpid()) {
            XCTAssertEqual(TerminalProcess.ttyOwner(ofPID: getpid())?.pid, getpid())
            XCTAssertEqual(TerminalProcess.ttyOwner(ofPID: getpid())?.tty, own)
        }
    }

    func testRefreshReadsTheRememberedTTYUntilItIsForgotten() {
        TerminalProcess.queue.sync {
            // /dev/null runs no foreground job, so it reads as a shell prompt in that pane.
            let shell = TerminalReading(program: nil, pane: "/dev/null", tty: "/dev/null")
            XCTAssertEqual(Terminal.ghostty.focusedProgram(onTTY: "/dev/null", pid: getpid()), shell)
            XCTAssertEqual(Terminal.ghostty.refreshedProgram(pid: getpid()), shell)
            XCTAssertEqual(Terminal.ghostty.focusedTTY, "/dev/null")

            XCTAssertEqual(Terminal.ghostty.focusedProgram(onTTY: nil, pid: getpid()), TerminalReading(program: nil, pane: nil))
            XCTAssertNil(Terminal.ghostty.focusedTTY, "Forgotten: the next refresh asks the terminal")
        }
    }

    func testGhosttyPanelIsTheOnlyTerminalOutsideEveryWindow() {
        let windows = ["/dev/ttys001", "/dev/ttys002"]
        XCTAssertEqual(TerminalProbe.panelTTY(all: windows + ["/dev/ttys009"], inWindows: windows), "/dev/ttys009")
        XCTAssertEqual(TerminalProbe.panelTTY(all: ["/dev/ttys009"], inWindows: []), "/dev/ttys009")
        XCTAssertNil(TerminalProbe.panelTTY(all: windows, inWindows: windows), "No panel")
        XCTAssertNil(TerminalProbe.panelTTY(all: windows + ["/dev/ttys008", "/dev/ttys009"], inWindows: windows), "A split panel: focus unknown")
    }
}

final class MultiplexerTests: XCTestCase {
    func testUnreadableTmuxPaneKeepsTheRuleWithoutExposingItsClientTTY() {
        let client = "/dev/ttys010"
        let program = TerminalProgram(key: "tmux", name: "tmux: client")
        for depth in [0, 1, Multiplexer.maxDepth] {
            var trail = TerminalTrail()
            var asked = false
            let reading = TerminalProcess.foregroundProgram(program, onTTY: client, pane: client, depth: depth, trail: &trail) { mux, _ in
                XCTAssertEqual(mux, .tmux)
                asked = true
                return nil
            }
            XCTAssertEqual(asked, depth < Multiplexer.maxDepth)
            XCTAssertEqual(reading.program, TerminalProgram(key: program.key, name: program.name, pane: client))
            XCTAssertEqual(reading.pane, client)
            XCTAssertNil(reading.tty)
            XCTAssertFalse(reading.paneControlUnavailable)
        }
    }

    func testTmuxClientsNameThePaneTTYOfTheAskedClient() {
        // Each client's line carries its own session's pane; a control-mode client has no tty.
        let clients = "/dev/ttys092 /dev/ttys010\n/dev/ttys091 /dev/ttys016\n /dev/ttys039\n"
        XCTAssertEqual(
            Multiplexer.pane(fromTmuxClients: clients, clientTTY: "/dev/ttys091"),
            .tty("/dev/ttys016", label: "/dev/ttys016")
        )
        XCTAssertNil(Multiplexer.pane(fromTmuxClients: clients, clientTTY: "/dev/ttys999"))
        XCTAssertNil(Multiplexer.pane(fromTmuxClients: "", clientTTY: "/dev/ttys091"))
    }

    func testZellijSessionFromClientArguments() {
        XCTAssertEqual(Multiplexer.zellijSession(fromArguments: ["zellij", "-s", "work"]), "work")
        XCTAssertEqual(Multiplexer.zellijSession(fromArguments: ["zellij", "--session", "work"]), "work")
        XCTAssertEqual(Multiplexer.zellijSession(fromArguments: ["zellij", "--session=work"]), "work")
        XCTAssertEqual(Multiplexer.zellijSession(fromArguments: ["zellij", "attach", "work"]), "work")
        XCTAssertEqual(Multiplexer.zellijSession(fromSocketPeers: ["/var/folders/x/T/zellij-501/contract_version_1/zippy-panda"]), "zippy-panda")
        XCTAssertNil(Multiplexer.zellijSession(fromSocketPeers: ["/Users/me/.config/herdr/herdr.sock", ""]))
        XCTAssertEqual(Multiplexer.zellijSession(fromArguments: ["/opt/homebrew/bin/zellij", "a", "-c", "work"]), "work")
        XCTAssertNil(Multiplexer.zellijSession(fromArguments: ["zellij"]))
        XCTAssertNil(Multiplexer.zellijSession(fromArguments: ["zellij", "-l", "compact"]))
        XCTAssertNil(Multiplexer.zellijSession(fromArguments: ["zellij", "-s"]))
        XCTAssertNil(Multiplexer.zellijSession(fromArguments: []))
    }

    func testZellijOnlySessionNeedsExactlyOne() {
        XCTAssertEqual(Multiplexer.onlySession(fromList: "work [Created 2m 31s ago] \n"), "work")
        XCTAssertNil(Multiplexer.onlySession(fromList: "work [Created 1s ago] \nplay [Created 2s ago] \n"))
        XCTAssertNil(Multiplexer.onlySession(fromList: ""))
        // An exited session stays listed for days while it can be resurrected.
        XCTAssertEqual(Multiplexer.onlySession(fromList: "old [Created 2days 7h ago] (EXITED - attach to resurrect)\nwork [Created 2m ago] \n"), "work")
        XCTAssertNil(Multiplexer.onlySession(fromList: "old [Created 2days ago] (EXITED - attach to resurrect)\n"))
    }

    func testZellijClientsNameTheRunningCommand() {
        let clients = """
        CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND
        1         terminal_0     claude 60
        2         terminal_3     nvim
        """
        XCTAssertEqual(
            Multiplexer.pane(fromZellijClients: clients, session: "work"),
            .program(TerminalProgram(key: "claude", pane: "zellij:work/terminal_0"), label: "zellij:work/terminal_0")
        )
        XCTAssertEqual(
            Multiplexer.pane(fromZellijClients: "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n1 terminal_2 /opt/homebrew/bin/nvim x.txt\n", session: "work"),
            .program(TerminalProgram(key: "nvim", pane: "zellij:work/terminal_2"), label: "zellij:work/terminal_2")
        )
    }

    /// zellij 0.46 names its server socket by a hash, so the name read from it is no
    /// session: the next way of naming the session is asked, each name once.
    func testZellijSessionIsTheFirstNameThatAnswers() {
        var asked: [String] = []
        let ask = { (session: String) -> String? in
            asked.append(session)
            return session == "work" ? "pane" : nil
        }
        let answer = Multiplexer.firstAnswer(for: ["0546e8d7ae28", "0546e8d7ae28", "work", "other"], ask: ask)
        XCTAssertEqual(answer?.session, "work")
        XCTAssertEqual(answer?.answer, "pane")
        XCTAssertEqual(asked, ["0546e8d7ae28", "work"])
        XCTAssertNil(Multiplexer.firstAnswer(for: ["gone"], ask: ask))
    }

    func testZellijShellOrPluginPaneMeansNoProgram() {
        let header = "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n"
        XCTAssertEqual(Multiplexer.pane(fromZellijClients: header + "1 terminal_0 /bin/zsh\n", session: "s"), .program(nil, label: "zellij:s/terminal_0"))
        XCTAssertEqual(Multiplexer.pane(fromZellijClients: header + "1 terminal_0 -zsh\n", session: "s"), .program(nil, label: "zellij:s/terminal_0"))
        XCTAssertEqual(Multiplexer.pane(fromZellijClients: header + "1 plugin_2 zellij:strider\n", session: "s"), .program(nil, label: "zellij:s/plugin_2"))
        XCTAssertEqual(Multiplexer.pane(fromZellijClients: header + "1 terminal_0\n", session: "s"), .program(nil, label: "zellij:s/terminal_0"))
        XCTAssertEqual(Multiplexer.pane(fromZellijClients: header + "2 terminal_1 N/A\n", session: "s"), .program(nil, label: "zellij:s/terminal_1"))
    }

    func testZellijUnreadableClientsAreUnknown() {
        XCTAssertNil(Multiplexer.pane(fromZellijClients: "", session: "s"))
        XCTAssertNil(Multiplexer.pane(fromZellijClients: "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n", session: "s"))
        XCTAssertNil(Multiplexer.pane(fromZellijClients: "Session not found\n1 terminal_0 claude\n", session: "s"))
    }

    func testHerdrProcessInfoNamesTheShell() throws {
        let reply = #"{"id":"cli:pane:process_info","result":{"process_info":{"foreground_process_group_id":7282,"foreground_processes":[{"argv":["tmux"],"argv0":"tmux","cmdline":"tmux","cwd":"/Users/me","name":"tmux","pid":7282}],"pane_id":"wB:p5Q","shell_pid":4160},"type":"pane_process_info"}}"#
        let shell = try XCTUnwrap(Multiplexer.herdrShell(fromProcessInfo: reply))

        XCTAssertEqual(shell.pid, 4160)
        XCTAssertEqual(shell.pane, "wB:p5Q")
    }

    /// A server that doesn't answer yet is still subscribed to, so its handshake reads the pane again.
    func testHerdrSocketIsNotedEvenWhenTheQueryFails() {
        var trail = TerminalTrail()
        var asked: [[String]] = []
        let pane = Multiplexer.herdrPane(arguments: ["herdr", "--session", "work"], trail: &trail, run: { asked.append($0); return nil })

        XCTAssertNil(pane)
        XCTAssertEqual(asked, [["--session", "work", "pane", "process-info"]])
        XCTAssertEqual(trail.herdrSockets, [Multiplexer.herdrSocket(session: "work")].compactMap { $0 })

        let reply = #"{"result":{"process_info":{"pane_id":"p1","shell_pid":4160}}}"#
        XCTAssertNil(Multiplexer.herdrPane(arguments: ["herdr"], trail: &trail, run: { _ in reply }, ttyPath: { _ in nil }),
                     "The shell has exited")
        XCTAssertEqual(trail.herdrSockets.count, 2)
        XCTAssertEqual(Multiplexer.herdrPane(arguments: ["herdr"], trail: &trail, run: { _ in reply }, ttyPath: { _ in "/dev/ttys009" }),
                       .tty("/dev/ttys009", label: "herdr:p1"))
    }

    func testHerdrErrorReplyIsUnknown() {
        XCTAssertNil(Multiplexer.herdrShell(fromProcessInfo: #"{"id":"cli:pane:process_info","error":{"code":"server_not_running","message":"no server"}}"#))
        XCTAssertNil(Multiplexer.herdrShell(fromProcessInfo: "not json"))
    }

    func testRefreshReadsTheRememberedTTYUntilItIsForgotten() {
        TerminalProcess.queue.sync {
            // /dev/null runs no foreground job, so it reads as a shell prompt in that pane.
            let shell = TerminalReading(program: nil, pane: "/dev/null")
            XCTAssertEqual(Terminal.herdr.focusedProgram(onTTY: "/dev/null", pid: getpid()), shell)
            XCTAssertEqual(Terminal.herdr.refreshedProgram(pid: getpid()), shell)

            XCTAssertEqual(Terminal.herdr.focusedProgram(onTTY: nil, pid: getpid()), TerminalReading(program: nil, pane: nil))
            XCTAssertNil(Terminal.herdr.refreshedProgram(pid: getpid()))
        }
    }

    // MARK: Herdr's desktop app

    func testHerdrRemoteClientNeverQueriesLocalSession() {
        for args in [["--remote", "workbox"], ["--session=work", "--remote=workbox"]] {
            var trail = TerminalTrail()
            let pane = Multiplexer.herdrPane(arguments: ["herdr"] + args, trail: &trail, run: { _ in
                XCTFail("Queried a local session for a remote client")
                return nil
            })
            XCTAssertNil(pane)
            XCTAssertTrue(trail.herdrSockets.isEmpty)
        }
    }

    func testBundledHerdrModInstallsIdempotentlyAndPreservesExistingMods() throws {
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: HerdrDesktop.modName, withExtension: nil))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mods = root.appendingPathComponent("mods")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = mods.appendingPathComponent(HerdrDesktop.modName)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        XCTAssertThrowsError(try HerdrDesktop.install(from: bundled, into: mods))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
        try FileManager.default.removeItem(at: target)
        try HerdrDesktop.install(from: bundled, into: mods)
        try HerdrDesktop.install(from: bundled, into: mods)
        for file in ["main.js", "mod.json"] {
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(file)), try Data(contentsOf: bundled.appendingPathComponent(file)))
        }
    }

    func testHerdrReportsBelongToTheCurrentRequest() {
        let data = Data(#"{"input-source-pro.watch":{"token":"a","focus":{"pane":"p1","terminal":"t2"}},"unrelated":null}"#.utf8)
        XCTAssertEqual(HerdrDesktop.report(in: data, key: "watch", token: "a"), .init(pane: "p1", terminal: "t2"))
        XCTAssertNil(HerdrDesktop.report(in: data, key: "watch", token: "b"))
        XCTAssertNil(HerdrDesktop.report(in: data, key: "query", token: "a"))
    }

    func testHerdrModAndRemotePanesForgetLocalTTY() {
        TerminalProcess.queue.sync {
            for address in [nil, "work/t1"] as [String?] {
                _ = Terminal.herdr.focusedProgram(onTTY: "/dev/null", pid: getpid())
                let reading = Terminal.herdr.herdrReading(.init(pane: "pB", terminal: address, pid: getpid()), pid: getpid(), lastTry: false) { _ in
                    XCTFail("Resolved a local PID for a non-local terminal")
                    return nil
                }
                XCTAssertEqual(reading?.pane, address ?? "pB")
                XCTAssertTrue(reading?.paneControlUnavailable == true)
                XCTAssertNil(reading?.tty)
                XCTAssertNil(Terminal.herdr.focusedTTY)
            }
        }
    }

    func testHerdrLocalReadingRetriesUntilThePaneHasATty() {
        TerminalProcess.queue.sync {
            let focus = HerdrDesktop.Focus(pane: "p", terminal: "t", pid: 2861)
            XCTAssertEqual(Terminal.herdr.herdrReading(focus, pid: getpid(), lastTry: false) { _ in "/dev/null" }?.tty, "/dev/null")
            XCTAssertNil(Terminal.herdr.herdrReading(focus, pid: getpid(), lastTry: false) { _ in nil })
            XCTAssertNil(Terminal.herdr.focusedTTY)
            XCTAssertEqual(Terminal.herdr.herdrReading(focus, pid: getpid(), lastTry: true) { _ in nil }?.pane, "t")
        }
    }
}

@MainActor
final class AppKindTerminalTests: XCTestCase {
    private let app = NSRunningApplication.current

    private func terminal(_ program: TerminalProgram, rule: TerminalRule? = nil) -> AppKind {
        .terminal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: true, program: program, rule: rule ?? TerminalRule(program: program.key))
        )
    }

    func testIdUsesMatchedRule() throws {
        let bundleId = try XCTUnwrap(app.bundleId())
        let rule = TerminalRule(program: "claude")

        XCTAssertEqual(
            terminal(TerminalProgram(key: "claude", name: "Claude Code"), rule: rule).getId(),
            "\(bundleId)_\(rule.id.uuidString)"
        )
    }

    func testProgramChangeInSameTerminalIsNewContext() {
        let normal = AppKind.normal(app: app, info: (focusedElement: nil, isFocusOnInputContainer: true))
        let claude = terminal(TerminalProgram(key: "claude"))
        let nvim = terminal(TerminalProgram(key: "nvim"))

        XCTAssertFalse(claude.isSameAppOrWebsite(with: nvim, detectAddressBar: true))
        XCTAssertFalse(claude.isSameAppOrWebsite(with: normal, detectAddressBar: true))
        XCTAssertFalse(normal.isSameAppOrWebsite(with: claude, detectAddressBar: true))
        XCTAssertTrue(claude.isSameAppOrWebsite(with: terminal(TerminalProgram(key: "claude")), detectAddressBar: true))
    }

    func testPaneChangeWithSameProgramIsNewContext() throws {
        let bundleId = try XCTUnwrap(app.bundleId())
        let rule = TerminalRule(program: "claude")
        let paneA = terminal(TerminalProgram(key: "claude", pane: "t2d"), rule: rule)
        let paneB = terminal(TerminalProgram(key: "claude", pane: "t2k"), rule: rule)

        XCTAssertFalse(paneA.isSameAppOrWebsite(with: paneB, detectAddressBar: true))
        XCTAssertEqual(paneA.getId(), paneB.getId())
        XCTAssertEqual(paneA.getId(), "\(bundleId)_\(rule.id.uuidString)")
    }

    func testAnInterpreterWithoutAScriptNameIsTheProgram() {
        XCTAssertEqual(TerminalProcess.program(comm: "node", arguments: ["node", "."]).key, "node")
        XCTAssertEqual(TerminalProcess.program(comm: "node", arguments: ["node", "/tmp/isp-no-package/tool.js"]).key, "tool")
    }

    func testProgramIdLeavesOutPane() {
        XCTAssertEqual(TerminalProgram(key: "claude", name: "2.1.318", pane: "/dev/ttys008").id, "claude/2.1.318")
    }

    /// A pane an `isp:` program controls is a context without a rule: its program keys it.
    func testIdWithoutARuleUsesTheProgram() throws {
        let bundleId = try XCTUnwrap(app.bundleId())
        let program = TerminalProgram(key: "program", name: "htop", pane: "/dev/ttys008")
        let kind = AppKind.terminal(app: app, info: (focusedElement: nil, isFocusOnInputContainer: true, program: program, rule: nil))

        XCTAssertEqual(kind.getId(), "\(bundleId)_program/htop")
    }
}

@MainActor
final class TerminalProgramGateTests: XCTestCase {
    private let claude = TerminalProgram(key: "claude", pane: "/dev/ttys001")
    private let hold = PassthroughSubject<Void, Never>()
    private var holds = 0
    private var rechecks = 0
    private var received: [TerminalProgram?] = []
    private lazy var gate = ApplicationVM.TerminalProgramGate { [unowned self] in
        self.holds += 1
        return self.hold.eraseToAnyPublisher()
    }

    private func receive(_ program: TerminalProgram?, pane: String?, current: TerminalProgram?, recheckReads: TerminalProgram? = nil) {
        gate.receive(
            TerminalReading(program: program, pane: pane),
            current: current,
            for: .herdr,
            recheck: { [unowned self] in
                self.rechecks += 1
                return Just(TerminalReading(program: recheckReads, pane: pane)).eraseToAnyPublisher()
            },
            publish: { [unowned self] in self.received.append($0.program) }
        )
    }

    func testShellInTheSamePaneWaitsAndPublishesWhatTheRecheckReads() {
        receive(nil, pane: "/dev/ttys001", current: claude)
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(rechecks, 0)

        hold.send(())
        XCTAssertEqual(received, [nil])
        XCTAssertEqual(rechecks, 1)
    }

    func testRecheckStillReadingTheProgramKeepsItAndEndsTheHold() {
        receive(nil, pane: "/dev/ttys001", current: claude, recheckReads: claude)
        hold.send(())
        XCTAssertEqual(received, [claude])

        // The next flip in that pane is held afresh.
        receive(nil, pane: "/dev/ttys001", current: claude)
        XCTAssertEqual(holds, 2)
    }

    func testRepeatedShellKeepsTheFirstDeadline() {
        receive(nil, pane: "/dev/ttys001", current: claude)
        receive(nil, pane: "/dev/ttys001", current: claude)
        XCTAssertEqual(holds, 1)
        XCTAssertTrue(received.isEmpty)

        hold.send(())
        XCTAssertEqual(received, [nil])
        XCTAssertEqual(rechecks, 1)
    }

    func testProgramOrOtherPaneEndsTheHoldAndPublishesAtOnce() {
        receive(nil, pane: "/dev/ttys001", current: claude)
        receive(claude, pane: "/dev/ttys001", current: claude)
        XCTAssertEqual(received, [claude])

        receive(nil, pane: "/dev/ttys001", current: claude)
        receive(nil, pane: "/dev/ttys002", current: claude)
        XCTAssertEqual(received, [claude, nil])

        hold.send(())
        XCTAssertEqual(received, [claude, nil])
        XCTAssertEqual(rechecks, 0)
    }

    func testShellInAnotherOrUnknownPanePublishesAtOnce() {
        let unpaned = TerminalProgram(key: "claude")
        for (pane, current) in [("/dev/ttys002", claude), (nil, claude), ("/dev/ttys001", unpaned)] as [(String?, TerminalProgram)] {
            received = []
            receive(nil, pane: pane, current: current)
            XCTAssertEqual(received, [nil])
        }
        XCTAssertEqual(holds, 0)
    }

    func testOtherChangesPublishAtOnce() {
        let nvim = TerminalProgram(key: "nvim", pane: "/dev/ttys001")
        for (program, current) in [(claude, nil), (nvim, claude), (nil, nil)] as [(TerminalProgram?, TerminalProgram?)] {
            received = []
            receive(program, pane: "/dev/ttys001", current: current)
            XCTAssertEqual(received, [program])
        }
        XCTAssertEqual(holds, 0)
    }
}

final class TerminalProbeTests: XCTestCase {
    func testWezTermQueriesTheSameGUIInstanceForItsClientAndPane() throws {
        // Both servers have a pane zero, on different ttys. The CLI receives
        // the socket through its environment just as the bundled executable does.
        let cli = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let script = """
        #!/bin/sh
        case "$WEZTERM_UNIX_SOCKET" in
            */.local/share/wezterm/gui-sock-46286) pid=46286; tty=/dev/ttys014 ;;
            */.local/share/wezterm/gui-sock-51000) pid=51000; tty=/dev/ttys016 ;;
            *) exit 1 ;;
        esac
        case "$3" in
            list-clients) printf '[{"pid":%s,"focused_pane_id":0}]' "$pid" ;;
            list) printf '[{"pane_id":0,"tty_name":"%s"}]' "$tty" ;;
            *) exit 1 ;;
        esac
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cli) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)

        XCTAssertEqual(TerminalProbe.weztermTTY(pid: 46286, executable: cli.path), "/dev/ttys014")
        XCTAssertEqual(TerminalProbe.weztermTTY(pid: 51000, executable: cli.path), "/dev/ttys016")
    }

    func testWezTermFocusedPaneComesFromTheFrontGUIClient() {
        let clients = """
        [{"pid": 46286, "workspace": "default", "focused_pane_id": 2},
         {"pid": 51000, "workspace": "default", "focused_pane_id": 7}]
        """

        XCTAssertEqual(TerminalProbe.focusedPaneID(fromClients: clients, pid: 51000), 7)
        XCTAssertNil(TerminalProbe.focusedPaneID(fromClients: clients, pid: 99999))
        XCTAssertNil(TerminalProbe.focusedPaneID(fromClients: "[]", pid: 1))
        XCTAssertNil(TerminalProbe.focusedPaneID(fromClients: "Error: failed to connect", pid: 1))
    }

    func testWezTermPaneTTYIsLookedUpByPaneID() {
        let panes = """
        [{"window_id": 0, "tab_id": 0, "pane_id": 0, "is_active": false, "tty_name": "/dev/ttys014"},
         {"window_id": 0, "tab_id": 0, "pane_id": 2, "is_active": true, "tty_name": "/dev/ttys016"}]
        """

        XCTAssertEqual(TerminalProbe.tty(ofPane: 2, in: panes), "/dev/ttys016")
        XCTAssertNil(TerminalProbe.tty(ofPane: 5, in: panes))
        XCTAssertNil(TerminalProbe.tty(ofPane: 0, in: "not json"))
    }

    func testAlacrittyWindowTitleSelectsARuleContextWithoutAuthorizingItsTTY() {
        let shell = (tty: "/dev/isp-test-shell", program: TerminalProgram?.none)
        let claude = (tty: "/dev/isp-test-claude", program: Optional(TerminalProgram(key: "claude", name: "2.1.318")))
        TerminalProcess.queue.sync {
            let reading = TerminalProbe.alacrittyReading(titled: "✳ Claude Code", among: [shell, claude], pid: getpid())
            XCTAssertEqual(reading.pane, claude.tty)
            XCTAssertNil(reading.tty)
            // A shell's working directory can name the program in a background window.
            let shellTitle = TerminalProbe.alacrittyReading(titled: "~/src/claude", among: [shell, claude], pid: getpid())
            XCTAssertNil(shellTitle.tty)
            XCTAssertNil(shellTitle.program?.tty)
            XCTAssertNil(Terminal.alacritty.focusedTTY)
            XCTAssertNil(TerminalProbe.alacrittyReading(titled: "user@host: ~", among: [shell, claude], pid: getpid()).tty)
            XCTAssertNil(TerminalProbe.alacrittyReading(titled: nil, among: [shell, claude], pid: getpid()).tty)
            XCTAssertNil(TerminalProbe.alacrittyReading(titled: "claude", among: [], pid: getpid()).tty)
        }
    }

    func testAmbiguousAlacrittyWindowsKeepOnlyTheirSharedProgramIdentifiers() {
        let old = TerminalProgram(key: "claude", name: "2.1.310")
        let updated = TerminalProgram(key: "claude", name: "2.1.318")
        TerminalProcess.queue.sync {
            let reading = TerminalProbe.alacrittyReading(
                titled: "Claude Code", among: [("old", old), ("new", updated)], pid: getpid()
            )
            XCTAssertEqual(reading.program, TerminalProgram(key: "claude"))
            XCTAssertNil(reading.tty)
        }
    }

    func testAlacrittyWindowsWithTheSameProgramHaveARuleButNoControllableTTY() {
        let editor = TerminalProgram(key: "nvim")
        let first = (tty: "/dev/isp-test-first", program: Optional(editor))
        let second = (tty: "/dev/isp-test-second", program: Optional(editor))
        TerminalProcess.queue.sync {
            _ = Terminal.alacritty.focusedProgram(onTTY: first.tty, pid: getpid())
            let reading = TerminalProbe.alacrittyReading(titled: "nvim", among: [first, second], pid: getpid())
            XCTAssertEqual(reading.program, editor)
            XCTAssertNil(reading.pane)
            XCTAssertNil(reading.tty)
            XCTAssertNil(Terminal.alacritty.focusedTTY, "A later refresh must not restore the previous window's tty")
        }
    }
}

final class TerminalControlCommandTests: XCTestCase {
    func testParsesEveryCommand() {
        XCTAssertEqual(TerminalControlCommand(line: "isp:123:select:com.apple.keylayout.ABC")?.command, .select("com.apple.keylayout.ABC"))
        XCTAssertEqual(TerminalControlCommand(line: "isp:123:push:x")?.command, .push("x"))
        XCTAssertEqual(TerminalControlCommand(line: "isp:123:pop"), TerminalControlCommand(pid: 123, command: .pop))
        XCTAssertEqual(TerminalControlCommand(line: "isp:99999:release")?.pid, 99999)
    }

    func testIdMayContainColons() {
        XCTAssertEqual(
            TerminalControlCommand(line: "isp:7:select:im.rime.inputmethod.Squirrel.Hans::im.rime.inputmethod.Squirrel.Hans")?.command,
            .select("im.rime.inputmethod.Squirrel.Hans::im.rime.inputmethod.Squirrel.Hans")
        )
    }

    func testRejectsMalformedLines() {
        for line in [
            "isp:123:jump", "isp:123:select:", "isp:123:select", "isp:123:push:", "isp:123:pop:x", "isp:123:release ",
            "isp:abc:pop", "isp::pop", "isp:-5:pop", "isp:0:pop", "isp:١٢:pop", "isp:123", "isp:99999999999999999999:pop",
            "mode:123:insert", "tmux:123:pop", "",
            "isp:123:select:" + String(repeating: "a", count: 256),
        ] {
            XCTAssertNil(TerminalControlCommand(line: line), line)
        }
        XCTAssertNotNil(TerminalControlCommand(line: "isp:123:select:" + String(repeating: "a", count: 256 - 15)))
    }
}

final class TerminalControlTrackerTests: XCTestCase {
    private var control = TerminalControlTracker<String>()
    private let first = TerminalProcess.Identity(pid: 10, startTime: 1)
    private let second = TerminalProcess.Identity(pid: 20, startTime: 2)
    private let tty = "/dev/ttys001"

    override func setUp() {
        super.setUp()
        control.setEnabledTerminals([.ghostty])
    }

    func testBatchKeepsItsArrivalEpochWhenTerminalSwitchesChange() {
        control.setEnabledTerminals([.ghostty, .iterm])
        let received = control.epoch
        control.setEnabledTerminals([.iterm])
        control.setEnabledTerminals([.iterm, .ghostty])

        // A lookup for this batch finished after Ghostty was re-enabled.
        XCTAssertTrue(control.acceptsCommands(from: received))
        control.push("ABC", on: tty, writer: first, live: (.iterm, "French"), epoch: received)
        XCTAssertFalse(control.isControlled(tty, in: .ghostty))
        XCTAssertTrue(control.isControlled(tty, in: .iterm))

        control.setEnabledTerminals([.ghostty])
        XCTAssertFalse(control.acceptsCommands(from: received))
        XCTAssertNil(control.pop(on: tty, writer: first))
    }

    func testSelectTakesControlAndSetsCurrent() {
        XCTAssertFalse(control.isControlled(tty))
        control.select("abc", on: tty, writer: first)

        XCTAssertTrue(control.isControlled(tty))
        XCTAssertEqual(control.current(on: tty, in: .ghostty), "abc")
    }

    func testFirstPushAfterOptInRestoresTheSourceInUse() {
        control.push("French", on: tty, writer: first, live: (.ghostty, "Greek"))
        control.setEnabledTerminals([.ghostty, .iterm])
        // The terminal just enabled is in front; its ordinary rule was using ABC.
        control.push("German", on: tty, writer: first, live: (.iterm, "ABC"))

        XCTAssertEqual(control.pop(on: tty, writer: first, in: .iterm), "ABC")
        XCTAssertEqual(control.current(on: tty, in: .ghostty), "French")
        control.follow("ABC", on: tty, in: .iterm)
        XCTAssertEqual(control.current(on: tty, in: .ghostty), "French")
        XCTAssertNil(control.pop(on: tty, writer: first, in: .iterm))
        XCTAssertEqual(control.current(on: tty, in: .ghostty), "Greek")
    }

    func testSelectAfterOptInDoesNotExposeAnEarlierStack() {
        control.push("French", on: tty, writer: first, live: (.ghostty, "Greek"))
        control.setEnabledTerminals([.ghostty, .iterm])
        control.select("German", on: tty, writer: first)

        XCTAssertNil(control.pop(on: tty, writer: first, in: .iterm))
        XCTAssertEqual(control.current(on: tty, in: .iterm), "German")
        XCTAssertEqual(control.current(on: tty, in: .ghostty), "Greek")
    }

    func testUnfocusedPopOnlyRestoresClientsThatSawThePush() {
        control.push("French", on: tty, writer: first, live: (.ghostty, "Greek"))
        control.setEnabledTerminals([.ghostty, .iterm])

        XCTAssertEqual(control.pop(on: tty, writer: first), "Greek")
        XCTAssertFalse(control.isControlled(tty, in: .iterm))
        XCTAssertEqual(control.current(on: tty, in: .ghostty), "Greek")

        control.push("German", on: tty, writer: first, live: nil)
        XCTAssertNil(control.pop(on: tty, writer: first, in: .iterm))
        XCTAssertEqual(control.current(on: tty, in: .iterm), "German")
        XCTAssertEqual(control.current(on: tty, in: .ghostty), "Greek")
    }

    func testPushStacksCurrentThenPopReturnsToIt() {
        control.select("rime", on: tty, writer: first)
        control.push("abc", on: tty, writer: first, live: (.ghostty, "other"))

        XCTAssertEqual(control.current(on: tty, in: .ghostty), "abc")
        XCTAssertEqual(control.pop(on: tty, writer: first), "rime")
        XCTAssertEqual(control.current(on: tty, in: .ghostty), "rime")
    }

    func testFirstPushStacksTheLiveSource() {
        control.push("abc", on: tty, writer: first, live: (.ghostty, "rime"))

        XCTAssertEqual(control.pop(on: tty, writer: first), "rime")
    }

    func testUnfocusedFirstPushStacksNothing() {
        control.push("abc", on: tty, writer: first, live: nil)

        XCTAssertTrue(control.isControlled(tty))
        XCTAssertNil(control.pop(on: tty, writer: first))
        XCTAssertEqual(control.current(on: tty, in: .ghostty), "abc")
    }

    func testPopOnEmptyStackChangesNothing() {
        XCTAssertNil(control.pop(on: tty, writer: first))
        XCTAssertFalse(control.isControlled(tty))

        control.select("abc", on: tty, writer: first)
        XCTAssertNil(control.pop(on: tty, writer: first))
        XCTAssertEqual(control.current(on: tty, in: .ghostty), "abc")
    }

    func testStackKeepsTheNewestSixteen() {
        control.select("0", on: tty, writer: first)
        for n in 1...20 { control.push("\(n)", on: tty, writer: first, live: nil) }

        var popped: [String] = []
        while let source = control.pop(on: tty, writer: first) { popped.append(source) }
        XCTAssertEqual(popped.count, TerminalControlTracker<String>.maxStack)
        XCTAssertEqual(popped.first, "19")
        XCTAssertEqual(popped.last, "4")
    }

    func testManualChangeUpdatesCurrentOnlyOfControlledPanes() {
        control.select("rime", on: tty, writer: first)
        control.follow("abc", on: tty, in: .ghostty)
        control.follow("abc", on: "/dev/ttys009", in: .ghostty)

        XCTAssertEqual(control.current(on: tty, in: .ghostty), "abc")
        XCTAssertFalse(control.isControlled("/dev/ttys009"))
    }

    func testReleaseDropsStateOfThatTTYOnly() {
        control.select("rime", on: tty, writer: first)
        control.select("abc", on: "/dev/ttys002", writer: second)
        control.release(tty, writer: first)

        XCTAssertFalse(control.isControlled(tty))
        XCTAssertNil(control.current(on: tty, in: .ghostty))
        XCTAssertEqual(control.current(on: "/dev/ttys002", in: .ghostty), "abc")
    }

    func testAReadingKeepsControlWhileTheProgramIsInTheForeground() {
        control.push("abc", on: tty, writer: first, live: (.ghostty, "rime"))
        control.check(tty) { writer, onTTY in writer == self.first && onTTY == self.tty ? .foreground : .gone }

        XCTAssertTrue(control.isControlled(tty))
        XCTAssertEqual(control.current(on: tty, in: .ghostty), "abc")
        XCTAssertEqual(control.pop(on: tty, writer: first), "rime")
    }

    /// Whatever the reading shows, a shell or another program, control ends with its process.
    func testAReadingReleasesOnceTheProgramIsGone() {
        control.select("abc", on: tty, writer: first)
        control.check(tty) { _, _ in .gone }

        XCTAssertFalse(control.isControlled(tty))
        XCTAssertNil(control.current(on: tty, in: .ghostty))
        control.check("/dev/ttys009") { _, _ in .gone }
    }

    /// Ctrl-Z: the shell (or what runs next) gets the rules, and `current` waits for `fg`.
    func testASuspendedProgramDoesNotControlItsPaneUntilItResumes() {
        control.select("abc", on: tty, writer: first)
        control.check(tty) { _, _ in .background }

        XCTAssertFalse(control.isControlled(tty))
        control.follow("rime", on: tty, in: .ghostty)
        XCTAssertNil(control.current(on: tty, in: .ghostty))

        control.check(tty) { _, _ in .foreground }
        XCTAssertTrue(control.isControlled(tty))
        XCTAssertEqual(control.current(on: tty, in: .ghostty), "abc")
    }

    func testACommandResumesASuspendedProgram() {
        control.select("abc", on: tty, writer: first)
        control.check(tty) { _, _ in .background }
        control.push("rime", on: tty, writer: first, live: nil)

        XCTAssertTrue(control.isControlled(tty))
        XCTAssertEqual(control.pop(on: tty, writer: first), "abc")

        control.check(tty) { _, _ in .background }
        control.select("rime", on: tty, writer: first)
        XCTAssertTrue(control.isControlled(tty))
    }

    func testSuspendedEditorsKeepSeparateStacksWhenTheyShareAPane() {
        control.push("ABC", on: tty, writer: first, live: (.ghostty, "French"))
        control.check(tty) { _, _ in .background }
        control.push("ABC", on: tty, writer: second, live: (.ghostty, "Pinyin"))
        XCTAssertEqual(control.pop(on: tty, writer: second), "Pinyin")
        control.release(tty, writer: second)
        XCTAssertFalse(control.isControlled(tty))

        control.check(tty) { _, _ in .foreground }
        XCTAssertEqual(control.current(on: tty, in: .ghostty), "ABC")
        XCTAssertEqual(control.pop(on: tty, writer: first), "French")
    }

    func testUnfocusedTakeoverPushRemembersThePanesKnownSource() {
        control.push("French", on: tty, writer: first, live: (.ghostty, "Pinyin"))
        control.push("ABC", on: tty, writer: second, live: nil)
        XCTAssertEqual(control.pop(on: tty, writer: second), "French")
        XCTAssertNil(control.pop(on: tty, writer: second))
    }

    func testFocusedTakeoverPushPreservesTheOtherEmulatorsSource() {
        control.push("French", on: tty, writer: first, live: (.ghostty, "Greek"))
        control.setEnabledTerminals([.ghostty, .iterm])
        control.push("German", on: tty, writer: first, live: (.iterm, "ABC"))
        XCTAssertEqual(control.pop(on: tty, writer: first, in: .iterm), "ABC")
        XCTAssertEqual(control.current(on: tty, in: .ghostty), "French")

        // iTerm's live source changed again before the new writer's first push.
        control.push("Spanish", on: tty, writer: second, live: (.iterm, "Pinyin"))
        XCTAssertEqual(control.pop(on: tty, writer: second, in: .iterm), "Pinyin")
        XCTAssertEqual(control.current(on: tty, in: .ghostty), "French")
    }

    func testReconcilingTheActiveWritersPushPreservesOtherEmulatorsHistory() {
        control.setEnabledTerminals([.iterm, .ghostty])
        control.select("French", on: tty, writer: first)
        control.push("Spanish", on: tty, writer: first, live: (.iterm, "Pinyin"), useLiveForCurrentWriter: true)

        XCTAssertEqual(control.pop(on: tty, writer: first, in: .iterm), "Pinyin")
        XCTAssertEqual(control.current(on: tty, in: .ghostty), "French")
    }

    func testAnotherPIDTakesOverTheTTY() {
        control.select("abc", on: tty, writer: first)
        control.select("rime", on: tty, writer: second)
        control.check(tty) { writer, _ in writer == self.second ? .foreground : .gone }

        XCTAssertEqual(control.current(on: tty, in: .ghostty), "rime")
        control.check(tty) { writer, _ in writer == self.first ? .foreground : .gone }
        XCTAssertFalse(control.isControlled(tty))
    }

    func testJobStateOfAProcessNotOnTheTTYIsGone() {
        XCTAssertEqual(TerminalProcess.jobState(ofPID: pid_t.max, onTTY: "/dev/ttys000"), .gone)
        XCTAssertEqual(TerminalProcess.jobState(ofPID: getpid(), onTTY: "/dev/not-a-tty"), .gone)
    }
}

final class TerminalControlFramerTests: XCTestCase {
    private var framer = TerminalControlFramer()

    private func append(_ text: String) -> String {
        framer.append(Array(text.utf8))
    }

    func testALineSplitAcrossReadsIsDeliveredWhole() {
        XCTAssertEqual(append("isp:1:sel"), "")
        XCTAssertEqual(append("ect:abc\n"), "isp:1:select:abc\n")
    }

    func testTwoLinesInOneRead() {
        XCTAssertEqual(append("isp:1:pop\nisp:1:release\n"), "isp:1:pop\nisp:1:release\n")
    }

    /// `isp:1:release` must not run when `x` is still to come.
    func testAPartialLineWaitsForItsNewline() {
        XCTAssertEqual(append("isp:1:pop\nisp:1:release"), "isp:1:pop\n")
        XCTAssertEqual(append("x\n"), "isp:1:releasex\n")
    }

    func testAnOverlongLineIsDroppedAndTheNextLineStillArrives() {
        let long = String(repeating: "a", count: TerminalControlFramer.maxPending + 1)
        XCTAssertEqual(append("isp:1:select:" + long), "")
        XCTAssertEqual(append(long + "isp:1:release"), "")
        XCTAssertEqual(append("\nisp:1:pop\n"), "isp:1:pop\n")
    }
}

@MainActor
final class FocusedTerminalTTYTests: XCTestCase {
    func testReusedHelperPIDOnTheSameTTYDoesNotInheritControl() async throws {
        let preferences = try ApplicationVMTerminalTests.inMemoryPreferencesVM()
        let restore = ApplicationVMTerminalTests.setTerminalPreferences(preferences, enabled: .ghostty, rules: [])
        defer { restore() }
        let tty = "/dev/ttys220"
        let writer: pid_t = 220
        let parent: pid_t = 200
        var writerStartTime: TimeInterval = 1
        let vm = ApplicationVM(preferencesVM: preferences, environment: .init(
            frontmostApplication: { nil }, focusedApplication: { nil },
            runningApplications: Just([]).eraseToAnyPublisher(), isTerminalEnabled: { _ in false },
            probedProgram: { _, _ in TerminalReading(program: nil, pane: nil) },
            terminalPanelFocus: .init(read: { _, _ in AnyCancellable {} }),
            ttyOwner: { _ in (parent, tty, writerStartTime) },
            jobState: { _, _ in .foreground }
        ))
        let source = InputSource.getCurrentInputSource().persistentIdentifier
        await vm.receiveTerminalControl(lines: "isp:\(writer):select:\(source)\nisp:\(writer):push:\(source)\n")
        XCTAssertTrue(preferences.terminalControl.isControlled(tty))

        // The foreground parent survived while its old helper's PID was recycled.
        writerStartTime = 2
        await vm.receiveTerminalControl(lines: "isp:\(writer):pop\n")
        XCTAssertFalse(preferences.terminalControl.isControlled(tty))
        XCTAssertNil(preferences.terminalControl.current(on: tty, in: .ghostty))
    }

    func testAPaneShowingAShellIsFocusedForItsFirstCommand() throws {
        let preferencesVM = try ApplicationVMTerminalTests.inMemoryPreferencesVM()
        // The switches live in the test host's own defaults.
        let restore = ApplicationVMTerminalTests.setTerminalPreferences(preferencesVM, enabled: .ghostty, rules: [])
        defer { restore() }

        preferencesVM.terminalTTYs[.ghostty] = "/dev/ttys001" // the latest reading was a shell
        preferencesVM.setTerminal(.ghostty, enabled: false)
        XCTAssertNil(preferencesVM.focusedTerminalTTY(.ghostty))

        preferencesVM.setTerminal(.ghostty, enabled: true)
        XCTAssertEqual(preferencesVM.focusedTerminalTTY(.ghostty), "/dev/ttys001")
        preferencesVM.setTerminal(.iterm, enabled: true)
        XCTAssertNil(preferencesVM.focusedTerminalTTY(.iterm))
    }
}

@MainActor
final class TerminalControlPipeTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testOnlyTheOwnerCanRemoveOrReplaceThePipe() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("terminal-control")
        let delivered = expectation(description: "first instance still receives commands")
        let first = try XCTUnwrap(TerminalControlPipe(directory: directory) { lines in
            XCTAssertEqual(lines, "isp:1:pop\n")
            delivered.fulfill()
        })
        XCTAssertNil(TerminalControlPipe(directory: directory) { _ in XCTFail("second reader") })
        let writer = try FileHandle(forWritingTo: url)
        try writer.write(contentsOf: Data("isp:1:pop\n".utf8))
        try writer.close()
        wait(for: [delivered], timeout: 2)

        first.remove()
        let next = try XCTUnwrap(TerminalControlPipe(directory: directory) { _ in })
        first.remove()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        next.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testReopensAnExistingFIFOForWritersThatAlreadyHaveItOpen() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("terminal-control")
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        let writer = try FileHandle(forUpdating: url)
        defer { try? writer.close() }
        let delivered = expectation(description: "existing writer reaches restarted app")
        let pipe = try XCTUnwrap(TerminalControlPipe(directory: directory) { lines in
            XCTAssertEqual(lines, "isp:2:pop\n")
            delivered.fulfill()
        })
        defer { pipe.remove() }
        try writer.write(contentsOf: Data("isp:2:pop\n".utf8))
        wait(for: [delivered], timeout: 2)
    }

    func testPreservesFilesAtStartupAndWhenThePathChangesBeforeRemoval() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("terminal-control")
        let text = "created while ISP was closed"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let pipe = try XCTUnwrap(TerminalControlPipe(directory: directory) { _ in })
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let saved = try XCTUnwrap(entries.first { $0.lastPathComponent.hasPrefix("terminal-control.") })
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), text)

        try FileManager.default.removeItem(at: url)
        try "replacement".write(to: url, atomically: true, encoding: .utf8)
        pipe.remove()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "replacement")
    }

    func testLeavesAnExistingSymlinkAlone() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("terminal-control")
        let destination = directory.appendingPathComponent("unrelated")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        XCTAssertNil(TerminalControlPipe(directory: directory) { _ in })
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), destination.path)
    }

    func testDeliveryWaitsForThePreviousBatchToFinish() async throws {
        let directory = try makeDirectory()
        let started = expectation(description: "first batch started")
        let overlapped = expectation(description: "second batch ran while the first was suspended")
        overlapped.isInverted = true
        let finished = expectation(description: "second batch finished")
        var resumeFirst: CheckedContinuation<Void, Never>?
        let pipe = try XCTUnwrap(TerminalControlPipe(directory: directory) { lines in
            if lines == "first\n" {
                await withCheckedContinuation {
                    resumeFirst = $0
                    started.fulfill()
                }
            } else {
                XCTAssertEqual(lines, "second\n")
                if resumeFirst != nil { overlapped.fulfill() }
                finished.fulfill()
            }
        })
        defer { pipe.remove() }
        let writer = try FileHandle(forWritingTo: directory.appendingPathComponent("terminal-control"))
        defer { try? writer.close() }
        try writer.write(contentsOf: Data("first\n".utf8))
        await fulfillment(of: [started], timeout: 2)
        try writer.write(contentsOf: Data("second\n".utf8))
        await fulfillment(of: [overlapped], timeout: 0.1)
        resumeFirst?.resume()
        resumeFirst = nil
        await fulfillment(of: [finished], timeout: 2)
    }
}
