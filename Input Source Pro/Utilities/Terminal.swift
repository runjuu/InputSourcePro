import AppKit
import Combine
import Darwin

/// Terminals whose foreground program can drive Terminal Rules.
enum Terminal: String, CaseIterable {
    case herdr = "dev.herdr.app"
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
        case .herdr:
            return "Herdr"
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
    /// The terminal process, outer tty, and optional pane label from its latest
    /// lookup. Accessed on `TerminalProcess.queue` with the reads that use it.
    private static var focusedTTYs: [Terminal: (pid: pid_t, path: String, pane: String?)] = [:]
    /// Terminals whose floating panel has focus (`TerminalPanelFocus`), so
    /// `TerminalProbe` asks for the panel's pane. Confined to `TerminalProcess.queue`.
    private static var focusedPanels: Set<Terminal> = []

    var isPanelFocused: Bool { Self.focusedPanels.contains(self) }
    /// The tty a refresh reads again, nil when none is remembered. Call on `TerminalProcess.queue`.
    var focusedTTY: String? { Self.focusedTTYs[self]?.path }

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
    func focusedProgram(onTTY tty: String?, pane: String? = nil, pid: pid_t) -> TerminalReading {
        Self.focusedTTYs[self] = tty.map { (pid, $0, pane) }
        return tty.map { TerminalProcess.foregroundProgram(onTTY: $0, pane: pane, watchHerdrJobs: self == .herdr) }
            ?? TerminalReading(program: nil, pane: nil)
    }

    /// Refresh the cached tty for this process. Herdr's mod supplies
    /// its pane, so a refresh has nothing to publish until that lookup succeeds.
    func refreshedProgram(pid: pid_t) -> TerminalReading? {
        // A second Alacritty window can open since the last lookup. Only a fresh
        // inventory can establish that the cached tty still identifies the window.
        if self == .alacritty { return TerminalProbe.program(self, pid: pid) }
        let cached = Self.focusedTTYs[self].flatMap { $0.pid == pid ? $0 : nil }
        IndicatorDiagnostics.record("terminal.refresh bundle=\(rawValue) tty=\(cached?.path ?? "-")")
        if let cached {
            return TerminalProcess.foregroundProgram(onTTY: cached.path, pane: cached.pane, watchHerdrJobs: self == .herdr)
        }
        return self == .herdr ? nil : TerminalProbe.program(self, pid: pid)
    }

    /// A non-terminal pane or a machine-qualified address has no local tty.
    /// An unanswered local lookup stays retryable until the last ordinary read.
    func herdrReading(
        _ focus: HerdrDesktop.Focus, pid: pid_t, lastTry: Bool,
        ttyPath: (pid_t) -> String? = TerminalProcess.ttyPath(ofPID:)
    ) -> TerminalReading? {
        guard let address = focus.terminal, !address.contains("/") else {
            _ = focusedProgram(onTTY: nil, pid: pid)
            return TerminalReading(program: nil, pane: focus.terminal ?? focus.pane, paneControlUnavailable: true)
        }
        let tty = focus.pid.flatMap { $0 > 0 ? ttyPath($0) : nil }
        let reading = focusedProgram(onTTY: tty, pane: address, pid: pid)
        if tty != nil { return reading }
        return lastTry ? TerminalReading(program: nil, pane: address) : nil
    }
}

/// What a lookup found in a terminal's focused pane: its program, nil for a
/// shell prompt, and the pane read (the program's own pane when there is one),
/// so a shell is tied to its pane too. `pane` is nil when no pane was read.
/// `trail` is what the lookup went through, for `TerminalWatcher`; it is not
/// part of what was read, so two readings compare equal without it. `tty` is
/// the focused pane's tty when the emulator and its multiplexers can identify it.
/// `pane` already tells panes apart for equality.
struct TerminalReading: Equatable {
    let program: TerminalProgram?
    let pane: String?
    var trail = TerminalTrail()
    var tty: String? = nil
    /// The terminal identified a configuration without pane control. An
    /// unanswered lookup also lacks a tty, but a pending command can retry it.
    var paneControlUnavailable = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.program == rhs.program && lhs.pane == rhs.pane
    }
}

