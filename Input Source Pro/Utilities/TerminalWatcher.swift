import Combine
import Darwin
import Foundation

/// What a terminal lookup went through: the ttys it read and the multiplexers
/// that answered. `TerminalWatcher` watches these until the next lookup.
struct TerminalTrail: Equatable {
    /// A tty that was read: a process on it that ISP can read (the earliest
    /// started, normally the shell; a `login` session leader belongs to root),
    /// and the tty's foreground process group when it was read. `program` is the
    /// process read as the tty's program, if any: one that runs in its shell's own
    /// process group (a command in a startup file, a step of `sh -c 'a; b'`) ends
    /// without the foreground group changing.
    struct TTY: Equatable {
        let pid: pid_t
        let foregroundPgid: pid_t
        var program: pid_t?
    }

    /// Whether `pid` still exists; another user's process (a program under `sudo`) does.
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// The zellij session asked, and the focused pane it answered.
    struct Zellij: Equatable {
        let session: String
        let pane: Multiplexer.Pane
    }

    var ttys: [TTY] = []
    /// The default tmux server answered.
    var tmux = false
    /// Sockets used by the herdr TUI clients on this trail.
    var herdrSockets: [String] = []
    /// Herdr's SSH catalogs on the trail and whether each allowed a local pane lookup.
    var herdrCatalogs: [String: Bool] = [:]
    var herdrClients: [Multiplexer.HerdrClient: Bool] = [:]
    /// Herdr emits no event for popup terminals; their PTY master appears and disappears.
    var herdrMasters: [pid_t: Set<UInt32>] = [:]
    var herdrInventoryIncomplete = false
    var zellij: Zellij?

    /// The foreground process group of `pid`'s controlling tty, from libproc;
    /// nil when `pid` is gone or can't be read (another user's, e.g. root's `login`).
    static func foregroundPgid(ofPID pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(bitPattern: info.e_tpgid)
    }
}

extension TerminalTrail.TTY {
    /// The tty `processes` (one tty's process table) are on, watched through its
    /// earliest-started process that `read` can read; nil when there is none.
    init?(watching processes: [TerminalProcess], foregroundPgid read: (pid_t) -> pid_t?) {
        guard let process = processes
            .sorted(by: { ($0.startTime, $0.pid) < ($1.startTime, $1.pid) })
            .first(where: { read($0.pid) != nil })
        else { return nil }
        // The table's value, not a new read: a job started since the lookup must still count as a change.
        self.init(
            pid: process.pid,
            foregroundPgid: process.foregroundPgid,
            program: TerminalProcess.foregroundProcess(in: processes)?.pid
        )
    }
}

/// Notices changes in the frontmost terminal's focused pane without shell
/// hooks or plugins, and calls `refresh` so the pane is read again (Herdr's
/// mod calls `focusHerdr` with the pane and displayed terminal):
/// - libproc: each tty the last lookup read, for a job starting or ending, and the
///   program read on it, for one that ends inside its shell's process group;
/// - tmux: a control-mode client, for pane, window and session switches;
/// - herdr TUI: pane focus and workspace/tab creation or closure on the session socket;
/// - zellij: its client list, polled, since it has neither ttys nor events;
/// - Herdr's desktop app: its focus mod, for pane, tab, space and displayed-terminal changes.
///
/// Watches only while a terminal with Terminal Rules is frontmost (`watching`).
/// Each lookup's trail is handed to `follow`, which replaces the polls with
/// ones for the new trail. A poll fires once; the lookup it causes restarts
/// it. Connections stay open while the terminal is frontmost, and for
/// `connectionGrace` after it leaves, so switching back reuses them.
@MainActor
final class TerminalWatcher {
    enum Connection: Hashable {
        case tmux
        case herdr(socket: String)
    }

