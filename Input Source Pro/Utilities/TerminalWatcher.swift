import Combine
import Foundation

/// What a terminal lookup went through: the ttys it read. `TerminalWatcher`
/// watches these until the next lookup.
struct TerminalTrail: Equatable {
    /// A tty that was read: a process on it that ISP can read (the earliest
    /// started, normally the shell; a `login` session leader belongs to root),
    /// and the tty's foreground process group when it was read.
    struct TTY: Equatable {
        let pid: pid_t
        let foregroundPgid: pid_t
    }

    var ttys: [TTY] = []

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
/// - libproc: each tty the last lookup read, for a job starting or ending.
///
/// Watches only while a terminal with Terminal Rules is frontmost (`watching`).
/// Each lookup's trail is handed to `follow`, which replaces the polls with
/// ones for the new trail. A poll fires once; the lookup it causes restarts it.
@MainActor
final class TerminalWatcher {
    struct Environment {
        /// Calls `check` every `interval` seconds off the main thread until it
        /// returns a change or is cancelled; `fire` then gets the change once,
        /// on the main thread.
        var poll: (_ interval: TimeInterval, _ check: @escaping () -> String?, _ fire: @escaping (String) -> Void) -> AnyCancellable
        var foregroundPgid: (pid_t) -> pid_t?
    }

    static let libprocInterval: TimeInterval = 0.1

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
    }

    private func trigger(src: String, _ detail: String, generation: Int) {
        guard active != nil, generation == pollGeneration else { return }
        record(src: src, "trigger \(detail)")
        refresh()
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
}

// MARK: - Live environment

extension TerminalWatcher.Environment {
    static func live() -> Self {
        Self(
            poll: poll,
            foregroundPgid: TerminalTrail.foregroundPgid(ofPID:)
        )
    }

    /// Polls, off the main thread.
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
