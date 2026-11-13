import Combine
import Darwin
import XCTest
@testable import Input_Source_Pro

@MainActor
final class TerminalWatcherTests: XCTestCase {
    /// A watcher on fake polls, process table, zellij, connections and timers, all driven by hand.
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
        /// Processes that have exited.
        var ended: Set<pid_t> = []
        var zellijPane: Multiplexer.Pane?
        var zellijQueries: [String] = []
        var reachable: Set<TerminalWatcher.Connection> = []
        var attempts: [TerminalWatcher.Connection] = []
        var sends: [TerminalWatcher.Connection: (TerminalWatcher.ConnectionEvent) -> Void] = [:]
        var closed: [TerminalWatcher.Connection] = []
        var timers: [(seconds: TimeInterval, subject: PassthroughSubject<Date, Never>)] = []
        var refreshes = 0
        /// Refreshes that said the pane may have changed.
        var paneChanges = 0
        private var front: AnyCancellable?

        lazy var watcher = TerminalWatcher(
            environment: TerminalWatcher.Environment(
                poll: { [unowned self] interval, check, fire in
                    let poll = Poll(interval: interval, check: check, fire: fire)
                    polls.append(poll)
                    return AnyCancellable { poll.isCancelled = true }
                },
                foregroundPgid: { [unowned self] in foregroundPgids[$0] },
                isAlive: { [unowned self] in !ended.contains($0) },
                zellijPane: { [unowned self] session in
                    zellijQueries.append(session)
                    return zellijPane
                },
                connect: { [unowned self] connection, send in
                    attempts.append(connection)
                    guard reachable.contains(connection) else { return nil }
                    sends[connection] = send
                    return AnyCancellable { [weak self] in self?.closed.append(connection) }
                },
                // Weak: tearing the harness down leaves the front, which asks for the grace timer.
                delay: { [weak self] seconds in
                    let subject = PassthroughSubject<Date, Never>()
                    self?.timers.append((seconds, subject))
                    return subject.eraseToAnyPublisher()
                }
            ),
            refresh: { [unowned self] paneMayHaveChanged in
                refreshes += 1
                paneChanges += paneMayHaveChanged ? 1 : 0
            }
        )

        var livePolls: [Poll] { polls.filter { !$0.isCancelled && !$0.isDone } }

        func bringToFront(_ terminal: Terminal) {
            front = watcher.watching(terminal).sink { _ in }
        }

        func leaveFront() { front = nil }

        func tick() { livePolls.forEach { $0.tick() } }