    /// What a connection reports, on the main thread. `ready`: its server
    /// answered the handshake. `wasReady`: it had, before the connection
    /// closed. `dropped`: it gave up before the handshake for a reason worth
    /// retrying (no answer in time, or the server went away since it was found).
    enum ConnectionEvent: Equatable {
        case ready
        case changed
        case closed(wasReady: Bool)
        case dropped
    }

    struct Environment {
        /// Calls `check` every `interval` seconds off the main thread until it
        /// returns a change or is cancelled; `fire` then gets the change once,
        /// on the main thread.
        var poll: (_ interval: TimeInterval, _ check: @escaping () -> String?, _ fire: @escaping (String) -> Void) -> AnyCancellable
        var foregroundPgid: (pid_t) -> pid_t?
        var isAlive: (pid_t) -> Bool
        /// System uptime.
        var now: () -> TimeInterval
        var zellijPane: (_ session: String) -> Multiplexer.Pane?
        /// Opens a connection without waiting on it, or nil when its server can't be reached.
        var connect: (Connection, _ send: @escaping (ConnectionEvent) -> Void) -> AnyCancellable?
        var delay: (TimeInterval) -> AnyPublisher<Date, Never>
        /// Focus reports from Herdr's mod, delivered on the main thread until cancellation.
        var herdrView: (_ pid: pid_t, _ send: @escaping (HerdrDesktop.Focus?) -> Void) -> AnyCancellable?
    }

    static let libprocInterval: TimeInterval = 0.1
    static let zellijInterval: TimeInterval = 0.5
    static let connectionGrace: TimeInterval = 10
    /// How long after it was first read a program that follows another in the same
    /// foreground group may end unreported.
    static let programCooldown: TimeInterval = 2
    /// Attempts in a row that find no server, or get no handshake from it, before giving up on it.
    static let maxFailedAttempts = 6

