import AppKit
import Combine
import Darwin

/// Terminals whose foreground program can drive Terminal Rules.
enum Terminal: String, CaseIterable {
    case ghostty = "com.mitchellh.ghostty"
    case iterm = "com.googlecode.iterm2"
    case terminalApp = "com.apple.Terminal"
    case wezterm = "com.github.wez.wezterm"
    case alacritty = "org.alacritty"

    init?(_ app: NSRunningApplication) {
        guard let bundleIdentifier = app.bundleIdentifier else { return nil }
        self.init(rawValue: bundleIdentifier)
    }

    var displayName: String {
        switch self {
        case .ghostty:
            return "Ghostty"
        case .iterm:
            return "iTerm2"
        case .terminalApp:
            return "Terminal"
        case .wezterm:
            return "WezTerm"
        case .alacritty:
            return "Alacritty"
        }
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) != nil
    }
}

// MARK: - Focused tty

extension Terminal {
    /// The outer tty each terminal's focused pane was last read from (a
    /// `TerminalProbe` answer), so a refresh reads it again without asking the
    /// terminal. Confined to `TerminalProcess.queue`, which orders it with the
    /// reads that use it.
    private static var focusedTTYs: [Terminal: String] = [:]
    /// Terminals whose floating panel has focus (`TerminalPanelFocus`), so
    /// `TerminalProbe` asks for the panel's pane. Confined to `TerminalProcess.queue`.
    private static var focusedPanels: Set<Terminal> = []

    var isPanelFocused: Bool { Self.focusedPanels.contains(self) }

    /// Marks whether this terminal's floating panel has focus and forgets the
    /// focused tty, which belonged to the other side. Call on `TerminalProcess.queue`.
    func setPanelFocused(_ isFocused: Bool) {
        Self.focusedTTYs[self] = nil
        if isFocused {
            Self.focusedPanels.insert(self)
        } else {
            Self.focusedPanels.remove(self)
        }
    }

    /// What `tty` runs, which becomes this terminal's focused tty; nil forgets
    /// it and reads nothing, in no known pane. Call on `TerminalProcess.queue`.
    func focusedProgram(onTTY tty: String?) -> TerminalReading {
        Self.focusedTTYs[self] = tty
        return tty.map { TerminalProcess.foregroundProgram(onTTY: $0) } ?? TerminalReading(program: nil, pane: nil)
    }

    /// The focused pane, read again on the remembered tty; the terminal is
    /// probed for its tty when none is remembered. Call on `TerminalProcess.queue`.
    func refreshedProgram() -> TerminalReading {
        let focused = Self.focusedTTYs[self]
        IndicatorDiagnostics.record("terminal.refresh bundle=\(rawValue) tty=\(focused ?? "-")")
        if let focused {
            return TerminalProcess.foregroundProgram(onTTY: focused)
        }
        return TerminalProbe.program(self)
    }
}

/// What a lookup found in a terminal's focused pane: its program, nil for a
/// shell prompt, and the pane read (the program's own pane when there is one),
/// so a shell is tied to its pane too. `pane` is nil when no pane was read.
/// `trail` is what the lookup went through, for `TerminalWatcher`; it is not
/// part of what was read, so two readings compare equal without it.
struct TerminalReading: Equatable {
    let program: TerminalProgram?
    let pane: String?
    var trail = TerminalTrail()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.program == rhs.program && lhs.pane == rhs.pane
    }
}

/// The program running in the focused terminal pane. `key` is the terminal's
/// identifier for it (the process's `argv[0]`); `name` is an alternative label
/// (the kernel's process name when it differs, e.g. Claude Code's `2.1.318`).
/// `pane` names the terminal instance (the pane's tty path), so
/// moving to another pane running the same program is a new context.
struct TerminalProgram: Equatable {
    let key: String
    let name: String?
    let pane: String?

    init(key: String, name: String? = nil, pane: String? = nil) {
        self.key = key
        self.name = name == key ? nil : name
        self.pane = pane
    }

    /// Stable per-program part of `AppKind.getId()` when no rule matches. Leaves
    /// out `pane`, so panes running the same program share one remembered input
    /// source, like tabs on the same website.
    var id: String {
        [key, name].compactMap { $0 }.joined(separator: "/").lowercased()
    }
}

/// One process attached to a tty, as the kernel's process table reports it.
struct TerminalProcess: Equatable {
    let pid: pid_t
    let pgid: pid_t
    let foregroundPgid: pid_t
    let startTime: TimeInterval
    /// `p_comm`, the executable's file name (at most 16 bytes).
    let comm: String