        /// Fires the oldest pending timer, which must be for `seconds`.
        func fireTimer(_ seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
            guard !timers.isEmpty else { return XCTFail("No timer pending", file: file, line: line) }
            let timer = timers.removeFirst()
            XCTAssertEqual(timer.seconds, seconds, file: file, line: line)
            timer.subject.send(Date())
        }
    }

    private func trail(ttys: [(pid_t, pid_t)] = [], tmux: Bool = false, zellij: TerminalTrail.Zellij? = nil) -> TerminalTrail {
        TerminalTrail(ttys: ttys.map { TerminalTrail.TTY(pid: $0.0, foregroundPgid: $0.1) }, tmux: tmux, zellij: zellij)
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

    /// A program in its shell's own process group (a command in a startup file, a step
    /// of `sh -c 'a; b'`) ends without the foreground group changing.
    func testLibprocTriggersWhenTheProgramEndsInsideItsShellsGroup() {
        let harness = Harness()
        harness.foregroundPgids = [10: 100]
        harness.bringToFront(.ghostty)
        let reading = TerminalTrail(ttys: [TerminalTrail.TTY(pid: 10, foregroundPgid: 100, program: 11)])
        harness.watcher.follow(reading, for: .ghostty)

        harness.tick()
        XCTAssertEqual(harness.refreshes, 0, "Still running")
        harness.ended = [11]
        harness.tick()
        XCTAssertEqual([harness.refreshes, harness.paneChanges], [1, 0])

        // The lookup it caused reads a shell: nothing more to watch but the group.
        harness.watcher.follow(trail(ttys: [(10, 100)]), for: .ghostty)
        harness.tick()
        XCTAssertEqual(harness.refreshes, 1)
    }

    /// A script's foreground group stays while its commands come and go: only the first
    /// one read there is watched, so the script costs one more read, not one per command.
    func testOnlyTheFirstProgramOfAForegroundGroupIsWatched() {
        let harness = Harness()
        harness.foregroundPgids = [10: 100]
        harness.bringToFront(.ghostty)
        let reading = { (program: pid_t?) in TerminalTrail(ttys: [TerminalTrail.TTY(pid: 10, foregroundPgid: 100, program: program)]) }

        harness.watcher.follow(reading(11), for: .ghostty)
        harness.ended = [11]
        harness.tick()
        XCTAssertEqual(harness.refreshes, 1, "The first command ended")

        harness.watcher.follow(reading(12), for: .ghostty)
        harness.ended = [11, 12]
        harness.tick()
        harness.watcher.follow(reading(13), for: .ghostty)
        harness.ended = [11, 12, 13]
        harness.tick()
        XCTAssertEqual(harness.refreshes, 1, "The script's next commands are not watched")

        // Another foreground group (the script ended, the user ran something else) starts over.
        harness.foregroundPgids = [10: 200]
        harness.tick()
        XCTAssertEqual(harness.refreshes, 2)
        harness.watcher.follow(TerminalTrail(ttys: [TerminalTrail.TTY(pid: 10, foregroundPgid: 200, program: 21)]), for: .ghostty)
        harness.ended.insert(21)
        harness.tick()
        XCTAssertEqual(harness.refreshes, 3)
    }

    func testAliveMeansTheProcessExistsWhoeverOwnsIt() {
        XCTAssertTrue(TerminalTrail.isAlive(getpid()))
        XCTAssertTrue(TerminalTrail.isAlive(1), "launchd is root's")
        XCTAssertFalse(TerminalTrail.isAlive(pid_t.max))
    }

    func testTTYIsWatchedThroughItsEarliestReadableProcess() {
        let processes = [
            TerminalProcess(pid: 9, pgid: 9, foregroundPgid: 9, startTime: 3, comm: "nvim"),
            TerminalProcess(pid: 5, pgid: 5, foregroundPgid: 9, startTime: 1, comm: "login"),
            TerminalProcess(pid: 6, pgid: 6, foregroundPgid: 9, startTime: 2, comm: "zsh"),
        ]
        let rootLogin: pid_t = 5
        let tty = TerminalTrail.TTY(watching: processes) { $0 == rootLogin ? nil : 1 }

        XCTAssertEqual(tty, TerminalTrail.TTY(pid: 6, foregroundPgid: 9, program: 9), "Baseline is the table's value, not the new read")
        XCTAssertNil(TerminalTrail.TTY(watching: processes) { _ in nil })
    }

    func testLibprocReadsOwnProcess() {
        let pid = getpid()
        XCTAssertNotNil(TerminalTrail.foregroundPgid(ofPID: pid))
        XCTAssertNil(TerminalTrail.foregroundPgid(ofPID: -1))
    }

    // MARK: zellij

    func testZellijPollsItsClientListEveryHalfSecond() {
        let harness = Harness()
        let pane = Multiplexer.Pane.program(nil, label: "zellij:s/terminal_1")
        harness.zellijPane = pane
        harness.bringToFront(.ghostty)
        harness.watcher.follow(trail(ttys: [(10, 100)], zellij: TerminalTrail.Zellij(session: "s", pane: pane)), for: .ghostty)
        harness.foregroundPgids[10] = 100

        XCTAssertEqual(harness.livePolls.map(\.interval).sorted(), [TerminalWatcher.libprocInterval, TerminalWatcher.zellijInterval])
        XCTAssertEqual(TerminalWatcher.zellijInterval, 0.5)

        harness.tick()
        harness.zellijPane = nil // zellij didn't answer
        harness.tick()
        XCTAssertEqual(harness.refreshes, 0)
        XCTAssertEqual(harness.zellijQueries, ["s", "s"])

        harness.zellijPane = .program(TerminalProgram(key: "nvim", pane: "zellij:s/terminal_1"), label: "zellij:s/terminal_1")
        harness.tick()
        XCTAssertEqual(harness.refreshes, 1)
    }

    // MARK: Connections

    func testTmuxAttachesWithBackoffAndReconnectsAfterTheServerGoes() {
        let harness = Harness()
        harness.bringToFront(.ghostty)
        harness.watcher.follow(trail(tmux: true), for: .ghostty)
        XCTAssertTrue(harness.attempts.isEmpty, "The first attempt waits for its delay")

        harness.fireTimer(0.5)
        XCTAssertEqual(harness.attempts, [.tmux], "Server not up: retried")
        harness.reachable = [.tmux]
        harness.fireTimer(1)
        XCTAssertEqual(harness.attempts, [.tmux, .tmux])
        XCTAssertTrue(harness.timers.isEmpty, "Attached: no more retries")

        harness.watcher.follow(trail(tmux: true), for: .ghostty)
        XCTAssertEqual(harness.attempts.count, 2, "One connection per server")

        harness.sends[.tmux]?(.changed)
        XCTAssertEqual(harness.refreshes, 1)

        harness.sends[.tmux]?(.closed(wasReady: true))
        XCTAssertEqual(harness.closed, [.tmux])
        harness.fireTimer(0.5)
        XCTAssertEqual(harness.attempts.count, 3, "Lost after its handshake: attached again")
    }

    func testAServerThatStaysUnreachableIsGivenUpUntilTheNextLookup() {
        let harness = Harness()
        harness.bringToFront(.ghostty)
        harness.watcher.follow(trail(tmux: true), for: .ghostty)

        for seconds in [0.5, 1, 2, 4, 5, 5] {
            harness.fireTimer(seconds)
        }
        XCTAssertEqual(harness.attempts.count, TerminalWatcher.maxFailedAttempts)
        XCTAssertTrue(harness.timers.isEmpty, "No endless retry")

        harness.watcher.follow(trail(tmux: true), for: .ghostty)
        harness.reachable = [.tmux]
        harness.fireTimer(0.5)
        XCTAssertEqual(harness.attempts.count, TerminalWatcher.maxFailedAttempts + 1, "The next lookup through tmux starts over")
        harness.sends[.tmux]?(.changed)
        XCTAssertEqual(harness.refreshes, 1)
    }

    func testAConnectionRefusedBeforeItsHandshakeWaitsForTheNextLookup() {
        let harness = Harness()
        harness.reachable = [.tmux]
        harness.bringToFront(.ghostty)
        harness.watcher.follow(trail(tmux: true), for: .ghostty)
        harness.fireTimer(0.5)

        harness.sends[.tmux]?(.closed(wasReady: false))
        XCTAssertTrue(harness.timers.isEmpty, "No retry loop")

        harness.watcher.follow(trail(tmux: true), for: .ghostty)
        harness.fireTimer(0.5)
        XCTAssertEqual(harness.attempts.count, 2)
    }

    func testConnectionsDroppedBeforeTheirHandshakeBackOffFurtherEachTime() {
        let harness = Harness()
        harness.reachable = [.tmux]
        harness.bringToFront(.ghostty)
        harness.watcher.follow(trail(tmux: true), for: .ghostty)
        harness.fireTimer(0.5)

        // No handshake in time, or the server went away after it was found: each drop in a row waits longer.
        for (drop, seconds) in [1, 2, 4, 5, 5].enumerated() {
            harness.sends[.tmux]?(.dropped)
            XCTAssertEqual(harness.closed.count, drop + 1)
            harness.fireTimer(TimeInterval(seconds))
            XCTAssertEqual(harness.attempts.count, drop + 2, "Retried")
        }

        // A handshake ends the run: the next loss starts the backoff over.
        harness.sends[.tmux]?(.closed(wasReady: true))
        harness.fireTimer(0.5)
        XCTAssertEqual(harness.attempts.count, 7)
    }

    func testAServerThatNeverAnswersItsHandshakeIsGivenUpUntilTheNextLookup() {
        let harness = Harness()
        harness.reachable = [.tmux]
        harness.bringToFront(.ghostty)
        harness.watcher.follow(trail(tmux: true), for: .ghostty)
        harness.fireTimer(0.5)

        for seconds in [1, 2, 4, 5, 5] as [TimeInterval] {
            harness.sends[.tmux]?(.dropped)
            harness.fireTimer(seconds)
        }
        harness.sends[.tmux]?(.dropped)
        XCTAssertEqual(harness.attempts.count, TerminalWatcher.maxFailedAttempts)
        XCTAssertTrue(harness.timers.isEmpty, "No endless retry")

        harness.watcher.follow(trail(tmux: true), for: .ghostty)
        harness.fireTimer(0.5)
        XCTAssertEqual(harness.attempts.count, TerminalWatcher.maxFailedAttempts + 1)
    }

    func testAConnectionNoLookupGoesThroughIsClosedAfterTheGracePeriod() {
        let harness = Harness()
        harness.reachable = [.tmux]
        harness.bringToFront(.ghostty)
        harness.watcher.follow(trail(tmux: true), for: .ghostty)
        harness.fireTimer(0.5)

        // tmux detached: the terminal stays in front, its lookups no longer go through the server.
        harness.watcher.follow(trail(ttys: [(1, 1)]), for: .ghostty)
        XCTAssertTrue(harness.closed.isEmpty)
        harness.fireTimer(TerminalWatcher.connectionGrace)
        XCTAssertEqual(harness.closed, [.tmux])
    }

    func testOnlyAMultiplexerSaysThePaneMayHaveChanged() {
        let harness = Harness()
        harness.reachable = [.tmux]
        harness.foregroundPgids = [1: 1]
        harness.bringToFront(.ghostty)
        harness.watcher.follow(trail(ttys: [(1, 1)], tmux: true), for: .ghostty)
        harness.fireTimer(0.5)

        harness.foregroundPgids = [1: 2]
        harness.tick()
        XCTAssertEqual([harness.refreshes, harness.paneChanges], [1, 0], "A job started in the same pane")
        harness.sends[.tmux]?(.changed)
        XCTAssertEqual([harness.refreshes, harness.paneChanges], [2, 1])
    }

    func testConnectionsOutliveLeavingTheFrontForAGracePeriod() {
        let harness = Harness()
        harness.reachable = [.tmux]
        harness.bringToFront(.ghostty)
        harness.watcher.follow(trail(tmux: true), for: .ghostty)
        harness.fireTimer(0.5)
        XCTAssertEqual(harness.attempts, [.tmux])

        harness.leaveFront()
        harness.sends[.tmux]?(.changed)
        XCTAssertEqual(harness.refreshes, 0, "Not frontmost: events are ignored")
        XCTAssertTrue(harness.closed.isEmpty)

        harness.bringToFront(.ghostty)
        harness.fireTimer(TerminalWatcher.connectionGrace) // cancelled by coming back
        XCTAssertTrue(harness.closed.isEmpty, "Back in time: the connection is reused")
        XCTAssertEqual(harness.attempts.count, 1)
        harness.sends[.tmux]?(.changed)
        XCTAssertEqual(harness.refreshes, 1)

        harness.leaveFront()
        harness.fireTimer(TerminalWatcher.connectionGrace)
        XCTAssertEqual(harness.closed, [.tmux])
    }

    // MARK: Lines

    func testTmuxControlModeLines() {
        let parse = { (line: String) in TerminalWatcher.Line.tmux(Substring(line)) }
        XCTAssertEqual(parse("%end 1794042581 321 0"), .ready)
        XCTAssertEqual(parse("%window-pane-changed @0 %1"), .changed)
        XCTAssertEqual(parse("%session-window-changed $0 @1"), .changed)
        XCTAssertEqual(parse("%client-session-changed /dev/ttys003 $1 B"), .changed)
        XCTAssertEqual(parse("%session-changed $1 B"), .changed)
        for line in ["%begin 1794042581 321 0", "%sessions-changed", "%window-renamed @2 x", "%layout-change @0 x",
                     "%output %1 %window-pane-changed", "%exit", "", "window-pane-changed"] {
            XCTAssertNil(parse(line), line)
        }
    }

    func testStreamSendsOneChangePerReadThenClosed() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        var events: [TerminalWatcher.ConnectionEvent] = []
        let closed = expectation(description: "closed")
        let lock = NSLock()
        let stream = TerminalWatcher.Environment.stream(fd: fds[0], timeout: 5, parse: TerminalWatcher.Line.tmux, send: { event in
            lock.withLock { events.append(event) }
            if case .closed = event { closed.fulfill() }
        }, onClose: {})

        let lines = Array("%begin 1 1 0\n%end 1 1 0\n%session-changed $1 B\n%window-pane-changed @0 %1\n".utf8)
        XCTAssertEqual(write(fds[1], lines, lines.count), lines.count)
        close(fds[1])
        wait(for: [closed], timeout: 5)

        XCTAssertEqual(lock.withLock { events }, [.changed, .closed(wasReady: true)])
        stream.cancel()
    }

    /// Opening runs off the caller's thread: `attach` returns while `open` is
    /// still held, and `open` only goes on once the caller lets it.
    func testAttachReturnsBeforeItOpens() {
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "open finished")
        let lock = NSLock()
        var openedOnMain = true
        var released = DispatchTimeoutResult.timedOut

        let connection = TerminalWatcher.Environment.attach(timeout: 60, parse: TerminalWatcher.Line.tmux, send: { _ in }) {
            lock.withLock { openedOnMain = Thread.isMainThread }
            // Run in line, this would wait out its timeout: the signal comes only after `attach` returns.
            let result = release.wait(timeout: .now() + 5)
            lock.withLock { released = result }
            finished.fulfill()
            return nil
        }
        release.signal()
        wait(for: [finished], timeout: 5)
        lock.withLock {
            XCTAssertEqual(released, .success, "attach returned before open finished")
            XCTAssertFalse(openedOnMain)
        }
        connection.cancel()
    }

    /// Cancelled while it was opening: what opens is closed at once, and nothing is sent.
    func testAConnectionThatOpensAfterItsCancelIsClosed() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[1]) }
        let opening = expectation(description: "opening")
        let cancelled = DispatchSemaphore(value: 0)
        let closed = expectation(description: "closed")
        var events: [TerminalWatcher.ConnectionEvent] = []

        // A deadline past the test: anything sent would come from the cancel itself.
        let connection = TerminalWatcher.Environment.attach(timeout: 60, parse: TerminalWatcher.Line.tmux, send: { events.append($0) }) {
            opening.fulfill()
            _ = cancelled.wait(timeout: .now() + 5)
            return (fds[0], { closed.fulfill() })
        }
        guard XCTWaiter().wait(for: [opening], timeout: 5) == .completed else {
            cancelled.signal()
            connection.cancel()
            return XCTFail("open never ran")
        }
        connection.cancel()
        cancelled.signal()
        wait(for: [closed], timeout: 5)

        // Events hop to the main queue; one turn of it delivers any already sent.
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(events, [], "Nothing after cancel")
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

    /// A process the CLI leaves behind keeps the pipe open; the read must not wait for it.
    func testCLIOutputDoesNotWaitForAProcessLeftBehind() {
        let started = Date()
        let output = TerminalProcess.output(of: "/bin/sh", arguments: ["-c", "sleep 30 & echo done"])
        XCTAssertEqual(output, "done\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testExecutableIsTheFirstInstalledOne() {
        let installed: Set<String> = ["/usr/local/bin/tmux", "/opt/local/bin/tmux"]
        let find = { TerminalProcess.executable(named: $0, in: ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"], isExecutable: installed.contains) }
        XCTAssertEqual(find("tmux"), "/usr/local/bin/tmux")
        XCTAssertNil(find("zellij"))
        XCTAssertTrue(TerminalProcess.executableDirectories.contains("/usr/local/bin"))
    }

    /// Smoke test on real processes.
    func testCLIOutputOnlyOnSuccess() {
        XCTAssertEqual(TerminalProcess.output(of: "/bin/echo", arguments: ["a b", "c"]), "a b c\n")
        XCTAssertNil(TerminalProcess.output(of: "/usr/bin/false", arguments: []))
        XCTAssertNil(TerminalProcess.output(of: "/nonexistent", arguments: []))
    }

    // MARK: Live probe

    /// The live sources against throwaway servers that a driver script starts:
    /// it passes them as JSON in `ISP_TERMINAL_WATCH_PROBE` (through xcodebuild's
    /// `TEST_RUNNER_ISP_TERMINAL_WATCH_PROBE`). Skipped otherwise.
    func testLiveProbe() throws {
        guard let json = ProcessInfo.processInfo.environment["ISP_TERMINAL_WATCH_PROBE"] else {
            throw XCTSkip("Needs ISP_TERMINAL_WATCH_PROBE: live tmux and zellij servers")
        }
        struct Config: Decodable {
            let tmux: String
            let tmuxClient: String
            let zellij: String
        }
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        final class Counter { var refreshes = 0 }
        let counter = Counter()
        let watcher = TerminalWatcher(environment: .live(tmuxSocket: config.tmux), refresh: { _ in counter.refreshes += 1 })

        let tmux = { (arguments: [String]) in Self.cli("/opt/homebrew/bin/tmux", ["-L", config.tmux] + arguments) }
        let windowSize = { tmux(["display", "-p", "-t", "A", "#{window_width}x#{window_height}"]) }
        let controlClient = { Self.cli("/usr/bin/pgrep", ["-f", "tmux -L \(config.tmux) -C attach"]) }
        /// What a lookup of the frontmost pane would go through: tmux session A's active pane, zellij.
        func lookup(tty: Bool = true) -> TerminalTrail {
            var trail = TerminalTrail(tmux: true)
            if tty, let pid = pid_t(tmux(["display", "-p", "-t", "A", "#{pane_pid}"])),
               let foregroundPgid = TerminalTrail.foregroundPgid(ofPID: pid) {
                trail.ttys = [TerminalTrail.TTY(pid: pid, foregroundPgid: foregroundPgid)]
            }
            trail.zellij = Multiplexer.zellijPane(session: config.zellij).map { TerminalTrail.Zellij(session: config.zellij, pane: $0) }
            return trail
        }
        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func waitForRefresh(after count: Int, timeout: TimeInterval) -> TimeInterval? {
            let start = Date()
            while Date().timeIntervalSince(start) < timeout {
                if counter.refreshes > count { return Date().timeIntervalSince(start) }
                spin(0.002)
            }
            return nil
        }
        func step(_ name: String, expect: Bool = true, _ action: () -> Void) {
            watcher.follow(lookup(), for: .ghostty) // as the lookup a refresh causes would
            spin(0.3)
            let count = counter.refreshes
            action()
            let latency = waitForRefresh(after: count, timeout: expect ? 3 : 1)
            spin(0.3)
            let result = latency.map { "refresh after \(Int($0 * 1000)) ms (\(counter.refreshes - count) in all)" } ?? "no refresh"
            print("PROBE \(name): \(result)")
            if expect { XCTAssertNotNil(latency, name) } else { XCTAssertNil(latency, name) }
        }
        func idleCPU(_ name: String, seconds: TimeInterval) {
            var before = rusage(), childrenBefore = rusage(), after = rusage(), childrenAfter = rusage()
            let client = controlClient()
            let clientBefore = Self.cli("/bin/ps", ["-o", "time=", "-p", client])
            getrusage(RUSAGE_SELF, &before)
            getrusage(RUSAGE_CHILDREN, &childrenBefore)
            let start = Date()
            spin(seconds)
            let wall = Date().timeIntervalSince(start)
            getrusage(RUSAGE_SELF, &after)
            getrusage(RUSAGE_CHILDREN, &childrenAfter)
            func cpu(_ a: rusage, _ b: rusage) -> String {
                func t(_ v: timeval) -> Double { Double(v.tv_sec) + Double(v.tv_usec) / 1e6 }
                let used = t(b.ru_utime) + t(b.ru_stime) - t(a.ru_utime) - t(a.ru_stime)
                return String(format: "%.2f%%", used / wall * 100)
            }
            let clientTime = client.isEmpty ? "none" : "\(clientBefore) -> \(Self.cli("/bin/ps", ["-o", "time=", "-p", client]))"
            print("PROBE idle \(name) \(Int(wall))s: test host \(cpu(before, after)), reaped children (zellij CLI) \(cpu(childrenBefore, childrenAfter)), tmux control client cpu time \(clientTime)")
        }

        func cpuPerCall(_ name: String, _ body: () -> Void) {
            func now() -> Double {
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
            }
            body()
            let start = now()
            for _ in 0 ..< 20 { body() }
            print(String(format: "PROBE test host cpu per %@: %.2f ms", name, (now() - start) / 20 * 1000))
        }
        cpuPerCall("zellij client-list query") { _ = Multiplexer.zellijPane(session: config.zellij) }

        let sizeBefore = windowSize()
        var front: AnyCancellable? = watcher.watching(.ghostty).sink { _ in }
        watcher.follow(lookup(), for: .ghostty)
        let connected = waitForRefresh(after: 0, timeout: 5)
        spin(1)
        print("PROBE connect: first refresh after \(connected.map { "\(Int($0 * 1000)) ms" } ?? "none") (\(counter.refreshes) in all); control client pid \(controlClient())")
        print("PROBE window size: \(sizeBefore) before, \(windowSize()) with the control client")
        XCTAssertEqual(windowSize(), sizeBefore)

        step("libproc: job starts in the tmux pane") { tmux(["send-keys", "-t", "A", "sleep 2", "Enter"]) }
        step("libproc: job ends (the sleep 2 above)") {}
        step("tmux: select-pane") { tmux(["select-pane", "-t", "A:0.0"]) }
        step("tmux: select-window") { tmux(["select-window", "-t", "A:1"]) }
        step("tmux: switch-client to another session") { tmux(["switch-client", "-c", config.tmuxClient, "-t", "B"]) }
        step("tmux: switch-client back") { tmux(["switch-client", "-c", config.tmuxClient, "-t", "A"]) }
        step("tmux: rename-window (ignored)", expect: false) { tmux(["rename-window", "-t", "A:0", "renamed"]) }
        for direction in ["left", "right"] {
            step("zellij: move-focus \(direction)") { Self.cli("/opt/homebrew/bin/zellij", ["-s", config.zellij, "action", "move-focus", direction]) }
        }

        var withoutZellij = lookup()
        withoutZellij.zellij = nil
        watcher.follow(withoutZellij, for: .ghostty)
        spin(0.5)
        idleCPU("frontmost, libproc + tmux watched", seconds: 10)
        watcher.follow(lookup(), for: .ghostty)
        spin(0.5)
        idleCPU("frontmost, libproc + tmux + zellij watched", seconds: 10)

        front = nil
        step("left the front: select-window", expect: false) { tmux(["select-window", "-t", "A:0"]) }
        idleCPU("after leaving the front (grace, then closed)", seconds: TerminalWatcher.connectionGrace + 1)
        print("PROBE control client after the grace period: \(controlClient().isEmpty ? "gone" : "still running")")
        XCTAssertTrue(controlClient().isEmpty)

        let count = counter.refreshes
        front = watcher.watching(.ghostty).sink { _ in }
        let back = waitForRefresh(after: count, timeout: 5)
        print("PROBE back to the front: refresh after \(back.map { "\(Int($0 * 1000)) ms" } ?? "none") (reattached, picked up the stored trail)")

        watcher.follow(lookup(tty: false), for: .ghostty)
        spin(0.5)
        let beforeKill = counter.refreshes
        tmux(["kill-server"])
        spin(0.3)
        tmux(["-f", "/dev/null", "new-session", "-d", "-s", "A", "-x", "120", "-y", "40"])
        let reconnected = waitForRefresh(after: beforeKill, timeout: 10)
        print("PROBE tmux kill-server, new server 0.3 s later: refresh after \(reconnected.map { "\(Int($0 * 1000)) ms" } ?? "none"), control client pid \(controlClient())")
        XCTAssertNotNil(reconnected)
        front = nil
        _ = front
    }

    /// Runs `path` with the multiplexers' session variables removed, and returns its trimmed output.
    @discardableResult
    private static func cli(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !(key == "TMUX" || key == "TMUX_PANE" || key.hasPrefix("ZELLIJ"))
        }
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
