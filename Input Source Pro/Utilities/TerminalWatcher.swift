import Combine
import Darwin
import Foundation

/// What a terminal lookup went through: the ttys it read and the multiplexers
/// that answered. `TerminalWatcher` watches these until the next lookup.
struct TerminalTrail: Equatable {
    /// A tty that was read: a process on it that ISP can read (the earliest
    /// started, normally the shell; a `login` session leader belongs to root),
    /// and the tty's foreground process group when it was read.
    struct TTY: Equatable {
        let pid: pid_t
        let foregroundPgid: pid_t
    }

    var ttys: [TTY] = []
    /// The default tmux server answered.
    var tmux = false

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
        self.init(pid: process.pid, foregroundPgid: process.foregroundPgid)
    }
}

/// Notices changes in the frontmost terminal's focused pane without shell
/// hooks or plugins, and calls `refresh` so the pane is read again:
/// - libproc: each tty the last lookup read, for a job starting or ending;
/// - tmux: a control-mode client, for pane, window and session switches.
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
    }

    /// What a connection reports, on the main thread. `wasReady`: its server
    /// had answered the handshake before the connection closed. `dropped`: it
    /// gave up before the handshake for a reason worth retrying (no answer in
    /// time, or the server went away since it was found).
    enum ConnectionEvent: Equatable {
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
        /// Opens a connection without waiting on it, or nil when its server can't be reached.
        var connect: (Connection, _ send: @escaping (ConnectionEvent) -> Void) -> AnyCancellable?
        var delay: (TimeInterval) -> AnyPublisher<Date, Never>
    }

    static let libprocInterval: TimeInterval = 0.1
    static let connectionGrace: TimeInterval = 10

    private let environment: Environment
    private let refresh: () -> Void

    private var active: Terminal?
    /// Counts `watching` subscriptions, so a late cancel of an earlier one is ignored.
    private var session = 0
    /// Each terminal's latest trail, picked up again when it comes to the front.
    private var trails: [Terminal: TerminalTrail] = [:]
    private var polls: [AnyCancellable] = []
    /// Counts poll sets, so a change fired by a replaced poll is ignored.
    private var pollGeneration = 0
    private var watchedPIDs: [pid_t] = []
    private var connections: [Connection: AnyCancellable] = [:]
    /// Attaches dropped in a row since a connection's last handshake; each one waits longer.
    private var drops: [Connection: Int] = [:]
    private var closing: AnyCancellable?

    init(environment: Environment = .live(), refresh: @escaping () -> Void) {
        self.environment = environment
        self.refresh = refresh
    }

    /// Watches `terminal` for as long as the result is subscribed: while it is frontmost.
    func watching(_ terminal: Terminal) -> AnyPublisher<Never, Never> {
        Deferred { () -> AnyPublisher<Never, Never> in
            var session = 0
            return Empty(completeImmediately: false)
                .handleEvents(
                    receiveSubscription: { [weak self] _ in session = self?.start(terminal) ?? 0 },
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

    private func start(_ terminal: Terminal) -> Int {
        session += 1
        active = terminal
        closing = nil
        if let trail = trails[terminal] {
            // A stale baseline reads as a change, which looks the pane up again.
            watch(trail)
        }
        return session
    }

    private func stop(session: Int) {
        guard session == self.session, active != nil else { return }
        active = nil
        watch(TerminalTrail())
        guard !connections.isEmpty else { return }
        closing = environment.delay(Self.connectionGrace)
            .sink { [weak self] _ in self?.closeConnections() }
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
            let check = Self.libprocCheck(trail.ttys, foregroundPgid: environment.foregroundPgid)
            polls.append(environment.poll(Self.libprocInterval, check) { [weak self] change in
                self?.trigger(src: "libproc", change, generation: generation)
            })
        }

        if trail.tmux { open(.tmux) }
    }

    private func trigger(src: String, _ detail: String, generation: Int? = nil) {
        guard active != nil, generation.map({ $0 == pollGeneration }) ?? true else { return }
        record(src: src, "trigger \(detail)")
        refresh()
    }

    // MARK: Connections

    private func open(_ connection: Connection) {
        guard connections[connection] == nil else { return }
        record(connection, "start")
        connections[connection] = subscribe(connection)
    }

    /// Attaches with `AXWatchRetry`'s backoff until the server can be reached,
    /// starting past the attempts already dropped.
    private func subscribe(_ connection: Connection) -> AnyCancellable {
        let environment = environment
        return AXWatchRetry.publisher(
            pid: 0,
            // A local socket is retried at most every 5s.
            notReadyDelayCap: 5,
            isAlive: { true },
            isTrusted: { true },
            probe: { _, done in done(nil) },
            // Starts past the attempts already dropped.
            initialDelay: AXWatchRetry.delay(afterFailures: drops[connection] ?? 0, cap: 5),
            attach: { send in
                environment.connect(connection, send).map { .attached($0, registration: .init()) }
                    ?? .notReady(reason: "unreachable")
            },
            delay: environment.delay
        )
        .sink { [weak self] event in self?.receive(event, from: connection) }
    }

    private func receive(_ event: ConnectionEvent, from connection: Connection) {
        switch event {
        case .changed:
            trigger(src: connection.src, "event")
        case .closed(wasReady: true):
            // The server went away (or restarts): attach again with backoff.
            record(connection, "reconnect")
            drops[connection] = nil
            connections[connection] = subscribe(connection)
        case .dropped:
            // No handshake in time, or the server vanished: back off further each time.
            drops[connection, default: 0] += 1
            record(connection, "reconnect dropped=\(drops[connection] ?? 0)")
            connections[connection] = subscribe(connection)
        case .closed(wasReady: false):
            // Refused before its handshake: retrying at once would loop, so wait for a lookup that reaches it again.
            record(connection, "stop refused")
            connections[connection] = nil
            drops[connection] = nil
        }
    }

    private func closeConnections() {
        for connection in connections.keys {
            record(connection, "stop")
        }
        connections = [:]
        drops = [:]
        closing = nil
    }

    // MARK: Checks (run on the poll queue)

    /// The first tty whose foreground group differs from `ttys`' baseline, or can't be read any more.
    nonisolated static func libprocCheck(_ ttys: [TerminalTrail.TTY], foregroundPgid: @escaping (pid_t) -> pid_t?) -> () -> String? {
        {
            for tty in ttys {
                let now = foregroundPgid(tty.pid)
                if now != tty.foregroundPgid {
                    return "pid=\(tty.pid) tpgid=\(tty.foregroundPgid)->\(now.map(String.init) ?? "gone")"
                }
            }
            return nil
        }
    }

    private func record(src: String, _ message: String) {
        IndicatorDiagnostics.record("terminal.watch src=\(src) \(message)")
    }

    private func record(_ connection: Connection, _ message: String) {
        record(src: connection.src, message)
    }
}

extension TerminalWatcher.Connection {
    var src: String {
        switch self {
        case .tmux: return "tmux-ctl"
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
            // tmux sends no long lines; a runaway one is dropped rather than kept growing.
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
            connect: { connection, send in
                switch connection {
                case .tmux:
                    let path = (ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/tmp") + "/tmux-\(getuid())/\(tmuxSocket)"
                    // Spawn tmux only when its server listens; otherwise `attach` fails at once.
                    guard isListening(path) else { return nil }
                    return attach(timeout: handshakeTimeout, parse: TerminalWatcher.Line.tmux, send: send) {
                        spawnTmuxControlClient(socket: tmuxSocket)
                    }
                }
            },
            delay: { Timer.delay(seconds: $0) }
        )
    }

    /// Polls, connecting and connection reads, off the main thread.
    private static let queue = DispatchQueue(label: "dev.inputsourcepro.terminal-watch", qos: .utility)

    static func poll(every interval: TimeInterval, check: @escaping () -> String?, fire: @escaping (String) -> Void) -> AnyCancellable {
        let timer = DispatchSource.makeTimerSource(queue: queue)
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
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: Multiplexer.tmux.executable)
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
        // A control client exits when its stdin closes; so does it when ISP quits.
        return (fd, { try? input.fileHandleForWriting.close(); _ = process })
    }

    /// Whether a server listens at `path`, without waiting on it.
    static func isListening(_ path: String) -> Bool {
        guard let fd = connectUnix(path) else { return false }
        Darwin.close(fd)
        return true
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

    /// Reads `fd` on `queue` until EOF, sending `.changed` at most once per
    /// read and `.closed` at EOF, or `.dropped` when no handshake line came
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
            if TerminalWatcher.Line.scan(&buffer, isReady: &isReady, parse: parse) {
                send(.changed)
            }
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
