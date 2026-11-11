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
        let table: [pid_t: (ppid: pid_t, tty: String?)] = [
            10: (9, nil), 9: (8, "/dev/ttys1"), 8: (7, "/dev/ttys0"),
            20: (19, nil), 19: (18, nil), 18: (17, nil), 17: (16, nil), 16: (15, "/dev/ttys2"),
            30: (1, nil),
        ]
        func owner(_ pid: pid_t, depth: Int = 4) -> pid_t? {
            TerminalProcess.ttyOwner(ofPID: pid, maxDepth: depth) { table[$0] }?.pid
        }
        XCTAssertEqual(owner(8), 8) // has a tty itself
        XCTAssertEqual(owner(10), 9) // the nearest one wins
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
            XCTAssertEqual(Terminal.ghostty.focusedProgram(onTTY: "/dev/null"), shell)
            XCTAssertEqual(Terminal.ghostty.refreshedProgram(), shell)
            XCTAssertEqual(Terminal.ghostty.focusedTTY, "/dev/null")

            XCTAssertEqual(Terminal.ghostty.focusedProgram(onTTY: nil), TerminalReading(program: nil, pane: nil))
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
        XCTAssertNil(Multiplexer.zellijSession(fromSocketPeers: ["/tmp/tmux-501/default", ""]))
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
            for: .ghostty,
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
    func testWezTermFocusedPaneComesFromTheFirstClient() {
        let clients = """
        [{"pid": 46286, "workspace": "default", "focused_pane_id": 2},
         {"pid": 51000, "workspace": "default", "focused_pane_id": 7}]
        """

        XCTAssertEqual(TerminalProbe.focusedPaneID(fromClients: clients), 2)
        XCTAssertNil(TerminalProbe.focusedPaneID(fromClients: "[]"))
        XCTAssertNil(TerminalProbe.focusedPaneID(fromClients: "Error: failed to connect"))
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

    func testAlacrittyWindowTitlePicksTheTTYWhoseProgramItNames() {
        let shell = (tty: "/dev/ttys017", program: TerminalProgram?.none)
        let claude = (tty: "/dev/ttys018", program: Optional(TerminalProgram(key: "claude", name: "2.1.318")))

        XCTAssertEqual(TerminalProbe.tty(titled: nil, among: [shell]), shell.tty)
        XCTAssertEqual(TerminalProbe.tty(titled: "✳ Claude Code", among: [shell, claude]), claude.tty)
        XCTAssertNil(TerminalProbe.tty(titled: "user@host: ~", among: [shell, claude]))
        XCTAssertNil(TerminalProbe.tty(titled: nil, among: [shell, claude]))
        XCTAssertNil(TerminalProbe.tty(titled: "claude", among: []))
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
    private let tty = "/dev/ttys001"

    func testSelectTakesControlAndSetsCurrent() {
        XCTAssertFalse(control.isControlled(tty))
        control.select("abc", on: tty, pid: 10)

        XCTAssertTrue(control.isControlled(tty))
        XCTAssertEqual(control.current(on: tty), "abc")
    }

    func testPushStacksCurrentThenPopReturnsToIt() {
        control.select("rime", on: tty, pid: 10)
        control.push("abc", on: tty, pid: 10, live: "other")

        XCTAssertEqual(control.current(on: tty), "abc")
        XCTAssertEqual(control.pop(on: tty, pid: 10), "rime")
        XCTAssertEqual(control.current(on: tty), "rime")
    }

    func testFirstPushStacksTheLiveSource() {
        control.push("abc", on: tty, pid: 10, live: "rime")

        XCTAssertEqual(control.pop(on: tty, pid: 10), "rime")
    }

    func testUnfocusedFirstPushStacksNothing() {
        control.push("abc", on: tty, pid: 10, live: nil)

        XCTAssertTrue(control.isControlled(tty))
        XCTAssertNil(control.pop(on: tty, pid: 10))
        XCTAssertEqual(control.current(on: tty), "abc")
    }

    func testPopOnEmptyStackChangesNothing() {
        XCTAssertNil(control.pop(on: tty, pid: 10))
        XCTAssertFalse(control.isControlled(tty))

        control.select("abc", on: tty, pid: 10)
        XCTAssertNil(control.pop(on: tty, pid: 10))
        XCTAssertEqual(control.current(on: tty), "abc")
    }

    func testStackKeepsTheNewestSixteen() {
        control.select("0", on: tty, pid: 10)
        for n in 1...20 { control.push("\(n)", on: tty, pid: 10, live: nil) }

        var popped: [String] = []
        while let source = control.pop(on: tty, pid: 10) { popped.append(source) }
        XCTAssertEqual(popped.count, TerminalControlTracker<String>.maxStack)
        XCTAssertEqual(popped.first, "19")
        XCTAssertEqual(popped.last, "4")
    }

    func testManualChangeUpdatesCurrentOnlyOfControlledPanes() {
        control.select("rime", on: tty, pid: 10)
        control.follow("abc", on: tty)
        control.follow("abc", on: "/dev/ttys009")

        XCTAssertEqual(control.current(on: tty), "abc")
        XCTAssertFalse(control.isControlled("/dev/ttys009"))
    }

    func testReleaseDropsStateOfThatTTYOnly() {
        control.select("rime", on: tty, pid: 10)
        control.select("abc", on: "/dev/ttys002", pid: 11)
        control.release(tty)

        XCTAssertFalse(control.isControlled(tty))
        XCTAssertNil(control.current(on: tty))
        XCTAssertEqual(control.current(on: "/dev/ttys002"), "abc")
    }

    func testAReadingKeepsControlWhileTheProgramIsInTheForeground() {
        control.push("abc", on: tty, pid: 10, live: "rime")
        control.check(tty) { pid, onTTY in pid == 10 && onTTY == self.tty ? .foreground : .gone }

        XCTAssertTrue(control.isControlled(tty))
        XCTAssertEqual(control.current(on: tty), "abc")
        XCTAssertEqual(control.pop(on: tty, pid: 10), "rime")
    }

    /// Whatever the reading shows, a shell or another program, control ends with its process.
    func testAReadingReleasesOnceTheProgramIsGone() {
        control.select("abc", on: tty, pid: 10)
        control.check(tty) { _, _ in .gone }

        XCTAssertFalse(control.isControlled(tty))
        XCTAssertNil(control.current(on: tty))
        control.check("/dev/ttys009") { _, _ in .gone }
    }

    /// Ctrl-Z: the shell (or what runs next) gets the rules, and `current` waits for `fg`.
    func testASuspendedProgramDoesNotControlItsPaneUntilItResumes() {
        control.select("abc", on: tty, pid: 10)
        control.check(tty) { _, _ in .background }

        XCTAssertFalse(control.isControlled(tty))
        control.follow("rime", on: tty)
        XCTAssertEqual(control.current(on: tty), "abc")

        control.check(tty) { _, _ in .foreground }
        XCTAssertTrue(control.isControlled(tty))
        XCTAssertEqual(control.current(on: tty), "abc")
    }

    func testACommandResumesASuspendedProgram() {
        control.select("abc", on: tty, pid: 10)
        control.check(tty) { _, _ in .background }
        control.push("rime", on: tty, pid: 10, live: nil)

        XCTAssertTrue(control.isControlled(tty))
        XCTAssertEqual(control.pop(on: tty, pid: 10), "abc")

        control.check(tty) { _, _ in .background }
        control.select("rime", on: tty, pid: 10)
        XCTAssertTrue(control.isControlled(tty))
    }

    func testAnotherPIDTakesOverTheTTY() {
        control.select("abc", on: tty, pid: 10)
        control.select("rime", on: tty, pid: 20)
        control.check(tty) { pid, _ in pid == 20 ? .foreground : .gone }

        XCTAssertEqual(control.current(on: tty), "rime")
        control.check(tty) { pid, _ in pid == 10 ? .foreground : .gone }
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