/// The program running in the focused terminal pane. `key` is the terminal's
/// identifier for it (the process's `argv[0]`); `name` is an alternative label.
/// `pane` identifies the context, including Herdr addresses and multiplexer
/// pane labels. `tty` is the pane's local tty when known, used by ISP commands.
struct TerminalProgram: Equatable {
    let key: String
    let name: String?
    let pane: String?
    let tty: String?

    init(key: String, name: String? = nil, pane: String? = nil, tty: String? = nil) {
        self.key = key
        self.name = name == key ? nil : name
        self.pane = pane
        self.tty = tty
    }

    /// Names the program in diagnostics; leaves out `pane`.
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
            let scriptName = (script as NSString).lastPathComponent.components(separatedBy: ".")[0]
            // `node .` names no script: the interpreter is the program then.
            return TerminalProgram(key: packageBinName(ofScript: script) ?? (scriptName.isEmpty ? command : scriptName), name: comm)
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
    /// Runs probes one at a time and off the main thread: multiplexer lookups
    /// spawn processes, and `TerminalProbe` runs here too.
    static let queue = DispatchQueue(label: "dev.inputsourcepro.terminal-probe", qos: .userInitiated)

    /// The foreground program on the tty at `path` (e.g. `/dev/ttys008`), nil
    /// for a shell prompt or an unreadable tty. Its pane is `pane`, or the tty path.
    /// A multiplexer (tmux, zellij, herdr) is looked through to the program in its
    /// focused pane, nested up to `Multiplexer.maxDepth`; when it can't be asked,
    /// the multiplexer itself is the program. Spawns processes then, so call it
    /// on `queue`.
    static func foregroundProgram(onTTY path: String, pane: String? = nil, watchHerdrJobs: Bool = false) -> TerminalReading {
        var trail = TerminalTrail()
        var reading = foregroundProgram(onTTY: path, pane: pane, depth: 0, watchHerdrJobs: watchHerdrJobs, trail: &trail)
        reading.trail = trail
        return reading
    }

    private static func foregroundProgram(onTTY path: String, pane: String?, depth: Int, watchHerdrJobs: Bool, trail: inout TerminalTrail) -> TerminalReading {
        let pane = pane ?? path
        let processes = processes(onTTY: path)
        if let tty = TerminalTrail.TTY(watching: processes, foregroundPgid: TerminalTrail.foregroundPgid(ofPID:)) {
            trail.ttys.append(tty)
        }
        let foreground = foregroundProcess(in: processes)
        if watchHerdrJobs, foreground == nil {
            trail.herdrShellTTYs.append(path)
        }
        // Herdr keeps pane focus and the foreground group when a process execs another program or script.
        if watchHerdrJobs, let owner = foreground ?? processes.first(where: { $0.pid == $0.foregroundPgid }) {
            trail.herdrExecPIDs.insert(owner.pid)
        }
        guard let process = foreground else {
            // Non-shell processes that are not in the foreground group explain a surprising "shell".
            if processes.contains(where: { !$0.isShell }) {
                IndicatorDiagnostics.record("terminal.tty tty=\(path) tpgid=\(processes.first?.foregroundPgid ?? 0) procs=\(processes.map { "\($0.comm):\($0.pgid)" }.joined(separator: ","))")
            }
            return TerminalReading(program: nil, pane: pane, tty: path)
        }
        let arguments = arguments(pid: process.pid)
        let found = program(comm: process.comm, arguments: arguments)
        return foregroundProgram(found, onTTY: path, pane: pane, depth: depth, watchHerdrJobs: watchHerdrJobs, trail: &trail) { multiplexer, trail in
            multiplexer.focusedPane(clientPID: process.pid, clientTTY: path, arguments: arguments, trail: &trail)
        }
    }