    static let shells: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "tcsh", "csh",
        "nu", "elvish", "xonsh", "pwsh", "login",
    ]

    var isShell: Bool {
        Self.shells.contains(comm.hasPrefix("-") ? String(comm.dropFirst()) : comm)
    }

    /// The process that stands for the tty's foreground job: the earliest-started
    /// non-shell member of the foreground process group. That is the group leader
    /// (`nvim`, `claude`), or the command a shell leader started (`bash -c
    /// lazygit`); children a program spawns later into its group (an agent's MCP
    /// servers, `caffeinate`) start after it and never win. A shell alone means
    /// no program.
    static func foregroundProcess(in processes: [TerminalProcess]) -> TerminalProcess? {
        processes
            .filter { $0.pgid == $0.foregroundPgid && !$0.isShell }
            .min { ($0.startTime, $0.pid) < ($1.startTime, $1.pid) }
    }

    /// `argv[0]` names the command people typed (`claude`), while `p_comm` is the
    /// resolved file name (`2.1.318` for Claude Code's versioned binary), so the
    /// rule can match either. A script run by an interpreter (`node …/cli.js`,
    /// `bun ~/.bun/bin/omp`) is named after the script: the bin name its npm
    /// package gives it, else the file name without extension.
    static func program(comm: String, arguments: [String]) -> TerminalProgram {
        let command = arguments.first
            .map { ($0 as NSString).lastPathComponent }
            .map { $0.hasPrefix("-") ? String($0.dropFirst()) : $0 }
            .flatMap { $0.isEmpty ? nil : $0 }

        if let command, interpreters.contains(command),
           let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") && $0 != "run" }) {
            return TerminalProgram(key: packageBinName(ofScript: script) ?? (script as NSString).lastPathComponent.components(separatedBy: ".")[0], name: comm)
        }
        return TerminalProgram(key: command ?? comm, name: comm)
    }

    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "perl"]

    /// The `bin` name the nearest `package.json` above `script` gives it
    /// (`pi` for `…/pi-coding-agent/dist/bundle/cli.js`), nil when none does.
    static func packageBinName(ofScript script: String) -> String? {
        var directory = (script as NSString).deletingLastPathComponent
        while directory.count > 1 {
            let manifest = directory + "/package.json"
            if let data = FileManager.default.contents(atPath: manifest) {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return binName(in: json, packageDirectory: directory, script: script)
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// `bin` is a map of name → script path relative to the package, or one
    /// path for a bin named after the package.
    static func binName(in manifest: [String: Any], packageDirectory: String, script: String) -> String? {
        let scriptPath = (script as NSString).standardizingPath
        let resolves: (String) -> Bool = { ((packageDirectory + "/" + $0) as NSString).standardizingPath == scriptPath }
        if let bins = manifest["bin"] as? [String: String] {
            return bins.first { resolves($0.value) }?.key
        }
        if let bin = manifest["bin"] as? String, resolves(bin), let name = manifest["name"] as? String {
            return (name as NSString).lastPathComponent
        }
        return nil
    }
}

// MARK: - Process table

extension TerminalProcess {
    /// Runs probes one at a time and off the main thread: `TerminalProbe`
    /// spawns processes.
    static let queue = DispatchQueue(label: "dev.inputsourcepro.terminal-probe", qos: .userInitiated)

    /// The foreground program on the tty at `path` (e.g. `/dev/ttys008`), nil
    /// for a shell prompt or an unreadable tty. Its pane is the tty path.
    static func foregroundProgram(onTTY path: String) -> TerminalReading {
        let processes = processes(onTTY: path)
        var trail = TerminalTrail()
        if let tty = TerminalTrail.TTY(watching: processes, foregroundPgid: TerminalTrail.foregroundPgid(ofPID:)) {
            trail.ttys.append(tty)
        }
        guard let process = foregroundProcess(in: processes) else {
            // Non-shell processes that are not in the foreground group explain a surprising "shell".
            if processes.contains(where: { !$0.isShell }) {
                IndicatorDiagnostics.record("terminal.tty tty=\(path) tpgid=\(processes.first?.foregroundPgid ?? 0) procs=\(processes.map { "\($0.comm):\($0.pgid)" }.joined(separator: ","))")
            }
            return TerminalReading(program: nil, pane: path, trail: trail)
        }
        let arguments = arguments(pid: process.pid)
        let found = program(comm: process.comm, arguments: arguments)
        return TerminalReading(program: TerminalProgram(key: found.key, name: found.name, pane: path), pane: path, trail: trail)
    }

    /// Runs `body` on `queue` and delivers its result on the main queue.
    static func onQueue<Output>(_ body: @escaping () -> Output) -> AnyPublisher<Output, Never> {
        Future { promise in
            queue.async { promise(.success(body())) }
        }
        .receive(on: DispatchQueue.main)
        .eraseToAnyPublisher()
    }

    /// The controlling tty of `pid` (e.g. `/dev/ttys002`), or nil when the process
    /// is gone, has no tty, or belongs to another user.
    static func ttyPath(ofPID pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var entry = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // An exited pid still succeeds, with size 0.
        guard sysctl(&mib, u_int(mib.count), &entry, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride,
              entry.kp_eproc.e_ucred.cr_uid == getuid()
        else { return nil }
        let dev = entry.kp_eproc.e_tdev
        // NODEV: no controlling tty
        return dev == -1 ? nil : devname(dev, S_IFCHR).map { "/dev/" + String(cString: $0) }
    }

    static func processes(onTTY path: String) -> [TerminalProcess] {
        var info = stat()
        guard stat(path, &info) == 0 else { return [] }

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, info.st_rdev]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        // Room for processes started between the two calls.
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 8)
        size = entries.count * stride
        guard sysctl(&mib, u_int(mib.count), &entries, &size, nil, 0) == 0 else { return [] }

        return entries.prefix(size / stride).map { entry in
            let startTime = entry.kp_proc.p_un.__p_starttime
            let comm = withUnsafeBytes(of: entry.kp_proc.p_comm) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }

            return TerminalProcess(
                pid: entry.kp_proc.p_pid,
                pgid: entry.kp_eproc.e_pgid,
                foregroundPgid: entry.kp_eproc.e_tpgid,
                startTime: TimeInterval(startTime.tv_sec) + TimeInterval(startTime.tv_usec) / 1_000_000,
                comm: comm
            )
        }
    }

    /// The argv of `pid`, empty when it can't be read.
    static func arguments(pid: pid_t) -> [String] {
        var argMaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        guard sysctl(&argMaxMib, 2, &argMax, &argMaxSize, nil, 0) == 0, argMax > 0 else { return [] }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }

        return arguments(fromProcArgs: buffer.prefix(size))
    }

    /// Parses a `KERN_PROCARGS2` buffer: `argc` (Int32), the executable path,
    /// NUL padding, then `argc` NUL-terminated arguments (the environment follows).
    static func arguments(fromProcArgs buffer: ArraySlice<UInt8>) -> [String] {
        let countSize = MemoryLayout<Int32>.size
        guard buffer.count > countSize else { return [] }
        let argc = Array(buffer.prefix(countSize)).withUnsafeBytes { $0.load(as: Int32.self) }
        var index = buffer.startIndex + countSize

        while index < buffer.endIndex, buffer[index] != 0 { index += 1 }
        while index < buffer.endIndex, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < argc, index < buffer.endIndex {
            let start = index
            while index < buffer.endIndex, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start ..< index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}

// MARK: - CLI runs

extension TerminalProcess {
    /// ISP's environment for the CLIs.
    private static let environment: [String] = ProcessInfo.processInfo.environment.map { "\($0)=\($1)" }

    /// `path`'s standard output when it exits with status 0 within `timeout`.
    /// posix_spawn rather than `Process`, which costs about ten times the CPU per run.
    /// `watchdog` runs its handler `timeout` seconds on; tests fire it by hand.
    static func output(
        of path: String,
        arguments: [String],
        timeout: TimeInterval = 1,
        watchdog: (TimeInterval, @escaping () -> Void) -> Void = { DispatchQueue.global().asyncAfter(deadline: .now() + $0, execute: $1) }
    ) -> String? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let (readEnd, writeEnd) = (fds[0], fds[1])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only 0-2 reach the child: no other ISP descriptor (a watcher's socket, this pipe's read end) leaks into it.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        close(writeEnd)
        guard spawned == 0 else {
            close(readEnd)
            return nil
        }

        // A wedged server must not stall every lookup queued behind this one.
        // The child stays unreaped until `exited` is set, so its pid can't be reused under the kill.
        let lock = NSLock()
        var exited = false
        watchdog(timeout) {
            lock.withLock { if !exited { kill(pid, SIGKILL) } }
        }

        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(readEnd, &chunk, chunk.count)
            if count > 0 {
                output += chunk[..<count]
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        close(readEnd)

        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
        lock.withLock { exited = true }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        return status == 0 ? String(decoding: output, as: UTF8.self) : nil
    }
}