    /// The wait before an attempt that follows `failures` failed ones: 0.5s, doubling up to 5s.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        min(0.5 * pow(2, Double(failures)), 5)
    }

    private let environment: Environment
    /// `paneMayHaveChanged`: a multiplexer reported the change, not a job starting or ending on a tty.
    private let refresh: (_ paneMayHaveChanged: Bool) -> Void
    private let focusHerdr: (HerdrDesktop.Focus) -> Void

    private var active: Terminal?
    /// Counts `watching` subscriptions, so a late cancel of an earlier one is ignored.
    private var session = 0
    /// Each terminal's latest trail, picked up again when it comes to the front.
    private var trails: [Terminal: TerminalTrail] = [:]
    private var polls: [AnyCancellable] = []
    /// Counts poll sets, so a change fired by a replaced poll is ignored.
    private var pollGeneration = 0
    private var watchedPIDs: [pid_t] = []
    /// Per watched tty (by its `pid`): the foreground group it was read in, the program
    /// watched there, and the uptime before which that program's end is not reported. The
    /// first program of a group is reported at once; one that follows it in the same group
    /// only `programCooldown` after it was first read. A script keeps its group while its
    /// commands come and go, and reporting each at once would read the pane for every one.
    /// Entries follow the latest lookup's ttys: kept while no tty is watched (leaving a
    /// terminal and coming straight back does not start over), dropped for a tty the
    /// latest lookup did not go through.
    private var watchedPrograms: [pid_t: (foregroundPgid: pid_t, program: pid_t, notBefore: TimeInterval)] = [:]
    private var watchedZellij: String?
    private var connections: [Connection: AnyCancellable] = [:]
    /// Attaches dropped in a row since a connection's last handshake; each one waits longer.
    private var drops: [Connection: Int] = [:]
    private var activeConnections = Set<Connection>()
    private var closing: [Connection: AnyCancellable] = [:]
    private var herdrView: AnyCancellable?
    /// The last pane and displayed terminal reported in the current watch.
    private var herdrPane: HerdrDesktop.Focus?

    init(
        environment: Environment = .live(),
        refresh: @escaping (_ paneMayHaveChanged: Bool) -> Void,
        focusHerdr: @escaping (HerdrDesktop.Focus) -> Void
    ) {
        self.environment = environment
        self.refresh = refresh
        self.focusHerdr = focusHerdr
    }

    /// Watches `terminal` for as long as the result is subscribed: while it is frontmost.
    func watching(_ terminal: Terminal, pid: pid_t) -> AnyPublisher<Never, Never> {
        Deferred { () -> AnyPublisher<Never, Never> in
            var session = 0
            return Empty(completeImmediately: false)
                .handleEvents(
                    receiveSubscription: { [weak self] _ in session = self?.start(terminal, pid: pid) ?? 0 },
                    receiveCancel: { [weak self] in self?.stop(session: session) }
                )
                .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
    }

    /// What `terminal`'s latest lookup went through; watched at once if it is frontmost.
    func follow(_ trail: TerminalTrail, for terminal: Terminal) {
        trails[terminal] = trail
        guard terminal == active else { return }
        watch(trail)
    }

    private func start(_ terminal: Terminal, pid: pid_t) -> Int {
        session += 1
        active = terminal
        watchHerdrView(pid: terminal == .herdr ? pid : nil)
        // A stale baseline reads as a change, which looks the pane up again.
        watch(trails[terminal] ?? TerminalTrail())
        return session
    }

    private func stop(session: Int) {
        guard session == self.session, active != nil else { return }
        active = nil
        watch(TerminalTrail())
        watchHerdrView(pid: nil)
    }

    private func watch(_ trail: TerminalTrail) {
        pollGeneration += 1
        let generation = pollGeneration
        polls = []

        let pids = trail.ttys.map(\.pid)
        if pids != watchedPIDs {
            record(src: "libproc", pids.isEmpty ? "stop" : "start pids=\(pids.map(String.init).joined(separator: ","))")
            watchedPIDs = pids
        }
        if !trail.ttys.isEmpty {
            let check = Self.libprocCheck(
                trail.ttys,
                programNotBefore: programHolds(trail.ttys),
                foregroundPgid: environment.foregroundPgid,
                isAlive: environment.isAlive,
                now: environment.now
            )
            polls.append(environment.poll(Self.libprocInterval, check) { [weak self] change in
                self?.trigger(src: "libproc", change, paneMayHaveChanged: false, generation: generation)
            })
        }

        if trail.zellij?.session != watchedZellij {
            record(src: "zellij-poll", trail.zellij.map { "start session=\($0.session)" } ?? "stop")
            watchedZellij = trail.zellij?.session
        }
        if let zellij = trail.zellij {
            let check = Self.zellijCheck(zellij, pane: environment.zellijPane)
            polls.append(environment.poll(Self.zellijInterval, check) { [weak self] change in
                self?.trigger(src: "zellij-poll", change, paneMayHaveChanged: true, generation: generation)
            })
        }

        if !trail.herdrCatalogs.isEmpty || !trail.herdrClients.isEmpty || !trail.herdrMasters.isEmpty || trail.herdrInventoryIncomplete {
            let check = { () -> String? in
                if trail.herdrInventoryIncomplete { return "continue split inventory" }
                if let changed = trail.herdrCatalogs.first(where: { Multiplexer.herdrIsLocalOnly(catalog: $0.key) != $0.value }) {
                    return changed.key
                }
                if let client = trail.herdrClients.first(where: { $0.key.isOnlyClient() != $0.value }) {
                    return client.key.socket
                }
                return trail.herdrMasters.first { (TerminalProcess.ptyMasters(ofPID: $0.key) ?? []) != $0.value }
                    .map { "server=\($0.key) PTYs changed" }
            }
            polls.append(environment.poll(1, check) { [weak self] path in
                self?.trigger(src: "herdr-client", path, paneMayHaveChanged: true, generation: generation)
            })
        }

        activeConnections = Set(trail.herdrSockets.map(Connection.herdr))
        if trail.tmux { activeConnections.insert(.tmux) }
        for connection in activeConnections {
            closing[connection] = nil
            open(connection)
        }
        for connection in connections.keys where !activeConnections.contains(connection) && closing[connection] == nil {
            closing[connection] = environment.delay(Self.connectionGrace)
                .sink { [weak self] _ in self?.close(connection) }
        }
    }

    /// Starts or stops the Herdr focus mod.
    private func watchHerdrView(pid: pid_t?) {
        herdrView = nil
        herdrPane = nil
        guard let pid else { return }
        let generation = session
        herdrView = environment.herdrView(pid) { [weak self] in
            guard let self, self.session == generation else { return }
            self.receiveHerdrView($0)
        }
        record(src: "herdr-view", herdrView == nil ? "unavailable" : "start")
    }

    /// A lost report clears the prior pane. The same pane can show a different terminal.
    private func receiveHerdrView(_ pane: HerdrDesktop.Focus?) {
        guard active == .herdr, pane != herdrPane else { return }
        herdrPane = pane
        let focus = pane ?? .init(pane: nil, terminal: nil)
        record(src: "herdr-mod", "focus pane=\(focus.pane ?? "-") terminal=\(focus.terminal ?? "-")")
        focusHerdr(focus)
    }

    /// Per tty in `ttys` (by its `pid`), the uptime before which its program's end is not
    /// reported; see `watchedPrograms`.
    private func programHolds(_ ttys: [TerminalTrail.TTY]) -> [pid_t: TimeInterval] {
        watchedPrograms = watchedPrograms.filter { watched in ttys.contains { $0.pid == watched.key } }
        let now = environment.now()
        for tty in ttys {
            let watched = watchedPrograms[tty.pid].flatMap { $0.foregroundPgid == tty.foregroundPgid ? $0 : nil }
            guard let program = tty.program else {
                // A shell read in the same group keeps the entry: the next program there is not the first.
                if watched == nil { watchedPrograms[tty.pid] = nil }
                continue
            }
            if let watched {
                if watched.program != program {
                    watchedPrograms[tty.pid] = (tty.foregroundPgid, program, now + Self.programCooldown)
                }
            } else {
                watchedPrograms[tty.pid] = (tty.foregroundPgid, program, 0)
            }
        }
        return watchedPrograms.mapValues(\.notBefore)
    }

    private func trigger(src: String, _ detail: String, paneMayHaveChanged: Bool, generation: Int? = nil) {
        guard active != nil, generation.map({ $0 == pollGeneration }) ?? true else { return }
        record(src: src, "trigger \(detail)")
        refresh(paneMayHaveChanged)
    }

    // MARK: Connections

    private func open(_ connection: Connection) {
        guard connections[connection] == nil else { return }
        record(connection, "start")
        connections[connection] = subscribe(connection)
    }

    /// Attaches once the server can be reached, starting past the attempts already dropped.
    private func subscribe(_ connection: Connection) -> AnyCancellable {
        attempt(connection, unreachable: 0)
    }

    /// One attempt after its wait. A server that can't be reached is tried again, each time
    /// after a longer wait, `maxFailedAttempts` times; after that the next lookup that
    /// goes through it starts over.
    private func attempt(_ connection: Connection, unreachable: Int) -> AnyCancellable {
        let wait = Self.retryDelay(afterFailures: (drops[connection] ?? 0) + unreachable)
        return environment.delay(wait).first().sink { [weak self] _ in
            guard let self else { return }
            let live = self.environment.connect(connection) { [weak self] in self?.receive($0, from: connection) }
            if let live {
                self.connections[connection] = live
            } else if unreachable + 1 < Self.maxFailedAttempts {
                self.connections[connection] = self.attempt(connection, unreachable: unreachable + 1)
            } else {
                self.record(connection, "stop unreachable")
                self.connections[connection] = nil
                self.drops[connection] = nil
            }
        }
    }

    private func receive(_ event: ConnectionEvent, from connection: Connection) {
        guard activeConnections.contains(connection) else {
            switch event {
            case .closed, .dropped: close(connection)
            case .ready, .changed: break
            }
            return
        }
        switch event {
        case .ready:
            // A herdr pane focused after the lookup but before the subscription went unreported:
            // read it again now that events flow. tmux's control client reports its own attach.
            guard case .herdr = connection else { return }
            trigger(src: connection.src, "ready \(connection.detail)", paneMayHaveChanged: true)
        case .changed:
            trigger(src: connection.src, connection.detail.isEmpty ? "event" : "event \(connection.detail)", paneMayHaveChanged: true)
        case .closed(wasReady: true):
            // The server went away (or restarts): attach again with backoff.
            record(connection, "reconnect")
            drops[connection] = nil
            connections[connection] = subscribe(connection)
        case .dropped:
            // No handshake in time, or the server vanished: back off further each time, and
            // give up on a server that never answers until a lookup reaches it again.
            let dropped = (drops[connection] ?? 0) + 1
            guard dropped < Self.maxFailedAttempts else {
                record(connection, "stop dropped=\(dropped)")
                connections[connection] = nil
                drops[connection] = nil
                return
            }
            drops[connection] = dropped
            record(connection, "reconnect dropped=\(dropped)")
            connections[connection] = subscribe(connection)
        case .closed(wasReady: false):
            // Refused before its handshake: retrying at once would loop, so wait for a lookup that reaches it again.
            record(connection, "stop refused")
            connections[connection] = nil
            drops[connection] = nil
        }
    }

    private func close(_ connection: Connection) {
        record(connection, "stop")
        connections[connection] = nil
        drops[connection] = nil
        closing[connection] = nil
    }

    // MARK: Checks (run on the poll queue)

    /// The first tty whose foreground group differs from `ttys`' baseline or can't be read
    /// any more, or whose program has ended and may be reported (`programNotBefore`, by tty `pid`).
    nonisolated static func libprocCheck(
        _ ttys: [TerminalTrail.TTY],
        programNotBefore: [pid_t: TimeInterval] = [:],
        foregroundPgid: @escaping (pid_t) -> pid_t?,
        isAlive: @escaping (pid_t) -> Bool,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) -> () -> String? {
        {
            for tty in ttys {
                let current = foregroundPgid(tty.pid)
                if current != tty.foregroundPgid {
                    return "pid=\(tty.pid) tpgid=\(tty.foregroundPgid)->\(current.map(String.init) ?? "gone")"
                }
                if let program = tty.program, now() >= programNotBefore[tty.pid] ?? 0, !isAlive(program) {
                    return "pid=\(tty.pid) program=\(program)->gone"
                }
            }
            return nil
        }
    }

    /// zellij's focused pane when it answers with another one than `zellij`'s baseline.
    nonisolated static func zellijCheck(_ zellij: TerminalTrail.Zellij, pane: @escaping (String) -> Multiplexer.Pane?) -> () -> String? {
        {
            guard let now = pane(zellij.session), now != zellij.pane else { return nil }
            switch now {
            case .clientOnly: return "client only"
            case let .tty(_, label), let .program(_, label):
                return "pane=\(label)"
            }
        }
    }

    private func record(src: String, _ message: String) {
        IndicatorDiagnostics.record("terminal.watch src=\(src) \(message)")
    }

    private func record(_ connection: Connection, _ message: String) {
        record(src: connection.src, connection.detail.isEmpty ? message : "\(message) \(connection.detail)")
    }
}

