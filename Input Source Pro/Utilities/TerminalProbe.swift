import AppKit
import AXSwift
import Darwin

/// Reads the program in the focused pane of a terminal ISP pulls from (every
/// terminal but Herdr, which pushes): each terminal names the pane's tty its
/// own way, and the kernel's process table names the tty's foreground job.
/// Runs on `TerminalProcess.queue`, never on the main thread; scriptable
/// terminals are asked with Apple Events sent from there (NSAppleScript is
/// main-thread only).
enum TerminalProbe {
    /// When each terminal last refused Automation (system uptime). Confined to `TerminalProcess.queue`.
    private static var automationDenied: [Terminal: TimeInterval] = [:]
    /// How long a refusal is believed. A refused event returns at once and never
    /// prompts again, so asking this often is cheap and picks up a later grant.
    static let automationRetryInterval: TimeInterval = 10

    /// The focused pane's program, nil for a shell prompt or, in no known
    /// pane, when the terminal can't be asked. The tty it finds becomes the
    /// terminal's focused tty, which refreshes read again. Call on `TerminalProcess.queue`.
    static func program(_ terminal: Terminal, pid: pid_t) -> TerminalReading {
        let tty: String?
        switch terminal {
        case .herdr:
            // FIFO commands need a fresh pane lookup even before the view watcher fires.
            guard let pane = HerdrDesktop.focusedPane(),
                  let address = HerdrDesktop.terminal(ofPane: pane),
                  let reading = terminal.paneProgram(pane: address, appPID: pid) else {
                return TerminalReading(program: nil, pane: nil)
            }
            return reading
        case .ghostty:
            // The quick terminal belongs to no window; the front window is the one behind it.
            if terminal.isPanelFocused {
                tty = ghosttyPanelTTY(pid: pid)
            } else {
                tty = askTTY(terminal, pid: pid, property("Gtty", of: property("GTfT", of: property("GWsT", of: property("GFWn")))))
            }
        case .iterm:
            // tty of current session of current tab of current window
            tty = askTTY(terminal, pid: pid, property("Stty", of: property("Wcsn", of: property("Crtb", of: property("Crwn")))))
        case .terminalApp:
            // tty of selected tab of window 1
            tty = askTTY(terminal, pid: pid, property("ttty", of: property("tcnt", of: element("cwin", at: 1))))
        case .wezterm:
            tty = weztermExecutable(pid: pid).flatMap { weztermTTY(pid: pid, executable: $0) }
        case .alacritty:
            return alacrittyReading(ofPID: pid)
        }
        return terminal.focusedProgram(onTTY: tty, pid: pid)
    }

    // MARK: - Apple Events (Ghostty, iTerm2, Terminal)

    /// `specifier`'s value in `terminal`, if it is a tty path.
    private static func askTTY(_ terminal: Terminal, pid: pid_t, _ specifier: NSAppleEventDescriptor) -> String? {
        guard let tty = ask(terminal, pid: pid, specifier)?.stringValue, tty.hasPrefix("/dev/") else { return nil }
        return tty
    }

    /// The quick terminal's tty: Ghostty's one terminal outside every window.
    private static func ghosttyPanelTTY(pid: pid_t) -> String? {
        guard let ttys = ghosttySurfaceProperties("Gtty", pid: pid) else { return nil }
        return panelTTY(all: ttys.all, inWindows: ttys.inWindows)
    }

    /// Without an AX answer, the regular window is unambiguous only if no
    /// quick-terminal surface exists. Surface IDs also cover a tty still opening.
    static func ghosttyHasOnlyWindowSurfaces(pid: pid_t) -> Bool {
        guard let ids = ghosttySurfaceProperties("ID  ", pid: pid), !ids.all.isEmpty,
              ids.all.allSatisfy({ !$0.isEmpty }) else { return false }
        return ids.all.sorted() == ids.inWindows.sorted()
    }

    private static func ghosttySurfaceProperties(_ code: String, pid: pid_t) -> (all: [String], inWindows: [String])? {
        let read = { (terminals: NSAppleEventDescriptor) in
            ask(.ghostty, pid: pid, property(code, of: terminals)).flatMap(strings)
        }
        // Read all surfaces last so a freshly opened quick terminal is included.
        guard let windows = read(every("Gtrm", of: every("Gwnd"))), let all = read(every("Gtrm")) else { return nil }
        return (all, windows)
    }

    /// The only tty in `all` that no window holds; nil when there is none, or
    /// several (a split quick terminal), since which one has focus is unknown.
    static func panelTTY(all: [String], inWindows: [String]) -> String? {
        let outside = all.filter { !inWindows.contains($0) }
        guard outside.count == 1, outside[0].hasPrefix("/dev/") else { return nil }
        return outside[0]
    }

