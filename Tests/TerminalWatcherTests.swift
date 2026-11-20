import Combine
import Darwin
import JavaScriptCore
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

        /// One subscription to the Herdr mod.
        final class HerdrView {
            let report: (HerdrDesktop.Focus?) -> Void

            func send(_ pane: String?) { report(pane.map { .init(pane: $0, terminal: $0) }) }
            var isCancelled = false

            init(send: @escaping (HerdrDesktop.Focus?) -> Void) {
                self.report = send
            }
        }

        var polls: [Poll] = []
        var herdrViews: [HerdrView] = []
        /// Whether Herdr's view directory can be opened.
        var herdrViewOpens = true
        var foregroundPgids: [pid_t: pid_t] = [:]
        /// Processes that have exited.
        var ended: Set<pid_t> = []
        /// System uptime.
        var clock: TimeInterval = 1000
        var zellijPane: Multiplexer.Pane?
        var zellijQueries: [String] = []
        var reachable: Set<TerminalWatcher.Connection> = []
        var attempts: [TerminalWatcher.Connection] = []
        var sends: [TerminalWatcher.Connection: (TerminalWatcher.ConnectionEvent) -> Void] = [:]
        var closed: [TerminalWatcher.Connection] = []
        var timers: [(seconds: TimeInterval, subject: PassthroughSubject<Date, Never>)] = []
        var refreshes = 0
        var focusedHerdrPanes: [String?] = []
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
                now: { [unowned self] in clock },
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
                },
                herdrView: { [unowned self] _, send in
                    guard herdrViewOpens else { return nil }
                    let view = HerdrView(send: send)
                    herdrViews.append(view)
                    return AnyCancellable { view.isCancelled = true }
                }
            ),
            refresh: { [unowned self] paneMayHaveChanged in
                refreshes += 1
                paneChanges += paneMayHaveChanged ? 1 : 0
            },
            focusHerdr: { [unowned self] in focusedHerdrPanes.append($0.terminal) }
        )

        var livePolls: [Poll] { polls.filter { !$0.isCancelled && !$0.isDone } }

        func bringToFront(_ terminal: Terminal) {
            front = watcher.watching(terminal, pid: getpid()).sink { _ in }
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

    private func trail(ttys: [(pid_t, pid_t)] = [], tmux: Bool = false, herdr: [String] = [], zellij: TerminalTrail.Zellij? = nil) -> TerminalTrail {
        TerminalTrail(ttys: ttys.map { TerminalTrail.TTY(pid: $0.0, foregroundPgid: $0.1) }, tmux: tmux, herdrSockets: herdr, zellij: zellij)
    }

    // MARK: Lifecycle

    func testWatchesOnlyWhileTheTerminalIsFrontmost() {
        let harness = Harness()
        harness.watcher.follow(trail(ttys: [(10, 100)]), for: .ghostty)
        XCTAssertTrue(harness.polls.isEmpty, "Not frontmost: nothing watched")

        harness.bringToFront(.ghostty)
        XCTAssertEqual(harness.livePolls.map(\.interval), [TerminalWatcher.libprocInterval], "Picks up the remembered trail")

        harness.watcher.follow(trail(ttys: [(20, 200)]), for: .herdr)
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

    /// A script run by a shell (`sh install.sh`, `sh -c 'a; b'`) keeps its foreground group
    /// while its commands come and go. The first one's end is reported at once; one that
    /// follows it only after the cooldown, so the script costs a read every few seconds,
    /// not one per command.
    func testAProgramThatFollowsAnotherInItsGroupIsReportedAfterTheCooldown() {
        let harness = Harness()
        harness.foregroundPgids = [10: 100]
        harness.bringToFront(.ghostty)
        let reading = { (program: pid_t?) in TerminalTrail(ttys: [TerminalTrail.TTY(pid: 10, foregroundPgid: 100, program: program)]) }

        harness.watcher.follow(reading(11), for: .ghostty)
        harness.ended = [11]
        harness.tick()
        XCTAssertEqual(harness.refreshes, 1, "The first command ended")

        harness.watcher.follow(reading(12), for: .ghostty)
        harness.ended.insert(12)
        harness.tick()
        XCTAssertEqual(harness.refreshes, 1, "The next command ended within the cooldown")
        harness.clock += TerminalWatcher.programCooldown
        harness.tick()
        XCTAssertEqual(harness.refreshes, 2, "Reported once the cooldown is over")

        // A shell read in between (the script between two commands) does not start the group over.
        harness.watcher.follow(reading(nil), for: .ghostty)
        harness.watcher.follow(reading(13), for: .ghostty)
        harness.ended.insert(13)
        harness.tick()
        XCTAssertEqual(harness.refreshes, 2)

        // One that outlives the cooldown (an editor the script opens) is reported when it ends.
        harness.watcher.follow(reading(14), for: .ghostty)
        harness.clock += 60
        harness.tick()
        XCTAssertEqual(harness.refreshes, 2, "Still running")
        harness.ended.insert(14)
        harness.tick()
        XCTAssertEqual(harness.refreshes, 3)

        // Another foreground group (the script ended, the user ran something else) starts over.
        harness.foregroundPgids = [10: 200]
        harness.watcher.follow(TerminalTrail(ttys: [TerminalTrail.TTY(pid: 10, foregroundPgid: 200, program: 21)]), for: .ghostty)
        harness.ended.insert(21)
        harness.tick()
        XCTAssertEqual(harness.refreshes, 4)
    }

    /// The same program read again (the refresh's second read, a window-title probe once a
    /// second) must not push its report back, or a spinner in the title would hold it forever.
    func testReadingTheSameProgramAgainDoesNotRestartItsCooldown() {
        let harness = Harness()
        harness.foregroundPgids = [10: 100]
        harness.bringToFront(.ghostty)
        let reading = { (program: pid_t?) in TerminalTrail(ttys: [TerminalTrail.TTY(pid: 10, foregroundPgid: 100, program: program)]) }
        harness.watcher.follow(reading(11), for: .ghostty)
        harness.watcher.follow(reading(12), for: .ghostty)
        harness.ended = [12]

        for _ in 0 ..< 3 {
            harness.clock += TerminalWatcher.programCooldown / 2
            harness.watcher.follow(reading(12), for: .ghostty)
        }
        harness.tick()
        XCTAssertEqual(harness.refreshes, 1, "Reported a cooldown after it was first read, however often it was read since")
    }

    /// A tty the latest lookup did not go through is forgotten: read again, its program is a first one.
    func testAProgramOnATTYNoLongerReadIsAFirstOneAgain() {
        let harness = Harness()
        harness.foregroundPgids = [10: 100, 20: 200]
        harness.bringToFront(.ghostty)
        let pane = { (program: pid_t) in TerminalTrail(ttys: [TerminalTrail.TTY(pid: 10, foregroundPgid: 100, program: program)]) }
        harness.watcher.follow(pane(11), for: .ghostty)
        harness.watcher.follow(self.trail(ttys: [(20, 200)]), for: .ghostty) // another pane
        harness.watcher.follow(pane(12), for: .ghostty)
        harness.ended = [12]
        harness.tick()
        XCTAssertEqual(harness.refreshes, 1, "No cooldown: nothing is remembered of the pane's earlier program")
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

    // MARK: Herdr focus mod

    func testHerdrViewFocusesEachNewPane() throws {
        let harness = Harness()
        harness.bringToFront(.herdr)
        let view = try XCTUnwrap(harness.herdrViews.first)
        XCTAssertEqual(harness.herdrViews.count, 1)

        view.send("pA")
        XCTAssertEqual(harness.focusedHerdrPanes, ["pA"], "The first read is Herdr's focus on coming to the front")
        view.send("pA") // another file in the directory changed
        XCTAssertEqual(harness.focusedHerdrPanes, ["pA"])
        view.report(.init(pane: "pA", terminal: "sub-agent"))
        view.report(.init(pane: "pA", terminal: "pA"))
        view.report(.init(pane: "pB", terminal: nil))
        view.report(.init(pane: "pB", terminal: nil))
        XCTAssertEqual(harness.focusedHerdrPanes, ["pA", "sub-agent", "pA", nil])

        XCTAssertEqual(harness.refreshes, 0, "A pane switch is a focus, not a refresh of the remembered tty")

        harness.watcher.follow(trail(ttys: [(10, 100)]), for: .herdr)
        XCTAssertEqual(harness.herdrViews.count, 1, "A lookup leaves the view watch alone")
    }

    /// Coming to the front, the view watch's first read is the only lookup of
    /// Herdr's focus: a switch made right after it is a change from that read,
    /// never a baseline taken after another lookup already read the old pane.
    func testHerdrSwitchRightAfterComingToTheFrontIsFocused() throws {
        let harness = Harness()
        harness.bringToFront(.herdr)
        let view = try XCTUnwrap(harness.herdrViews.last)
        view.send("pA") // read on coming to the front
        view.send("pB") // switched at once
        XCTAssertEqual(harness.focusedHerdrPanes, ["pA", "pB"], "The latest focus is pB")
    }

    func testHerdrViewIsWatchedOnlyWhileHerdrIsFrontmost() throws {
        let harness = Harness()
        harness.bringToFront(.ghostty)
        XCTAssertTrue(harness.herdrViews.isEmpty, "Only Herdr's desktop app loads the mod")

        harness.bringToFront(.herdr)
        let first = try XCTUnwrap(harness.herdrViews.last)
        first.send(nil) // unreadable
        first.send("pA")
        XCTAssertEqual(harness.focusedHerdrPanes, ["pA"], "Focused once readable")

        harness.leaveFront()
        XCTAssertTrue(first.isCancelled, "Leaving the front stops at once")
        first.send("pB") // already queued for the main thread
        XCTAssertEqual(harness.focusedHerdrPanes, ["pA"])

        harness.bringToFront(.herdr)
        let second = try XCTUnwrap(harness.herdrViews.last)
        XCTAssertEqual(harness.herdrViews.count, 2)
        first.send("old") // still queued when the next instance came to the front
        second.send("pA")
        XCTAssertEqual(harness.focusedHerdrPanes, ["pA", "pA"], "Back in front: focused again, whatever was pushed meanwhile")
        second.send("pC")
        XCTAssertEqual(harness.focusedHerdrPanes, ["pA", "pA", "pC"])
    }

    /// Herdr's first launch: its directory isn't there yet, so the next time
    /// Herdr comes to the front the watch is tried again.
    func testAViewWatchThatCouldNotOpenIsTriedAgain() throws {
        let harness = Harness()
        harness.herdrViewOpens = false
        harness.bringToFront(.herdr)
        XCTAssertTrue(harness.herdrViews.isEmpty)

        harness.herdrViewOpens = true
        harness.leaveFront()
        harness.bringToFront(.herdr)
        try XCTUnwrap(harness.herdrViews.last).send("pA")
        XCTAssertEqual(harness.focusedHerdrPanes, ["pA"])
    }

    func testWatchDirectoryIsNilUntilTheDirectoryExists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var reads: [String?] = []
        let watch = { TerminalWatcher.Environment.watchDirectory(directory.path, read: { "pA" }, send: { reads.append($0) }) }
        XCTAssertNil(watch())

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let opened = try XCTUnwrap(watch())
        defer { opened.cancel() }
        waitUntil("the first read") { reads == ["pA"] }
    }

    /// The live watch on a real (temporary) directory: Herdr replaces its view
    /// file by rename, which the directory reports and the old file never would.
    func testWatchDirectorySeesAFileReplacedByRename() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("view.json")
        func view(_ pane: String) -> Data { Data(pane.utf8) }
        try view("pA").write(to: file)

        var reads: [String?] = []
        let watch = try XCTUnwrap(TerminalWatcher.Environment.watchDirectory(
            directory.path,
            read: { try? String(contentsOf: file, encoding: .utf8) },
            send: { reads.append($0) }
        ))
        defer { watch.cancel() }
        waitUntil("the first read") { reads == ["pA"] }

        try view("pB").write(to: file, options: .atomic) // a temporary file renamed over it
        waitUntil("a read after the rename") { reads.last == "pB" }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out: \(what)", file: file, line: line) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
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

    func testHerdrConnectionsOutliveLeavingTheFrontForAGracePeriod() {
        let socket = "/tmp/herdr.sock"
        let herdr = TerminalWatcher.Connection.herdr(socket: socket)
        let harness = Harness()
        harness.reachable = [herdr]
        harness.bringToFront(.ghostty)
        harness.watcher.follow(trail(herdr: [socket]), for: .ghostty)
        harness.fireTimer(0.5)
        XCTAssertEqual(harness.attempts, [herdr])

        harness.leaveFront()
        harness.sends[herdr]?(.changed)
        XCTAssertEqual(harness.refreshes, 0, "Not frontmost: events are ignored")
        XCTAssertTrue(harness.closed.isEmpty)

        harness.bringToFront(.ghostty)
        harness.fireTimer(TerminalWatcher.connectionGrace) // cancelled by coming back
        XCTAssertTrue(harness.closed.isEmpty, "Back in time: the connection is reused")
        XCTAssertEqual(harness.attempts.count, 1)
        harness.sends[herdr]?(.changed)
        XCTAssertEqual(harness.refreshes, 1)

        harness.leaveFront()
        harness.fireTimer(TerminalWatcher.connectionGrace)
        XCTAssertEqual(harness.closed, [herdr])
    }

    func testSwitchingHerdrSessionsExpiresOnlyTheDepartedSocket() {
        let a = TerminalWatcher.Connection.herdr(socket: "/A")
        let b = TerminalWatcher.Connection.herdr(socket: "/B")
        let h = Harness()
        h.reachable = [a, b]
        h.bringToFront(.ghostty)
        h.watcher.follow(trail(herdr: ["/A"]), for: .ghostty)
        h.fireTimer(0.5)
        h.watcher.follow(trail(herdr: ["/B"]), for: .ghostty)
        h.fireTimer(0.5)
        h.sends[a]?(.changed)
        h.sends[b]?(.ready)
        XCTAssertEqual(h.refreshes, 1)
        h.fireTimer(TerminalWatcher.connectionGrace)
        XCTAssertEqual(h.closed, [a])
        h.sends[b]?(.changed)
        XCTAssertEqual(h.refreshes, 2)
    }

    /// Read A, then subscribe: a switch made before the handshake sends no event,
    /// so the handshake itself reads the pane again, once.
    func testAHerdrHandshakeReadsThePaneAgain() {
        let socket = "/tmp/herdr.sock"
        let herdr = TerminalWatcher.Connection.herdr(socket: socket)
        let harness = Harness()
        harness.reachable = [herdr, .tmux]
        harness.bringToFront(.ghostty)
        harness.watcher.follow(trail(tmux: true, herdr: [socket]), for: .ghostty)
        harness.fireTimer(0.5)
        harness.fireTimer(0.5)

        harness.sends[herdr]?(.ready)
        XCTAssertEqual([harness.refreshes, harness.paneChanges], [1, 1])
        harness.sends[.tmux]?(.ready)
        XCTAssertEqual(harness.refreshes, 1, "tmux reports its attach as a session change")

        // That read's lookup goes through the same socket: no new connection, so no new handshake.
        harness.watcher.follow(trail(tmux: true, herdr: [socket]), for: .ghostty)
        XCTAssertEqual(harness.attempts.count, 2)
        XCTAssertTrue(harness.timers.isEmpty)
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

    func testHerdrsThreeFocusEventsCountOnce() {
        var buffer = Array("""
        {"id":"isp","result":{"type":"subscription_started"}}
        {"data":{"pane_id":"w1:p2","type":"pane_focused","workspace_id":"w1"},"event":"pane_focused"}
        {"data":{"tab_id":"w1:t2","type":"tab_focused"},"event":"tab_focused"}
        {"data":{"workspace_id":"w1","type":"workspace_focused"},"event":"workspace_focused"}
        {"data":{"pane_id":"w1:p3","type":"pane_focused"},"event":"pane_focused"}
        {"data":{"pane_id":
        """.utf8)
        var isReady = false

        XCTAssertTrue(TerminalWatcher.Line.scan(&buffer, isReady: &isReady, parse: TerminalWatcher.Line.herdr))
        XCTAssertTrue(isReady)
        XCTAssertEqual(String(decoding: buffer, as: UTF8.self), #"{"data":{"pane_id":"#, "A partial line waits for the rest")

        buffer += Array(#""w1:p4"},"event":"tab_focused"}"#.utf8) + [UInt8(ascii: "\n")]
        XCTAssertFalse(TerminalWatcher.Line.scan(&buffer, isReady: &isReady, parse: TerminalWatcher.Line.herdr))
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertNil(TerminalWatcher.Line.herdr(#"{"id":"isp","error":{"code":"bad"}}"#))
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

        XCTAssertEqual(lock.withLock { events }, [.ready, .changed, .closed(wasReady: true)])
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

        let connection = TerminalWatcher.Environment.attach(timeout: 60, parse: TerminalWatcher.Line.herdr, send: { _ in }) {
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

    func testHerdrDesktopConnectsOnlyToTheSpecifiedInstance() throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("herdr-app.sock")
        let listener = try XCTUnwrap(Self.listen(at: socket.path))
        defer { Darwin.close(listener) }
        let endpoint = try XCTUnwrap(HerdrDesktop.Endpoint.resolve(pid: getpid()))
        XCTAssertEqual(endpoint.socket.path, socket.path)
        XCTAssertNil(HerdrDesktop.Endpoint(pid: getpid() + 1, socket: socket).request(["status": true]))

        let served = expectation(description: "answered status for the process that owns the socket")
        DispatchQueue.global().async {
            // The client with the wrong PID connected and closed without sending a command.
            for _ in 0..<2 {
                let fd = Darwin.accept(listener, nil, nil)
                guard fd >= 0 else { break }
                var byte = UInt8(0)
                if Darwin.read(fd, &byte, 1) == 1 {
                    let reply = Array("{\"overlays\":[\"input-source-pro\"]}\n".utf8)
                    _ = Darwin.write(fd, reply, reply.count)
                }
                Darwin.close(fd)
            }
            served.fulfill()
        }
        XCTAssertTrue(endpoint.status()?.running == true)
        wait(for: [served], timeout: 2)
    }

    func testHerdrDesktopClearsAnObscuredPaneButRecognizesAFocusedPeek() {
        let name = HerdrDesktop.modName
        let pane = HerdrDesktop.Focus(pane: "p1", terminal: "t1")
        let peek = HerdrDesktop.Focus(pane: nil, terminal: "t2")
        XCTAssertEqual(HerdrDesktop.Status(overlays: [name]).focus(pane), pane)
        XCTAssertEqual(HerdrDesktop.Status(overlays: [name, "toast"]).focus(pane), pane)
        XCTAssertNil(HerdrDesktop.Status(overlays: [name, "settings", "toast"]).focus(pane)?.terminal)
        XCTAssertEqual(HerdrDesktop.Status(overlays: [name, "layout"]).focus(peek), peek)
        XCTAssertNil(HerdrDesktop.Status(overlays: [name, "layout"]).focus(pane)?.terminal)
        XCTAssertNil(HerdrDesktop.Status(overlays: [name, "layout", "settings"]).focus(peek)?.terminal)
        XCTAssertNil(HerdrDesktop.Status(overlays: ["settings"]).focus(pane))
    }

    /// A server that listens but never accepts: the missing handshake ends in `.dropped`.
    func testAServerThatNeverAnswersIsDropped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let server = try XCTUnwrap(Self.listen(at: path))
        defer { close(server) }

        let environment = TerminalWatcher.Environment.live(handshakeTimeout: 0.2)
        XCTAssertNil(environment.connect(.herdr(socket: directory.appendingPathComponent("none.sock").path)) { _ in },
                     "Nothing listens: nil at once")

        var events: [TerminalWatcher.ConnectionEvent] = []
        let dropped = expectation(description: "dropped")
        let connection = environment.connect(.herdr(socket: path)) { event in
            XCTAssertTrue(Thread.isMainThread)
            events.append(event)
            dropped.fulfill()
        }
        XCTAssertNotNil(connection)
        wait(for: [dropped], timeout: 5)
        XCTAssertEqual(events, [.dropped])
        connection?.cancel()
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

    /// A unix socket at `path` that listens and never accepts on its own.
    private static func listen(at path: String) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8.prefix($0.count - 1)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
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

    // MARK: herdr sessions

    func testChangingTheSavedMachinesRefreshesTheVisibleTUI() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("endpoints.json")
        let harness = Harness()
        harness.bringToFront(.ghostty)
        harness.watcher.follow(TerminalTrail(herdrCatalogs: [file.path: true]), for: .ghostty)
        harness.tick()
        XCTAssertEqual(harness.refreshes, 0)

        try Data(#"{"version":1,"ssh":[{"enabled":true}]}"#.utf8).write(to: file, options: .atomic)
        harness.tick()
        XCTAssertEqual(harness.paneChanges, 1)
        harness.watcher.follow(TerminalTrail(herdrCatalogs: [file.path: false]), for: .ghostty)
        harness.tick()
        XCTAssertEqual(harness.refreshes, 1)

        try Data(#"{"version":1,"ssh":[]}"#.utf8).write(to: file, options: .atomic)
        harness.tick()
        XCTAssertEqual(harness.paneChanges, 2)
    }

    func testHerdrRequiresOneDistinctClientConnection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("c.sock").path
        let server = try XCTUnwrap(Self.listen(at: path))
        defer { close(server) }
        let client = Multiplexer.HerdrClient(pid: getpid(), server: getpid(), socket: path)
        XCTAssertFalse(client.isOnlyClient())
        let first = try XCTUnwrap(TerminalWatcher.Environment.connectUnix(path))
        defer { close(first) }
        let a = accept(server, nil, nil)
        XCTAssertGreaterThanOrEqual(a, 0)
        defer { close(a) }
        let duplicate = dup(a)
        defer { close(duplicate) }
        XCTAssertTrue(client.isOnlyClient(), "Herdr duplicates its transport FDs")
        let second = try XCTUnwrap(TerminalWatcher.Environment.connectUnix(path))
        let b = accept(server, nil, nil)
        XCTAssertGreaterThanOrEqual(b, 0)
        XCTAssertFalse(client.isOnlyClient(), "Two clients can show different tabs")
        close(second)
        close(b)
        XCTAssertTrue(client.isOnlyClient())
    }

    func testHerdrSessionFromItsClientArguments() {
        XCTAssertNil(Multiplexer.HerdrLaunch(arguments: ["herdr"])?.session)
        XCTAssertEqual(Multiplexer.HerdrLaunch(arguments: ["herdr", "--session", "work"])?.session, "work")
        XCTAssertEqual(Multiplexer.HerdrLaunch(arguments: ["herdr", "--session=work"])?.session, "work")
        XCTAssertEqual(Multiplexer.HerdrLaunch(arguments: ["herdr", "session", "attach", "work"])?.session, "work")
        XCTAssertNil(Multiplexer.HerdrLaunch(arguments: ["herdr", "session", "attach"]))

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(Multiplexer.herdrSocket(session: nil), home + "/.config/herdr/herdr.sock")
        XCTAssertEqual(Multiplexer.herdrSocket(session: "work"), home + "/.config/herdr/sessions/work/herdr.sock")
        XCTAssertNil(Multiplexer.herdrSocket(session: ".."))
        XCTAssertNil(Multiplexer.herdrSocket(session: "a/b"))
    }

    // MARK: Live probe

    /// The live sources against throwaway servers that a driver script starts:
    /// it passes them as JSON in `ISP_TERMINAL_WATCH_PROBE` (through xcodebuild's
    /// `TEST_RUNNER_ISP_TERMINAL_WATCH_PROBE`). Skipped otherwise.
    func testLiveProbe() throws {
        guard let json = ProcessInfo.processInfo.environment["ISP_TERMINAL_WATCH_PROBE"] else {
            throw XCTSkip("Needs ISP_TERMINAL_WATCH_PROBE: live tmux, zellij and herdr servers")
        }
        struct Config: Decodable {
            let tmux: String
            let tmuxClient: String
            let zellij: String
            let herdr: String?
            let herdrPanes: [[String]]?
            let herdrTabs: [[String]]?
        }
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        final class Counter { var refreshes = 0 }
        let counter = Counter()
        let watcher = TerminalWatcher(environment: .live(tmuxSocket: config.tmux), refresh: { _ in counter.refreshes += 1 }, focusHerdr: { _ in })

        let tmux = { (arguments: [String]) in Self.cli("/opt/homebrew/bin/tmux", ["-L", config.tmux] + arguments) }
        let windowSize = { tmux(["display", "-p", "-t", "A", "#{window_width}x#{window_height}"]) }
        let controlClient = { Self.cli("/usr/bin/pgrep", ["-f", "tmux -L \(config.tmux) -C attach"]) }
        /// What a lookup of the frontmost pane would go through: tmux session A's active pane, herdr, zellij.
        func lookup(tty: Bool = true) -> TerminalTrail {
            var trail = TerminalTrail(tmux: true)
            if tty, let pid = pid_t(tmux(["display", "-p", "-t", "A", "#{pane_pid}"])),
               let foregroundPgid = TerminalTrail.foregroundPgid(ofPID: pid) {
                trail.ttys = [TerminalTrail.TTY(pid: pid, foregroundPgid: foregroundPgid)]
            }
            if let session = config.herdr, let socket = Multiplexer.herdrSocket(session: session) {
                trail.herdrSockets = [socket]
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
        var front: AnyCancellable? = watcher.watching(.ghostty, pid: getpid()).sink { _ in }
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
        if config.herdr != nil {
            let cli = try XCTUnwrap(Multiplexer.herdr.executable)
            for (index, arguments) in (config.herdrPanes ?? []).enumerated() {
                step("herdr: pane focus #\(index + 1)") { Self.cli(cli, arguments) }
            }
            for (index, arguments) in (config.herdrTabs ?? []).enumerated() {
                step("herdr: tab focus #\(index + 1)") { Self.cli(cli, arguments) }
            }
        }
        for direction in ["left", "right"] {
            step("zellij: move-focus \(direction)") { Self.cli("/opt/homebrew/bin/zellij", ["-s", config.zellij, "action", "move-focus", direction]) }
        }

        var withoutZellij = lookup()
        withoutZellij.zellij = nil
        watcher.follow(withoutZellij, for: .ghostty)
        spin(0.5)
        idleCPU("frontmost, libproc + tmux + herdr watched", seconds: 10)
        watcher.follow(lookup(), for: .ghostty)
        spin(0.5)
        idleCPU("frontmost, libproc + tmux + herdr + zellij watched", seconds: 10)

        front = nil
        step("left the front: select-window", expect: false) { tmux(["select-window", "-t", "A:0"]) }
        idleCPU("after leaving the front (grace, then closed)", seconds: TerminalWatcher.connectionGrace + 1)
        print("PROBE control client after the grace period: \(controlClient().isEmpty ? "gone" : "still running")")
        XCTAssertTrue(controlClient().isEmpty)

        let count = counter.refreshes
        front = watcher.watching(.ghostty, pid: getpid()).sink { _ in }
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

    func testBundledHerdrModReportsTheTerminalReceivingTheKeyboard() throws {
        let resource = try XCTUnwrap(Bundle.main.url(forResource: HerdrDesktop.modName, withExtension: nil))
        // JavaScriptCore supplies the language runtime. Replace the two host modules
        // with the live snapshots and shared-state sink the mod reads and writes.
        let source = try String(contentsOf: resource.appendingPathComponent("main.js"), encoding: .utf8)
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("import ") }
            .joined(separator: "\n")
            .replacingOccurrences(of: "export default ", with: "")
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, error in XCTFail(error?.toString() ?? "JavaScript exception") }
        let resolve = try XCTUnwrap(context.evaluateScript("""
            class View {}
            let snapshot, tree, report;
            const focused = () => snapshot;
            const layout = () => tree;
            const terminals = () => [];
            const setShared = (_, value) => { report = value; };
            \(source)
            const mod = new InputSourceFocus();
            (focus, root) => {
                snapshot = focus;
                tree = root;
                mod.publish("query", "test");
                return report.focus.terminal;
            }
            """))
        func address(_ focus: [String: String], in tree: [String: Any]) -> String? {
            let value = resolve.call(withArguments: [focus, tree])
            return value?.isNull == true ? nil : value?.toString()
        }

        let focus = ["pane": "p1", "terminal": "t1", "agent": "t2"]
        let tab: [String: Any] = ["id": "panes", "type": "block", "content": ["tab": "active"]]
        let agent: [String: Any] = ["id": "agents", "type": "block", "content": ["agent": "focused"]]
        XCTAssertEqual(address(focus, in: tab), "t1")
        XCTAssertEqual(address(focus.merging(["shown": "t3"]) { $1 }, in: tab), "t3")
        XCTAssertEqual(address(["terminal": "t3"], in: tab), "t3", "A peek reports its own terminal with no model pane")
        XCTAssertEqual(address(focus, in: ["type": "stack", "active": "panes", "children": [tab, agent]]), "t1")
        XCTAssertEqual(address(focus, in: ["type": "stack", "active": "agents", "children": [tab, agent]]), "t2")
        XCTAssertNil(address(focus, in: ["type": "row", "children": [tab, agent]]))
        XCTAssertEqual(address(["terminal": "t3"], in: ["type": "row", "children": [tab, agent]]), "t3")
        let float = ["content": ["terminal": "t3"]]
        XCTAssertNil(address(focus, in: tab.merging(["floating": [float]]) { $1 }))
        XCTAssertEqual(address(focus, in: tab.merging(["floating": [["hidden": true, "content": ["terminal": "t3"]]]]) { $1 }), "t1")
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
            !(key == "TMUX" || key == "TMUX_PANE" || key.hasPrefix("HERDR") || key.hasPrefix("ZELLIJ"))
        }
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