    static func foregroundProgram(
        _ found: TerminalProgram, onTTY path: String, pane: String, depth: Int, watchHerdrJobs: Bool = false, trail: inout TerminalTrail,
        focusedPane: (Multiplexer, inout TerminalTrail) -> Multiplexer.Pane?
    ) -> TerminalReading {
        let multiplexer = Multiplexer(rawValue: found.key)
        // The client is still a Terminal Rule match when its inner pane can't be read.
        // Only that inner pane can identify the tty for program control.
        let tty = multiplexer == nil ? path : nil
        let program = TerminalProgram(key: found.key, name: found.name, pane: pane, tty: tty)
        let reading = TerminalReading(program: program, pane: pane, tty: tty)
        guard let multiplexer, depth < Multiplexer.maxDepth else { return reading }

        let inner: TerminalReading
        var paneTTY: String?
        switch focusedPane(multiplexer, &trail) {
        case nil:
            inner = reading
        case .clientOnly?:
            inner = TerminalReading(program: program, pane: pane, paneControlUnavailable: true)
        case let .tty(tty, label)?:
            paneTTY = tty
            inner = foregroundProgram(onTTY: tty, pane: label, depth: depth + 1, watchHerdrJobs: watchHerdrJobs || multiplexer == .herdr, trail: &trail)
        case let .program(paneProgram, label)?:
            inner = TerminalReading(program: paneProgram, pane: label, paneControlUnavailable: true)
        }
        IndicatorDiagnostics.record("terminal.mux kind=\(multiplexer.rawValue) client=\(path) pane=\(inner.pane ?? "-") paneTTY=\(paneTTY ?? "-") program=\(inner.program?.id ?? "shell")")
        return inner
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
    /// is gone, has no tty, or belongs to another user. Herdr reports the shell
    /// wrapping a program (`sh -c 'lazygit'`), and its tty leads to the program.
    static func ttyPath(ofPID pid: pid_t) -> String? {
        processInfo(pid)?.tty
    }

    /// The PID can be reused while its pane is unfocused.
    struct Identity: Equatable {
        let pid: pid_t
        let startTime: TimeInterval
    }

    typealias TTYOwner = (pid: pid_t, tty: String, writerStartTime: TimeInterval)

    /// The nearest process at or above `pid` (up to `maxDepth` parents) that has a tty
    /// of ours, with that tty: a program's helper (`nvim --embed`) has none, its parent does.
    /// The start time always belongs to the writer, even when a parent owns its tty.
    static func ttyOwner(ofPID pid: pid_t, maxDepth: Int = 4) -> TTYOwner? {
        ttyOwner(ofPID: pid, maxDepth: maxDepth) { processInfo($0).map { ($0.ppid, $0.tty, $0.startTime) } }
    }

    /// Where `pid` stands on `tty`: gone (exited, or not on it), in the background
    /// (stopped with Ctrl-Z, or behind another job), or the foreground job.
    static func jobState(ofPID pid: pid_t, onTTY tty: String) -> JobState {
        guard let info = processInfo(pid), info.tty == tty else { return .gone }
        return info.isForeground ? .foreground : .background
    }

    enum JobState {
        case gone, background, foreground
    }

    /// `info` reads a process's parent and tty; nil when it is gone or not ours.
    static func ttyOwner(
        ofPID pid: pid_t,
        maxDepth: Int,
        info: (pid_t) -> (ppid: pid_t, tty: String?, startTime: TimeInterval)?
    ) -> TTYOwner? {
        guard var entry = info(pid) else { return nil }
        let writerStartTime = entry.startTime
        var current = pid
        for depth in 0 ... maxDepth {
            if let tty = entry.tty { return (current, tty, writerStartTime) }
            guard depth < maxDepth, entry.ppid > 1, let parent = info(entry.ppid) else { return nil }
            current = entry.ppid
            entry = parent
        }
        return nil
    }

    private static func processInfo(_ pid: pid_t) -> (ppid: pid_t, tty: String?, isForeground: Bool, startTime: TimeInterval, device: dev_t)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var entry = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // A reaped pid returns zero bytes. An unreaped writer can still
        // have a tty-owning parent, but can no longer control the pane.
        guard sysctl(&mib, u_int(mib.count), &entry, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride,
              Int32(entry.kp_proc.p_stat) != SZOMB,
              entry.kp_eproc.e_ucred.cr_uid == getuid()
        else { return nil }
        let dev = entry.kp_eproc.e_tdev
        // NODEV: no controlling tty
        return (entry.kp_eproc.e_ppid, ttyPath(forDevice: dev), entry.kp_eproc.e_pgid == entry.kp_eproc.e_tpgid, startTime(of: entry), dev)
    }

    private static func startTime(of entry: kinfo_proc) -> TimeInterval {
        let time = entry.kp_proc.p_un.__p_starttime
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000
    }

    static func ttyPath(forDevice device: dev_t) -> String? {
        guard device != -1 else { return nil }
        var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let capacity = Int32(name.count)
        guard devname_r(device, S_IFCHR, &name, capacity) != nil else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// The paths the unix sockets of `pid` are connected to, e.g. a multiplexer
    /// client's server socket; empty when the process is gone or not ours.
    static func unixSocketPeers(ofPID pid: pid_t) -> [String] {
        unixSocketPaths(ofPID: pid, listening: false)
    }

    /// Listening sockets identify a specific Herdr Desktop instance and its configuration directory.
    static func unixSocketPaths(ofPID pid: pid_t, listening: Bool) -> [String] {
        unixSockets(ofPID: pid).compactMap { socket in
            let path = listening ? (socket.listening ? socket.path : "") : socket.peerPath
            return path.isEmpty ? nil : path
        }
    }

    /// The kernel's socket and peer identifiers distinguish connections from duplicate FDs.
    struct UnixSocket {
        let id: UInt64
        let peerID: UInt64
        let path: String
        let peerPath: String
        let listening: Bool
    }

    private static func fileDescriptors(ofPID pid: pid_t) -> [proc_fdinfo]? {
        let stride = Int32(MemoryLayout<proc_fdinfo>.stride)
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size / stride) + 8)
        let capacity = Int32(fds.count) * stride
        let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, capacity)
        guard read > 0, read < capacity else { return nil }
        return Array(fds.prefix(Int(read / stride)))
    }

    /// macOS exposes each PTY master as /dev/ptmx, with the minor device
    /// number of its corresponding slave. Duplicate descriptors count once.
    static func ptyMasters(ofPID pid: pid_t) -> Set<UInt32>? {
        guard let fds = fileDescriptors(ofPID: pid) else { return nil }
        var devices = Set<UInt32>()
        for fd in fds where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
            if withUnsafeBytes(of: info.pvip.vip_path, { $0.starts(with: "/dev/ptmx\0".utf8) }) {
                devices.insert(info.pvip.vip_vi.vi_stat.vst_rdev & 0xffffff)
            }
        }
        return devices
    }

    struct PaneTTY: Equatable {
        let owner: Identity
        let path: String
        let minor: UInt32
    }

    static func paneTTY(ofPID pid: pid_t) -> PaneTTY? {
        guard let info = processInfo(pid), let path = info.tty else { return nil }
        return PaneTTY(owner: Identity(pid: pid, startTime: info.startTime), path: path, minor: UInt32(bitPattern: info.device) & 0xffffff)
    }

    static func unixSockets(ofPID pid: pid_t) -> [UnixSocket] {
        guard let fds = fileDescriptors(ofPID: pid) else { return [] }
        func path(_ address: sockaddr_un) -> String {
            withUnsafeBytes(of: address.sun_path) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        return fds.compactMap { fd in
            guard fd.proc_fdtype == PROX_FDTYPE_SOCKET else { return nil }
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_family == AF_UNIX else { return nil }
            let connection = info.psi.soi_proto.pri_un
            return UnixSocket(id: info.psi.soi_so, peerID: connection.unsi_conn_so,
                              path: path(connection.unsi_addr.ua_sun), peerPath: path(connection.unsi_caddr.ua_sun),
                              listening: Int32(info.psi.soi_options) & SO_ACCEPTCONN != 0)
        }
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
            let comm = withUnsafeBytes(of: entry.kp_proc.p_comm) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }

            return TerminalProcess(
                pid: entry.kp_proc.p_pid,
                pgid: entry.kp_eproc.e_pgid,
                foregroundPgid: entry.kp_eproc.e_tpgid,
                startTime: startTime(of: entry),
                comm: comm
            )
        }
    }

    /// The argv of `pid`, empty when it can't be read.
    static func arguments(pid: pid_t) -> [String] {
        procArgs(pid).map(arguments(fromProcArgs:)) ?? []
    }

    /// Reads only requested values from the environment following the process's argv.
    /// A restricted process can expose argv alone. Its environment is then unknown.
    static func environment(ofPID pid: pid_t, keys: Set<String>) -> [String: String]? {
        procArgs(pid).flatMap { environment(fromProcArgs: $0, keys: keys) }
    }

    private static func procArgs(_ pid: pid_t) -> ArraySlice<UInt8>? {
        var argMaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        guard sysctl(&argMaxMib, 2, &argMax, &argMaxSize, nil, 0) == 0, argMax > 0 else { return nil }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.prefix(size)
    }

    /// Parses a `KERN_PROCARGS2` buffer: `argc` (Int32), the executable path,
    /// NUL padding, then `argc` NUL-terminated arguments (the environment follows).
    static func arguments(fromProcArgs buffer: ArraySlice<UInt8>) -> [String] {
        argumentFields(buffer)?.arguments.map { String(decoding: $0, as: UTF8.self) } ?? []
    }

    private static func argumentFields(_ buffer: ArraySlice<UInt8>) -> (arguments: [ArraySlice<UInt8>], environment: ArraySlice<UInt8>)? {
        let countSize = MemoryLayout<Int32>.size
        guard buffer.count > countSize else { return nil }
        let count = Array(buffer.prefix(countSize)).withUnsafeBytes { $0.load(as: Int32.self) }
        guard count > 0 else { return nil }
        var fields = buffer.dropFirst(countSize).drop(while: { $0 != 0 }).drop(while: { $0 == 0 })
        var arguments: [ArraySlice<UInt8>] = []
        for _ in 0..<count {
            guard let end = fields.firstIndex(of: 0) else { return nil }
            arguments.append(fields[..<end])
            fields = fields[(end + 1)...]
        }
        return (arguments, fields)
    }

    static func environment(fromProcArgs buffer: ArraySlice<UInt8>, keys: Set<String>) -> [String: String]? {
        guard var fields = argumentFields(buffer)?.environment, fields.first.map({ $0 != 0 }) == true else { return nil }
        var values: [String: String] = [:]
        while fields.first != 0, let end = fields.firstIndex(of: 0) {
            let field = fields[..<end]
            if let equal = field.firstIndex(of: UInt8(ascii: "=")),
               let key = keys.first(where: { field[..<equal].elementsEqual($0.utf8) }) {
                values[key] = String(decoding: field[(equal + 1)...], as: UTF8.self)
            }
            fields = fields[(end + 1)...]
        }
        return values
    }
}