extension TerminalWatcher.Connection {
    var src: String {
        switch self {
        case .tmux: return "tmux-ctl"
        case .herdr: return "herdr-sock"
        }
    }

    var detail: String {
        switch self {
        case .tmux: return ""
        case let .herdr(socket): return "socket=\(socket)"
        }
    }
}

// MARK: - Connection lines

extension TerminalWatcher {
    /// What a connection line means: the server answered the handshake, or the focused pane may have changed.
    enum Line: Equatable {
        case ready
        case changed

        /// tmux control mode. `%end` closes the reply to `attach`. A pane switch
        /// (in any session) sends `%window-pane-changed`, a window switch only
        /// `%session-window-changed`, a client switching session
        /// `%client-session-changed`, this client's own session `%session-changed`.
        static func tmux(_ line: Substring) -> Line? {
            if line.hasPrefix("%end ") { return .ready }
            return tmuxChanges.contains(line.prefix { $0 != " " }) ? .changed : nil
        }

        private static let tmuxChanges: Set<Substring> = [
            "%window-pane-changed", "%session-window-changed", "%client-session-changed", "%session-changed",
        ]

        /// A background tab opening or closing can change whether the server's
        /// focused pane identifies this client, even when pane focus stays put.
        static let herdrSubscriptions = ["pane.focused", "tab.created", "tab.closed", "workspace.created", "workspace.closed"]

