import AppKit
import AXSwift
import Darwin

/// Reads the program in a terminal's focused pane: each terminal names the
/// pane's tty its own way, and the kernel's process table names the tty's
/// foreground job.
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
    static func program(_ terminal: Terminal) -> TerminalReading {
        terminal.focusedProgram(onTTY: focusedTTY(of: terminal))
    }

    private static func focusedTTY(of terminal: Terminal) -> String? {
        switch terminal {
        case .ghostty:
            // The quick terminal belongs to no window, so `front window` names the window behind it.
            guard terminal.isPanelFocused else {
                // tty of focused terminal of selected tab of front window
                return askTTY(terminal, property("Gtty", of: property("GTfT", of: property("GWsT", of: property("GFWn")))))
            }
            return ghosttyPanelTTY()
        case .iterm:
            // tty of current session of current tab of current window
            return askTTY(terminal, property("Stty", of: property("Wcsn", of: property("Crtb", of: property("Crwn")))))
        case .terminalApp:
            // tty of selected tab of window 1
            return askTTY(terminal, property("ttty", of: property("tcnt", of: element("cwin", at: 1))))
        case .wezterm:
            return weztermTTY()
        case .alacritty:
            return alacrittyTTY()
        }
    }

    // MARK: - Apple Events (Ghostty, iTerm2, Terminal)

    /// `specifier`'s value in `terminal`, if it is a tty path.
    private static func askTTY(_ terminal: Terminal, _ specifier: NSAppleEventDescriptor) -> String? {
        guard let tty = ask(terminal, specifier)?.stringValue, tty.hasPrefix("/dev/") else { return nil }
        return tty
    }

    /// The quick terminal's tty: Ghostty's one terminal outside every window.
    private static func ghosttyPanelTTY() -> String? {
        let ttys = { (terminals: NSAppleEventDescriptor) in ask(.ghostty, property("Gtty", of: terminals)).map(strings) }
        guard let all = ttys(every("Gtrm")), let inWindows = ttys(every("Gtrm", of: every("Gwnd"))) else { return nil }
        return panelTTY(all: all, inWindows: inWindows)
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
    private static func ask(_ terminal: Terminal, _ specifier: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        let now = ProcessInfo.processInfo.systemUptime
        guard automationDenied[terminal].map({ now - $0 >= automationRetryInterval }) ?? true,
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: terminal.rawValue).first?.processIdentifier
        else { return nil }

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
    private static func strings(_ descriptor: NSAppleEventDescriptor) -> [String] {
        guard descriptor.descriptorType == DescType(typeAEList) else { return descriptor.stringValue.map { [$0] } ?? [] }
        return (0 ..< descriptor.numberOfItems).flatMap { descriptor.atIndex($0 + 1).map(strings) ?? [] }
    }

    // MARK: - WezTerm

    /// The `wezterm` CLI: the one inside the running app (a download from wezterm.org
    /// installs nothing else), else one a package manager installed.
    private static var wezterm: String? {
        let bundled = NSRunningApplication
            .runningApplications(withBundleIdentifier: Terminal.wezterm.rawValue)
            .first?.bundleURL?
            .appendingPathComponent("Contents/MacOS/wezterm").path
        return bundled.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
            ?? TerminalProcess.executable(named: "wezterm")
    }

    /// The focused pane's tty from `wezterm cli`, which talks to the running
    /// GUI; nil when it isn't running (`--no-auto-start`: never start a mux server).
    private static func weztermTTY() -> String? {
        guard let wezterm else { return nil }
        let cli = { (command: String) in
            TerminalProcess.output(of: wezterm, arguments: ["cli", "--no-auto-start", command, "--format", "json"])
        }
        guard let clients = cli("list-clients"),
              let pane = focusedPaneID(fromClients: clients),
              let panes = cli("list")
        else { return nil }
        return tty(ofPane: pane, in: panes)
    }

    /// `focused_pane_id` of the first client in `wezterm cli list-clients --format json`.
    static func focusedPaneID(fromClients output: String) -> Int? {
        struct Client: Decodable { let focusedPaneId: Int? }
        return (try? snakeCaseDecoder.decode([Client].self, from: Data(output.utf8)))?.first?.focusedPaneId
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

    /// Alacritty has no scripting interface, but each window's shell is a child
    /// of its process with its own tty; with several windows, the focused
    /// window's title picks one.
    private static func alacrittyTTY() -> String? {
        guard let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: Terminal.alacritty.rawValue)
            .first?.processIdentifier
        else { return nil }

        let ttys = childTTYs(of: pid)
        guard ttys.count > 1 else { return ttys.first }
        let programs = ttys.map { tty in
            (tty: tty, program: TerminalProcess.foregroundProcess(in: TerminalProcess.processes(onTTY: tty)).map {
                TerminalProcess.program(comm: $0.comm, arguments: TerminalProcess.arguments(pid: $0.pid))
            })
        }
        return tty(titled: focusedWindowTitle(of: pid), among: programs)
    }

    /// The window whose title names a tty's foreground program, or the only tty.
    /// shortcut: with several windows, a window whose program doesn't put its
    /// name in the title (a shell prompt, plain vim) matches nothing and gets the
    /// App Rule, and windows running the same program can't be told apart; ask
    /// Alacritty for its focused window if it ever gains an IPC query for it.
    static func tty(titled title: String?, among programs: [(tty: String, program: TerminalProgram?)]) -> String? {
        guard programs.count > 1 else { return programs.first?.tty }
        guard let title else { return nil }
        return programs.first { $0.program.map { title.localizedCaseInsensitiveContains($0.key) } ?? false }?.tty
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
            guard entry.kp_eproc.e_ppid == pid,
                  entry.kp_eproc.e_tdev != -1, // NODEV: no controlling tty
                  let name = devname(entry.kp_eproc.e_tdev, S_IFCHR)
            else { return nil }
            return "/dev/" + String(cString: name)
        }
    }

    private static func focusedWindowTitle(of pid: pid_t) -> String? {
        guard let app = Application(forProcessID: pid) else { return nil }
        // A hung terminal must not hold up the probes behind it.
        app.messagingTimeout = 0.25
        let window: UIElement? = try? app.attribute(.focusedWindow)
        window?.messagingTimeout = 0.25
        return try? window?.attribute(.title)
    }
}