    /// `specifier`'s value, asked of the running `terminal` (never launched)
    /// with a `get` Apple Event sent from this thread; nil when it isn't
    /// running, fails or doesn't answer in time. In process: an `osascript`
    /// run costs about 300 ms, the event about 10.
    private static func ask(_ terminal: Terminal, pid: pid_t, _ specifier: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        let now = ProcessInfo.processInfo.systemUptime
        guard automationDenied[terminal].map({ now - $0 >= automationRetryInterval }) ?? true else { return nil }

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kAECoreSuite),
            eventID: AEEventID(kAEGetData),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(specifier, forKeyword: keyDirectObject)
        do {
            // AppleScript's send mode, so the first ask brings up the Automation prompt as before.
            let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 2)
            automationDenied[terminal] = nil
            return reply.paramDescriptor(forKeyword: keyDirectObject)
        } catch {
            let code = (error as NSError).code
            if code == errAEEventNotPermitted || code == errAEEventWouldRequireUserConsent {
                if automationDenied[terminal] == nil {
                    NSLog("\(terminal.displayName) automation is not permitted; Terminal Rules fall back to its App Rule.")
                }
                automationDenied[terminal] = now
            }
            return nil
        }
    }

    /// The property `code` (from the app's scripting dictionary) of `container`, the app by default.
    private static func property(_ code: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        specifier(want: DescType(cProperty), form: DescType(formPropertyID), data: NSAppleEventDescriptor(typeCode: fourCharCode(code)), from: container)
    }

    /// Element `index` (1-based) of class `code` of the app.
    private static func element(_ code: String, at index: Int32) -> NSAppleEventDescriptor {
        specifier(want: fourCharCode(code), form: DescType(formAbsolutePosition), data: NSAppleEventDescriptor(int32: index), from: .null())
    }

    /// Every element of class `code` of `container`, the app by default.
    private static func every(_ code: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        var all = OSType(kAEAll)
        let data = NSAppleEventDescriptor(descriptorType: DescType(typeAbsoluteOrdinal), bytes: &all, length: MemoryLayout<OSType>.size)!
        return specifier(want: fourCharCode(code), form: DescType(formAbsolutePosition), data: data, from: container)
    }

    private static func specifier(want: DescType, form: DescType, data: NSAppleEventDescriptor, from container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeObjectSpecifier))!
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        specifier.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
        specifier.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return specifier
    }

    private static func fourCharCode(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    /// The strings in `descriptor`, nested lists flattened (one list per window).
    private static func strings(_ descriptor: NSAppleEventDescriptor) -> [String]? {
        guard descriptor.descriptorType == DescType(typeAEList) else { return descriptor.stringValue.map { [$0] } }
        var values = [String]()
        for index in 0 ..< descriptor.numberOfItems {
            guard let item = descriptor.atIndex(index + 1), let strings = strings(item) else { return nil }
            values.append(contentsOf: strings)
        }
        return values
    }

    // MARK: - WezTerm

    /// The `wezterm` CLI: the one inside the running app (a download from wezterm.org
    /// installs nothing else), else one a package manager installed.
    private static func weztermExecutable(pid: pid_t) -> String? {
        let bundled = NSRunningApplication(processIdentifier: pid)?.bundleURL?
            .appendingPathComponent("Contents/MacOS/wezterm").path
        return bundled.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
            ?? TerminalProcess.executable(named: "wezterm")
    }

    /// The focused pane's tty from `wezterm cli`, which talks to the running
    /// GUI; nil when it isn't running (`--no-auto-start`: never start a mux server).
    static func weztermTTY(pid: pid_t, executable: String) -> String? {
        // Each macOS GUI listens here, including an unpublished --always-new-process
        // instance. Pane IDs belong to that socket, so both queries must use it.
        let socket = NSHomeDirectory() + "/.local/share/wezterm/gui-sock-\(pid)"
        let cli = { (command: String) in
            TerminalProcess.output(
                of: executable, arguments: ["cli", "--no-auto-start", command, "--format", "json"],
                overridingEnvironment: ["WEZTERM_UNIX_SOCKET": socket]
            )
        }
        guard let clients = cli("list-clients"),
              let pane = focusedPaneID(fromClients: clients, pid: pid),
              let panes = cli("list")
        else { return nil }
        return tty(ofPane: pane, in: panes)
    }

    /// The frontmost GUI process's pane. Another connected client can have its own focus.
    static func focusedPaneID(fromClients output: String, pid: pid_t) -> Int? {
        struct Client: Decodable {
            let pid: pid_t
            let focusedPaneId: Int?
        }
        let clients = (try? snakeCaseDecoder.decode([Client].self, from: Data(output.utf8))) ?? []
        let matches = clients.filter { $0.pid == pid }
        return matches.count == 1 ? matches[0].focusedPaneId : nil
    }

    /// `tty_name` of pane `id` in `wezterm cli list --format json`.
    static func tty(ofPane id: Int, in output: String) -> String? {
        struct Pane: Decodable {
            let paneId: Int
            let ttyName: String?
        }
        return (try? snakeCaseDecoder.decode([Pane].self, from: Data(output.utf8)))?
            .first { $0.paneId == id }?
            .ttyName
    }

    private static var snakeCaseDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    // MARK: - Alacritty

    /// Each Alacritty window's shell is a child with its own tty. Window titles
    /// can suggest a program for Terminal Rules, but a shell can set any title.
    private static func alacrittyReading(ofPID pid: pid_t) -> TerminalReading {
        let ttys = childTTYs(of: pid)
        guard !ttys.isEmpty else { return Terminal.alacritty.focusedProgram(onTTY: nil, pid: pid) }
        let app = Application(forProcessID: pid)
        app?.messagingTimeout = 0.25
        if ttys.count == 1 {
            let windows: [UIElement]? = try? app?.attribute(.windows)
            if windows?.count == 1 { return Terminal.alacritty.focusedProgram(onTTY: ttys[0], pid: pid) }
            var reading = alacrittyRuleReading(onTTY: ttys[0], pid: pid)
            reading.paneControlUnavailable = (windows?.count ?? 0) > 1
            return reading
        }
        var trail = TerminalTrail()
        let programs = ttys.map { tty in
            let processes = TerminalProcess.processes(onTTY: tty)
            if let watched = TerminalTrail.TTY(watching: processes, foregroundPgid: TerminalTrail.foregroundPgid(ofPID:)) {
                trail.ttys.append(watched)
            }
            return (tty: tty, program: TerminalProcess.foregroundProcess(in: processes).map {
                TerminalProcess.program(comm: $0.comm, arguments: TerminalProcess.arguments(pid: $0.pid))
            })
        }
        let window: UIElement? = try? app?.attribute(.focusedWindow)
        window?.messagingTimeout = 0.25
        var reading = alacrittyReading(titled: try? window?.attribute(.title), among: programs, pid: pid)
        reading.paneControlUnavailable = true
        // If a job exits, an ambiguous title can start identifying one window.
        if reading.pane == nil { reading.trail = trail }
        return reading
    }

    /// A title-only match may name a program running in another window. Retain
    /// the ordinary rule context without exposing a tty to FIFO commands or caching one for refresh.
    static func alacrittyReading(
        titled title: String?, among programs: [(tty: String, program: TerminalProgram?)], pid: pid_t
    ) -> TerminalReading {
        let matches = programs.filter { candidate in
            guard let title, let program = candidate.program else { return false }
            return title.localizedCaseInsensitiveContains(program.key)
        }
        if matches.count == 1 { return alacrittyRuleReading(onTTY: matches[0].tty, pid: pid) }

        let unknown = Terminal.alacritty.focusedProgram(onTTY: nil, pid: pid)
        let candidates = matches.compactMap(\.program)
        guard let first = candidates.first, candidates.allSatisfy({ Multiplexer(rawValue: $0.key) == nil }) else { return unknown }
        // Keep exactly the identifiers every candidate can match. For example,
        // two versions of Claude Code share “claude” but have different kernel names.
        let common = [first.key, first.name].compactMap { $0 }.filter { identifier in
            candidates.allSatisfy { candidate in
                [candidate.key, candidate.name].contains { $0?.caseInsensitiveCompare(identifier) == .orderedSame }
            }
        }
        guard let key = common.first else { return unknown }
        return TerminalReading(program: TerminalProgram(key: key, name: common.dropFirst().first), pane: nil)
    }

    private static func alacrittyRuleReading(onTTY tty: String, pid: pid_t) -> TerminalReading {
        _ = Terminal.alacritty.focusedProgram(onTTY: nil, pid: pid)
        let reading = TerminalProcess.foregroundProgram(onTTY: tty)
        let program = reading.program.map { TerminalProgram(key: $0.key, name: $0.name, pane: $0.pane) }
        return TerminalReading(program: program, pane: reading.pane, trail: reading.trail)
    }

    /// The controlling ttys of `pid`'s children. They are `login`, owned by
    /// root, so this skips `TerminalProcess.ttyPath(ofPID:)`'s owner check.
    private static func childTTYs(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        // Room for processes started between the two calls.
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = entries.count * stride
        guard sysctl(&mib, u_int(mib.count), &entries, &size, nil, 0) == 0 else { return [] }

        return entries.prefix(size / stride).compactMap { entry in
            guard entry.kp_eproc.e_ppid == pid else { return nil }
            return TerminalProcess.ttyPath(forDevice: entry.kp_eproc.e_tdev)
        }
    }
}