        static func herdr(_ line: Substring) -> Line? {
            struct Message: Decodable {
                struct Result: Decodable { let type: String? }
                let event: String?
                let result: Result?
            }
            guard let message = try? JSONDecoder().decode(Message.self, from: Data(line.utf8)) else { return nil }
            if message.result?.type == "subscription_started" { return .ready }
            guard let event = message.event else { return nil }
            return herdrSubscriptions.contains(event.replacingOccurrences(of: "_", with: ".")) ? .changed : nil
        }

        /// Takes the complete lines out of `buffer`; true when any of them is a
        /// change, so a burst read together counts once. Sets `isReady` on a handshake line.
        static func scan(_ buffer: inout [UInt8], isReady: inout Bool, parse: (Substring) -> Line?) -> Bool {
            var changed = false
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                switch parse(Substring(String(decoding: buffer[..<newline], as: UTF8.self))) {
                case .ready?: isReady = true
                case .changed?: changed = true
                case nil: break
                }
                buffer.removeSubrange(...newline)
            }
            // Neither protocol sends long lines; a runaway one is dropped rather than kept growing.
            if buffer.count > 1 << 16 { buffer.removeAll() }
            return changed
        }
    }
}

// MARK: - Live environment

extension TerminalWatcher.Environment {
    /// `tmuxSocket` names the tmux server (`tmux -L`); only the probe changes it.
    /// A server must answer the handshake within `handshakeTimeout`.
    static func live(tmuxSocket: String = "default", handshakeTimeout: TimeInterval = 2) -> Self {
        Self(
            poll: poll,
            foregroundPgid: TerminalTrail.foregroundPgid(ofPID:),
            isAlive: TerminalTrail.isAlive,
            now: { ProcessInfo.processInfo.systemUptime },
            zellijPane: Multiplexer.zellijPane(session:),
            connect: { connection, send in
                switch connection {
                case .tmux:
                    let path = (ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/tmp") + "/tmux-\(getuid())/\(tmuxSocket)"
                    // Spawn tmux only when its server listens; otherwise `attach` fails at once.
                    guard isListening(path) else { return nil }
                    return attach(timeout: handshakeTimeout, parse: TerminalWatcher.Line.tmux, send: send) {
                        spawnTmuxControlClient(socket: tmuxSocket)
                    }
                case let .herdr(socket):
                    guard isListening(socket) else { return nil }
                    return attach(timeout: handshakeTimeout, parse: TerminalWatcher.Line.herdr, send: send) {
                        subscribeHerdr(socket: socket)
                    }
                }
            },
            delay: { Timer.delay(seconds: $0) },
            herdrView: HerdrDesktop.watch
        )
    }

    /// Connecting and connection reads, off the main thread.
    private static let queue = DispatchQueue(label: "dev.inputsourcepro.terminal-watch", qos: .utility)

    static func poll(every interval: TimeInterval, check: @escaping () -> String?, fire: @escaping (String) -> Void) -> AnyCancellable {
        // A queue of its own: zellij's check runs its CLI, which must not hold up the
        // other polls or the connection reads when the server is slow to answer.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.inputsourcepro.terminal-poll", qos: .utility))
        // Leeway lets the system batch the wakeups.
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler {
            guard let change = check() else { return }
            timer.cancel()
            DispatchQueue.main.async { fire(change) }
        }
        timer.resume()
        return AnyCancellable { timer.cancel() }
    }

    /// Watches directory `path` on `queue` (a file there replaced by rename
    /// changes the directory, not the old file): `send` gets what `read` finds
    /// initially and after each change on the delivery queue, none once the
    /// result is cancelled. Nil when the directory can't be opened.
    /// A directory deleted or renamed while watched goes unnoticed until it is watched again.
    static func watchDirectory<Value>(_ path: String, receiveOn deliveryQueue: DispatchQueue = .main, read: @escaping () -> Value, send: @escaping (Value) -> Void) -> AnyCancellable? {
        // O_EVTONLY on a local directory doesn't block, so the caller learns at once whether it opened.
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let flag = CancelFlag()
        let deliver = {
            let value = read()
            deliveryQueue.async { if !flag.isCancelled { send(value) } }
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        source.setEventHandler(handler: deliver)
        source.setCancelHandler { Darwin.close(fd) }
        // Resumed before the first read: a change in between is read again, never missed.
        source.resume()
        queue.async(execute: deliver)
        flag.onCancel { source.cancel() }
        return AnyCancellable(flag)
    }

    /// Opens a connection on `queue`: `open` gives the fd to read and what to
    /// run once it is closed, or nil when the server went away since it was
    /// found. Events reach `send` on the main thread, none once the result is
    /// cancelled; a connection opened after that is closed at once.
    static func attach(
        timeout: TimeInterval,
        parse: @escaping (Substring) -> TerminalWatcher.Line?,
        send: @escaping (TerminalWatcher.ConnectionEvent) -> Void,
        open: @escaping () -> (fd: Int32, onClose: () -> Void)?
    ) -> AnyCancellable {
        let flag = CancelFlag()
        let deliver: (TerminalWatcher.ConnectionEvent) -> Void = { event in
            DispatchQueue.main.async { if !flag.isCancelled { send(event) } }
        }
        queue.async {
            guard !flag.isCancelled else { return }
            guard let opened = open() else { return deliver(.dropped) }
            let reading = stream(fd: opened.fd, timeout: timeout, parse: parse, send: deliver, onClose: opened.onClose)
            flag.onCancel { reading.cancel() }
        }
        return AnyCancellable(flag)
    }

    /// A tmux control-mode client of server `socket`: its stdout, and closing
    /// its stdin to end it. `no-output` keeps pane output away; it is not
    /// `read-only`, which would make other clients' `send-keys` fail.
    static func spawnTmuxControlClient(socket: String) -> (fd: Int32, onClose: () -> Void)? {
        guard let tmux = Multiplexer.tmux.executable else { return nil }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["-L", socket, "-C", "attach", "-f", "no-output"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        process.environment = environment
        do {
            try process.run()
        } catch {
            return nil
        }
        let fd = dup(output.fileHandleForReading.fileDescriptor)
        try? output.fileHandleForReading.close()
        guard fd >= 0 else {
            try? input.fileHandleForWriting.close()
            return nil
        }
        // A control client exits when its stdin closes; so does it when ISP quits. One still
        // waiting on a server that doesn't answer never reads its stdin, so it is ended too.
        return (fd, {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        })
    }

    /// Watch pane focus and the topology used to establish it.
    static func subscribeHerdr(socket: String) -> (fd: Int32, onClose: () -> Void)? {
        let subscriptions = TerminalWatcher.Line.herdrSubscriptions.map { ["type": $0] }
        let payload: [String: Any] = ["id": "isp", "method": "events.subscribe", "params": ["subscriptions": subscriptions]]
        guard var request = try? JSONSerialization.data(withJSONObject: payload), let fd = connectUnix(socket) else { return nil }
        request.append(0x0a)
        // A fresh socket's buffer takes the request whole; anything less is a server in trouble.
        guard request.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == request.count else {
            Darwin.close(fd)
            return nil
        }
        return (fd, {})
    }

    /// Whether a server listens at `path`, without waiting on it.
    static func isListening(_ path: String) -> Bool {
        guard let fd = connectUnix(path) else { return false }
        Darwin.close(fd)
        return true
    }

    /// Connect once so peer identification and the request act on the same server.
    static func withUnixPeer<Value>(at path: String, _ body: (Int32, pid_t) -> Value?) -> Value? {
        guard let fd = connectUnix(path) else { return nil }
        defer { Darwin.close(fd) }
        var peer: pid_t = 0
        var size = socklen_t(MemoryLayout.size(ofValue: peer))
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0, peer > 0 else { return nil }
        return body(fd, peer)
    }

    /// Herdr's local desktop and TUI APIs both use one newline-delimited JSON reply.
    static func jsonReply(to payload: [String: Any], on fd: Int32) -> Data? {
        guard var message = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        message.append(0x0a)
        guard message.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == message.count else { return nil }

        var reply = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while reply.count < 1 << 20 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard remaining > 0, Darwin.poll(&event, 1, Int32(remaining * 1000)) > 0 else { return nil }
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else { return nil }
            reply.append(contentsOf: bytes.prefix(count))
            if reply.last == 0x0a { return reply }
        }
        return nil
    }

    /// A non-blocking stream socket connected to `path`; nil when nothing
    /// listens there, or it can't take a connection right now (backlog full).
    static func connectUnix(_ path: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Never wait in connect: it may run on the main thread.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    /// Reads `fd` on `queue` until EOF, sending `.ready` on the handshake,
    /// `.changed` at most once per read and `.closed` at EOF, or `.dropped` when no handshake line came
    /// within `timeout`; `send` runs on `queue`. Owns `fd`: it is closed, and
    /// `onClose` runs, once reading has stopped, at the latest when cancelled.
    static func stream(
        fd: Int32,
        timeout: TimeInterval,
        parse: @escaping (Substring) -> TerminalWatcher.Line?,
        send: @escaping (TerminalWatcher.ConnectionEvent) -> Void,
        onClose: @escaping () -> Void
    ) -> AnyCancellable {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // Touched only on `queue`, where the handlers run serially.
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        var isReady = false

        source.setEventHandler {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            guard count > 0 else {
                source.cancel()
                return send(.closed(wasReady: isReady))
            }
            buffer += chunk[..<count]
            let wasReady = isReady
            let changed = TerminalWatcher.Line.scan(&buffer, isReady: &isReady, parse: parse)
            if isReady, !wasReady { send(.ready) }
            if changed { send(.changed) }
        }
        source.setCancelHandler {
            Darwin.close(fd)
            onClose()
        }
        source.resume()
        queue.asyncAfter(deadline: .now() + timeout) {
            guard !isReady, !source.isCancelled else { return }
            source.cancel()
            send(.dropped)
        }
        return AnyCancellable { source.cancel() }
    }
}

/// A cancellation that work on another queue can check.
final class CancelFlag: Cancellable, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Runs `handler` on cancel, at once when already cancelled.
    func onCancel(_ handler: @escaping () -> Void) {
        let runNow = lock.withLock {
            if !cancelled { handlers.append(handler) }
            return cancelled
        }
        if runNow { handler() }
    }

    func cancel() {
        let handlers = lock.withLock {
            cancelled = true
            defer { self.handlers = [] }
            return self.handlers
        }
        handlers.forEach { $0() }
    }
}
