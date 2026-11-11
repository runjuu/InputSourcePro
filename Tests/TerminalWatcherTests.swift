import Combine
import XCTest
@testable import Input_Source_Pro

@MainActor
final class TerminalWatcherTests: XCTestCase {
    /// A watcher on fake polls and process table, driven by hand.
    @MainActor
    private final class Harness {
        final class Poll {
            let interval: TimeInterval
            let check: () -> String?
            let fire: (String) -> Void
            var isCancelled = false
            var isDone = false

            init(interval: TimeInterval, check: @escaping () -> String?, fire: @escaping (String) -> Void) {
                self.interval = interval
                self.check = check
                self.fire = fire
            }

            /// One timer tick, as the live poll runs it: a change fires once and ends the poll.
            func tick() {
                guard !isCancelled, !isDone, let change = check() else { return }
                isDone = true
                fire(change)
            }
        }

        var polls: [Poll] = []
        var foregroundPgids: [pid_t: pid_t] = [:]
        var refreshes = 0
        private var front: AnyCancellable?

        lazy var watcher = TerminalWatcher(
            environment: TerminalWatcher.Environment(
                poll: { [unowned self] interval, check, fire in
                    let poll = Poll(interval: interval, check: check, fire: fire)
                    polls.append(poll)
                    return AnyCancellable { poll.isCancelled = true }
                },
                foregroundPgid: { [unowned self] in foregroundPgids[$0] }
            ),
            refresh: { [unowned self] in refreshes += 1 }
        )

        var livePolls: [Poll] { polls.filter { !$0.isCancelled && !$0.isDone } }

        func bringToFront(_ terminal: Terminal) {
            front = watcher.watching(terminal).sink { _ in }
        }

        func leaveFront() { front = nil }

        func tick() { livePolls.forEach { $0.tick() } }
    }

    private func trail(ttys: [(pid_t, pid_t)] = []) -> TerminalTrail {
        TerminalTrail(ttys: ttys.map { TerminalTrail.TTY(pid: $0.0, foregroundPgid: $0.1) })
    }

    // MARK: Lifecycle

    func testWatchesOnlyWhileTheTerminalIsFrontmost() {
        let harness = Harness()
        harness.watcher.follow(trail(ttys: [(10, 100)]), for: .ghostty)
        XCTAssertTrue(harness.polls.isEmpty, "Not frontmost: nothing watched")

        harness.bringToFront(.ghostty)
        XCTAssertEqual(harness.livePolls.map(\.interval), [TerminalWatcher.libprocInterval], "Picks up the remembered trail")

        harness.watcher.follow(trail(ttys: [(20, 200)]), for: .iterm)
        XCTAssertEqual(harness.livePolls.count, 1, "Another terminal's lookup changes nothing")

        harness.leaveFront()
        XCTAssertTrue(harness.livePolls.isEmpty, "Leaving the front stops polling at once")

        harness.foregroundPgids[10] = 101
        harness.tick()
        XCTAssertEqual(harness.refreshes, 0)
    }

    func testANewLookupReplacesThePolls() {
        let harness = Harness()
        harness.bringToFront(.ghostty)
        harness.watcher.follow(trail(ttys: [(10, 100)]), for: .ghostty)
        let first = harness.livePolls
        harness.watcher.follow(trail(ttys: [(20, 200)]), for: .ghostty)

        XCTAssertTrue(first.allSatisfy(\.isCancelled))
        XCTAssertEqual(harness.livePolls.count, 1)
        first[0].fire("late") // already queued for the main thread when it was replaced
        XCTAssertEqual(harness.refreshes, 0, "A replaced poll's change is ignored")
    }

    // MARK: libproc

    func testLibprocTriggersOnlyWhenTheForegroundGroupChanges() {
        let harness = Harness()
        harness.foregroundPgids = [10: 100, 20: 200]
        harness.bringToFront(.ghostty)
        harness.watcher.follow(trail(ttys: [(10, 100), (20, 200)]), for: .ghostty)

        for _ in 0 ..< 5 { harness.tick() }
        XCTAssertEqual(harness.refreshes, 0, "Same numbers: nothing to do")

        harness.foregroundPgids[20] = 201
        harness.tick()
        harness.tick()
        XCTAssertEqual(harness.refreshes, 1, "A change fires once; the lookup it causes restarts the poll")
        XCTAssertTrue(harness.livePolls.isEmpty)

        harness.watcher.follow(trail(ttys: [(10, 100), (20, 201)]), for: .ghostty)
        harness.tick()
        XCTAssertEqual(harness.refreshes, 1)

        harness.foregroundPgids[10] = nil // the shell is gone
        harness.tick()
        XCTAssertEqual(harness.refreshes, 2)
    }

    func testTTYIsWatchedThroughItsEarliestReadableProcess() {
        let processes = [
            TerminalProcess(pid: 9, pgid: 9, foregroundPgid: 9, startTime: 3, comm: "nvim"),
            TerminalProcess(pid: 5, pgid: 5, foregroundPgid: 9, startTime: 1, comm: "login"),
            TerminalProcess(pid: 6, pgid: 6, foregroundPgid: 9, startTime: 2, comm: "zsh"),
        ]
        let rootLogin: pid_t = 5
        let tty = TerminalTrail.TTY(watching: processes) { $0 == rootLogin ? nil : 1 }

        XCTAssertEqual(tty, TerminalTrail.TTY(pid: 6, foregroundPgid: 9), "Baseline is the table's value, not the new read")
        XCTAssertNil(TerminalTrail.TTY(watching: processes) { _ in nil })
    }

    func testLibprocReadsOwnProcess() {
        let pid = getpid()
        XCTAssertNotNil(TerminalTrail.foregroundPgid(ofPID: pid))
        XCTAssertNil(TerminalTrail.foregroundPgid(ofPID: -1))
    }

    // MARK: CLI runs

    func testCLIOutputIsNilOnceTheWatchdogKillsIt() {
        var timeouts: [TimeInterval] = []
        let output = TerminalProcess.output(of: "/bin/sleep", arguments: ["30"], timeout: 0.5) { timeout, kill in
            timeouts.append(timeout)
            kill() // the deadline passes at once
        }
        XCTAssertNil(output, "Killed when it hangs")
        XCTAssertEqual(timeouts, [0.5])
    }

    /// Smoke test on real processes.
    func testCLIOutputOnlyOnSuccess() {
        XCTAssertEqual(TerminalProcess.output(of: "/bin/echo", arguments: ["a b", "c"]), "a b c\n")
        XCTAssertNil(TerminalProcess.output(of: "/usr/bin/false", arguments: []))
        XCTAssertNil(TerminalProcess.output(of: "/nonexistent", arguments: []))
    }
}
