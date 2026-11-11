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

    func testRefreshReadsTheRememberedTTYUntilItIsForgotten() {
        TerminalProcess.queue.sync {
            // /dev/null runs no foreground job, so it reads as a shell prompt in that pane.
            let shell = TerminalReading(program: nil, pane: "/dev/null")
            XCTAssertEqual(Terminal.ghostty.focusedProgram(onTTY: "/dev/null"), shell)
            XCTAssertEqual(Terminal.ghostty.refreshedProgram(), shell)

            XCTAssertEqual(Terminal.ghostty.focusedProgram(onTTY: nil), TerminalReading(program: nil, pane: nil))
        }
    }
}

@MainActor
final class AppKindTerminalTests: XCTestCase {
    private let app = NSRunningApplication.current

    private func terminal(_ program: TerminalProgram, rule: TerminalRule? = nil) -> AppKind {
        .terminal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: true, program: program, rule: rule)
        )
    }

    func testIdUsesMatchedRuleOrProgram() throws {
        let bundleId = try XCTUnwrap(app.bundleId())
        let rule = TerminalRule(program: "claude")

        XCTAssertEqual(
            terminal(TerminalProgram(key: "claude", name: "Claude Code"), rule: rule).getId(),
            "\(bundleId)_\(rule.id.uuidString)"
        )
        XCTAssertEqual(
            terminal(TerminalProgram(key: "program", name: "htop")).getId(),
            "\(bundleId)_program/htop"
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

    func testProgramIdLeavesOutPane() throws {
        let bundleId = try XCTUnwrap(app.bundleId())
        let program = TerminalProgram(key: "claude", name: "2.1.318", pane: "/dev/ttys008")

        XCTAssertEqual(program.id, "claude/2.1.318")
        XCTAssertEqual(terminal(program).getId(), "\(bundleId)_claude/2.1.318")
        XCTAssertEqual(terminal(program).getId(), terminal(TerminalProgram(key: "claude", name: "2.1.318", pane: "/dev/ttys009")).getId())
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