// MARK: - CLI runs

extension TerminalProcess {
    /// ISP's environment for the CLIs. zellij keeps its sockets under $TMPDIR,
    /// which a GUI app may lack.
    private static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        if environment["TMPDIR"] == nil {
            environment["TMPDIR"] = URL(fileURLWithPath: NSTemporaryDirectory()).path
        }
        return environment
    }()

    /// Where package managers install CLIs (Homebrew on Apple silicon and Intel,
    /// MacPorts, Nix), in the order they are searched: ISP runs without a login PATH.
    static let executableDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/run/current-system/sw/bin",
        NSHomeDirectory() + "/.nix-profile/bin",
    ]

    /// The first executable called `name` in `directories`, nil when there is none.
    static func executable(
        named name: String,
        in directories: [String] = executableDirectories,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> String? {
        directories.lazy.map { $0 + "/" + name }.first(where: isExecutable)
    }

    /// `path`'s standard output when it exits with status 0 within `timeout`.
    /// posix_spawn rather than `Process`: zellij's client list is polled several
    /// times a second, and `Process` costs about ten times the CPU per run.
    /// `watchdog` runs its handler `timeout` seconds on; tests fire it by hand.
    static func output(
        of path: String,
        arguments: [String],
        overridingEnvironment: [String: String] = [:],
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
        let childEnvironment = environment.merging(overridingEnvironment) { _, override in override }
        let envp = childEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
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
        var timedOut = false
        watchdog(timeout) {
            lock.withLock {
                timedOut = true
                if !exited { kill(pid, SIGKILL) }
            }
        }

        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        var readable = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
        while true {
            // Waits in slices rather than in `read`: a process the child left behind
            // can keep the pipe open long after the child itself was killed.
            if lock.withLock({ timedOut }) { break }
            let ready = poll(&readable, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { break }
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

// MARK: - Program control

/// A tty has one controlling writer in the foreground. Stopped jobs keep their
/// own keyboard and stack until they resume, release control, or exit.
struct TerminalControlTracker<Source: Equatable> {
    typealias Writer = TerminalProcess.Identity
    static var maxStack: Int { 16 }

    private struct History {
        var current: Source
        var stack: [Source] = []
    }

    private struct Entry {
        let writer: Writer
        // A shared tmux pane may have been controlled before one emulator opted in.
        var histories: [Terminal: History]
        var isSuspended = false
    }

    private var entries: [String: [Entry]] = [:]
    private var enabledAt: [Terminal: UInt64] = [:]
    private(set) var epoch: UInt64 = 0

    /// A tmux pane can be shared across emulators. Enabling one lets it use
    /// commands received from now on, while the others keep their pane state.
    mutating func setEnabledTerminals(_ terminals: [Terminal]) {
        let enabled = Set(terminals)
        guard enabled != Set(enabledAt.keys) else { return }
        let added = enabled.subtracting(enabledAt.keys)
        enabledAt = enabledAt.filter { enabled.contains($0.key) }
        if !added.isEmpty {
            epoch += 1
            for terminal in added { enabledAt[terminal] = epoch }
        }
        // Switching an emulator off forgets only its own history.
        entries = entries.compactMapValues { writers in
            let remaining = writers.compactMap { writer -> Entry? in
                var entry = writer
                entry.histories = entry.histories.filter { enabled.contains($0.key) }
                return entry.histories.isEmpty ? nil : entry
            }
            return remaining.isEmpty ? nil : remaining
        }
    }

    func acceptsCommands(from epoch: UInt64) -> Bool {
        enabledAt.values.contains { $0 <= epoch }
    }

    func acceptsCommands(from epoch: UInt64, in terminal: Terminal) -> Bool {
        enabledAt[terminal].map { $0 <= epoch } == true
    }

    private func activeEntry(on tty: String) -> Entry? {
        entries[tty]?.last { !$0.isSuspended }
    }

    func activeWriter(on tty: String, in terminal: Terminal? = nil) -> Writer? {
        guard let entry = activeEntry(on: tty) else { return nil }
        if let terminal, entry.histories[terminal] == nil { return nil }
        return entry.writer
    }

    func isControlled(_ tty: String, in terminal: Terminal? = nil) -> Bool {
        activeWriter(on: tty, in: terminal) != nil
    }

    func current(on tty: String, in terminal: Terminal) -> Source? {
        activeEntry(on: tty)?.histories[terminal]?.current
    }

    /// The last writer in a foreground job takes over. Other jobs can resume later.
    private mutating func activate(_ entry: Entry, on tty: String) {
        entries[tty, default: []].removeAll { $0.writer.pid == entry.writer.pid || !$0.isSuspended }
        entries[tty, default: []].append(entry)
    }

    mutating func select(_ source: Source, on tty: String, writer: Writer, epoch: UInt64? = nil) {
        setSource(source, on: tty, writer: writer, epoch: epoch ?? self.epoch, push: false, live: nil)
    }

    mutating func push(
        _ source: Source, on tty: String, writer: Writer, live: (terminal: Terminal, source: Source)?,
        useLiveForCurrentWriter: Bool = false, epoch: UInt64? = nil
    ) {
        setSource(
            source, on: tty, writer: writer, epoch: epoch ?? self.epoch,
            push: true, live: live, useLiveForCurrentWriter: useLiveForCurrentWriter
        )
    }

    private mutating func setSource(
        _ source: Source, on tty: String, writer: Writer, epoch: UInt64, push: Bool,
        live: (terminal: Terminal, source: Source)?, useLiveForCurrentWriter: Bool = false
    ) {
        let previous = entries[tty]?.first { $0.writer == writer }
        var histories = [Terminal: History]()
        for (terminal, since) in enabledAt where since <= epoch {
            let history = previous?.histories[terminal]
            var stack = history?.stack ?? []
            // On takeover the focused emulator can tell us its actual source.
            // Other emulators may remember a different source for the same tmux pane.
            let focusedSource = live?.terminal == terminal ? live?.source : nil
            let previousSource = (useLiveForCurrentWriter ? focusedSource : nil) ?? history?.current
            if push, let base = previousSource ?? focusedSource ?? current(on: tty, in: terminal) ?? live?.source {
                stack.append(base)
                if stack.count > Self.maxStack { stack.removeFirst() }
            }
            histories[terminal] = History(current: source, stack: stack)
        }
        guard !histories.isEmpty else { return }
        activate(Entry(writer: writer, histories: histories), on: tty)
    }

    /// Pop each eligible emulator's stack. Without a verified terminal, a result
    /// means a pane changed and should be rechecked when focus is known.
    mutating func pop(on tty: String, writer: Writer, in terminal: Terminal? = nil, epoch: UInt64? = nil) -> Source? {
        guard var entry = entries[tty]?.first(where: { $0.writer == writer }) else { return nil }
        var restored = [Terminal: Source]()
        let received = epoch ?? self.epoch
        for (client, since) in enabledAt where since <= received {
            guard let source = entry.histories[client]?.stack.popLast() else { continue }
            entry.histories[client]?.current = source
            restored[client] = source
        }
        guard !restored.isEmpty else { return nil }
        entry.isSuspended = false
        activate(entry, on: tty)
        if let terminal { return restored[terminal] }
        return restored.values.first
    }

    mutating func follow(_ source: Source, on tty: String, in terminal: Terminal) {
        guard let index = entries[tty]?.lastIndex(where: { !$0.isSuspended }),
              var histories = entries[tty]?[index].histories,
              let current = histories[terminal]?.current, source != current else { return }
        // A manual change follows the shared pane. Reapplying one emulator's
        // already-current source on focus leaves the other histories alone.
        for client in histories.keys {
            histories[client]?.current = source
        }
        entries[tty]?[index].histories = histories
    }

    mutating func release(_ tty: String, writer: Writer) {
        entries[tty]?.removeAll { $0.writer == writer }
        if entries[tty]?.isEmpty == true { entries[tty] = nil }
    }

    mutating func check(_ tty: String, state: (Writer, String) -> TerminalProcess.JobState) {
        guard let writers = entries[tty] else { return }
        let surviving = writers.compactMap { entry -> Entry? in
            var entry = entry
            switch state(entry.writer, tty) {
            case .gone: return nil
            case .background: entry.isSuspended = true
            case .foreground: entry.isSuspended = false
            }
            return entry
        }
        entries[tty] = surviving.isEmpty ? nil : surviving
    }
}
