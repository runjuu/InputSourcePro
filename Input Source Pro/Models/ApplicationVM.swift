import AppKit
import AXSwift
import Combine
import CombineExt
import os

@MainActor
final class ApplicationVM: ObservableObject {
    @Published private(set) var appKind: AppKind? = nil
    @Published private(set) var appsDiff: AppsDiff = .empty

    let logger = ISPLogger(category: String(describing: ApplicationVM.self))

    let cancelBag = CancelBag()
    let preferencesVM: PreferencesVM

    /// Reads a terminal's focused pane; run again to confirm a change to a shell.
    typealias TerminalLookup = () -> AnyPublisher<TerminalReading, Never>

    private let terminalProgramChanges = PassthroughSubject<Terminal, Never>()
    /// The terminal in front whose focused pane changed, once per new pane.
    let terminalPaneFocusChanges = PassthroughSubject<Terminal, Never>()
    /// Per terminal, the last focused pane read.
    private var terminalPanes: [Terminal: String] = [:]
    private let terminalRefreshes = PassthroughSubject<Void, Never>()
    /// Sources a program switched its focused pane to; `IndicatorVM` selects them.
    let terminalSwitches = PassthroughSubject<InputSource, Never>()
    private let terminalProgramGate = TerminalProgramGate {
        Timer.delay(seconds: ApplicationVM.terminalShellConfirmationDelay).mapToVoid().eraseToAnyPublisher()
    }
    private lazy var terminalWatcher = TerminalWatcher { [weak self] in self?.requestTerminalRefresh(paneMayHaveChanged: $0) }
    /// Terminals whose program was forgotten and is being read again: the read publishes
    /// what it finds even when that is no change, and the wait publishes if no read answers.
    private var terminalRepublishes: [Terminal: AnyCancellable] = [:]
    private lazy var terminalPanelFocus = TerminalPanelFocus(environment: environment.terminalPanelFocus) { [weak self] in
        self?.receiveTerminalPanel($0)
    }
    private let terminalPanelChanges = PassthroughSubject<Void, Never>()
    /// Fallbacks for a panel that hides without a notification, while one has focus.
    private var terminalPanelRecheck: AnyCancellable?

    lazy var windowAXNotificationPublisher = ApplicationVM
        .createWindowAXNotificationPublisher(preferencesVM: preferencesVM)

    /// What picking the app rules apply to reads from the system; tests fake it.
    struct Environment {
        var frontmostApplication: () -> NSRunningApplication?
        /// The system-wide focused app when enhanced mode is on, else nil.
        var focusedApplication: () -> NSRunningApplication?
        var runningApplications: AnyPublisher<[NSRunningApplication], Never>
        var isTerminalEnabled: (Terminal) -> Bool
        /// Asks a terminal for its focused pane; runs off the main thread.
        var probedProgram: (Terminal) -> TerminalReading
        var terminalPanelFocus: TerminalPanelFocus.Environment
        /// The process a program's command is traced back to, with its tty.
        var ttyOwner: (pid_t) -> (pid: pid_t, tty: String)? = { TerminalProcess.ttyOwner(ofPID: $0) }
        /// Where a controlling program's process stands on its tty.
        var jobState: (pid_t, String) -> TerminalProcess.JobState = TerminalProcess.jobState

        @MainActor static func live(_ preferencesVM: PreferencesVM) -> Self {
            Self(
                frontmostApplication: { NSWorkspace.shared.frontmostApplication },
                focusedApplication: {
                    guard preferencesVM.preferences.isEnhancedModeEnabled,
                          let elm: UIElement = try? systemWideElement.attribute(.focusedApplication),
                          let pid = try? elm.pid()
                    else { return nil }
                    return NSRunningApplication(processIdentifier: pid)
                },
                runningApplications: NSWorkspace.shared.publisher(for: \.runningApplications).eraseToAnyPublisher(),
                isTerminalEnabled: preferencesVM.isTerminalEnabled,
                probedProgram: TerminalProbe.program,
                terminalPanelFocus: .live
            )
        }
    }

    private let environment: Environment
    /// The running terminals `terminalPanelFocus` watches.
    private var panelTerminals: [NSRunningApplication] = []

    init(preferencesVM: PreferencesVM, environment: Environment? = nil) {
        self.preferencesVM = preferencesVM
        self.environment = environment ?? .live(preferencesVM)
        appKind = .from(self.environment.frontmostApplication(), preferencesVM: preferencesVM)

        activateAccessibilitiesForCurrentApp()
        watchApplicationChange()
        watchTerminalPanels()
        watchRuntimeRuleChange()
        watchAppsDiffChange()
    }
}

extension ApplicationVM {
    private func watchApplicationChange() {
        let axNotification = windowAXNotificationPublisher
            .mapToVoid()

        let didActivateAppNotification = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared)
            .mapToVoid()

        let activeSpaceDidChangeNotification = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
            .mapToVoid()

        // focusedApplication lags AX events, so re-read it a few times after each one.
        let axNotificationBurst = axNotification
            .flatMapLatest { _ in
                Timer.interval(seconds: 0.04)
                    .prepend(Date())
                    .prefix(21) // ~0.8 s
                    .mapToVoid()
            }

        let preferencesVM = preferencesVM
        let environment = environment
        let evaluations = Publishers
            .MergeMany([
                axNotificationBurst.eraseToAnyPublisher(),
                didActivateAppNotification.eraseToAnyPublisher(),
                activeSpaceDidChangeNotification.eraseToAnyPublisher(),
                terminalPanelChanges.eraseToAnyPublisher(),
                // A terminal's switch flipped while it is in front starts or stops its watch.
                preferencesVM.runtimeRuleChanges,
            ])
            .eraseToAnyPublisher()

        Self.frontmostSubscriptions(
            evaluations: evaluations,
            ruledApp: { () -> NSRunningApplication? in
                let frontmost = environment.frontmostApplication()
                let app = Self.ruledApp(
                    front: frontmost,
                    isOwn: frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                    panel: preferencesVM.terminalPanel
                ) { environment.focusedApplication() ?? frontmost }
                guard let app, !InputSourceSwitcher.isTemporaryInputWindowApplicationActivation(app) else { return nil }
                return app
            },
            watchedTerminal: { app in Terminal(app).flatMap { environment.isTerminalEnabled($0) ? $0 : nil } },
            subscribe: { [weak self] app, terminal -> AnyPublisher<AppKind, Never> in
                guard let self else { return Empty().eraseToAnyPublisher() }

                if let terminal {
                    return self.watchTerminalProgram(app, terminal)
                }

                guard NSApplication.isBrowser(app)
                else { return Just(.from(app, preferencesVM: preferencesVM)).eraseToAnyPublisher() }

                return Timer
                    .interval(seconds: 1)
                    .prepend(Date())
                    .compactMap { _ in app.focusedUIElement(preferencesVM: preferencesVM) }
                    .first()
                    .flatMapLatest { _ in
                        // ⌘L right after switching to the browser moves focus into the address bar. Skip the
                        // default 0.5s attach delay (the browser already answers AX) and re-read once attached.
                        app.watchAX([
                            .focusedUIElementChanged,
                            .titleChanged,
                            .windowCreated,
                        ], [.application, .window], attachImmediately: true)
                            .filter { $0.notification != .windowCreated }
                            .map { event in event.runningApp }
                    }
                    .prepend(app)
                    .compactMap { app -> AppKind? in .from(app, preferencesVM: preferencesVM) }
                    .eraseToAnyPublisher()
            }
        )
            .sink { [weak self] next in
                guard let self, !next.isSameAppOrWebsite(with: self.appKind, detectAddressBar: true) else { return }
                self.appKind = next
            }
            .store(in: cancelBag)
    }
}

extension ApplicationVM {
    /// The app rules apply to: ISP's own window when it is in front, else a
    /// terminal's focused floating panel, else the focused app.
    static func ruledApp<App>(front: App?, isOwn: Bool, panel: App?, focused: () -> App?) -> App? {
        if isOwn { return front }
        return panel ?? focused()
    }

    /// One subscription for the app rules apply to, picked again on each
    /// evaluation. It is rebuilt when the app changes, or when whether Terminal
    /// Rules watch it does (its switch flipped while it is in front).
    static func frontmostSubscriptions<App: Equatable, Output>(
        evaluations: AnyPublisher<Void, Never>,
        ruledApp: @escaping () -> App?,
        watchedTerminal: @escaping (App) -> Terminal?,
        subscribe: @escaping (App, Terminal?) -> AnyPublisher<Output, Never>
    ) -> AnyPublisher<Output, Never> {
        evaluations
            // Evaluate at launch too, so a terminal in front is watched
            // before the user first switches apps.
            .prepend(())
            .compactMap { _ -> (app: App, terminal: Terminal?)? in
                guard let app = ruledApp() else { return nil }
                return (app, watchedTerminal(app))
            }
            .removeDuplicates { (a: (app: App, terminal: Terminal?), b: (app: App, terminal: Terminal?)) in
                a.app == b.app && a.terminal == b.terminal
            }
            .flatMapLatest { (pick: (app: App, terminal: Terminal?)) in subscribe(pick.app, pick.terminal) }
            .eraseToAnyPublisher()
    }
}

extension ApplicationVM {
    /// Watches every running terminal with Terminal Rules on for a floating
    /// panel taking focus (Ghostty's quick terminal); see `TerminalPanelFocus`.
    private func watchTerminalPanels() {
        let environment = environment
        let enabledTerminals = preferencesVM.runtimeRuleChanges
            .prepend(())
            .map { Terminal.allCases.filter(environment.isTerminalEnabled) }

        environment.runningApplications
            .combineLatest(enabledTerminals) { apps, enabled in
                apps.filter { Terminal($0).map(enabled.contains) == true }
            }
            .removeDuplicates()
            .flatMapLatest { [weak self] apps -> AnyPublisher<pid_t, Never> in
                self?.panelTerminals = apps
                self?.terminalPanelFocus.watch(Set(apps.map(\.processIdentifier)))
                return Publishers.MergeMany(apps.map { app in
                    app.watchAX(TerminalPanelFocus.notifications, [.application, .window])
                        .mapToVoid()
                        // Once on watch too: ISP may start with the panel up.
                        .prepend(())
                        .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
                        .map { app.processIdentifier }
                })
                .eraseToAnyPublisher()
            }
            .sink { [weak self] in self?.terminalPanelFocus.evaluate($0) }
            .store(in: cancelBag)
    }

    private func receiveTerminalPanel(_ pid: pid_t?) {
        let panel = pid.flatMap { pid in panelTerminals.first { $0.processIdentifier == pid } }
        IndicatorDiagnostics.record("terminal.panel bundle=\((panel ?? preferencesVM.terminalPanel)?.bundleIdentifier ?? "-") focused=\(panel != nil)")
        // The program last read belongs to the other side of the panel: forget it, and
        // probe this side next (in order with the reads on the queue).
        let terminals = [(preferencesVM.terminalPanel, false), (panel, true)].compactMap { app, isFocused in
            app.flatMap { Terminal($0) }.map { (terminal: $0, isFocused: isFocused) }
        }
        for (terminal, isFocused) in terminals {
            TerminalProcess.queue.async { terminal.setPanelFocused(isFocused) }
            // A terminal still picked (its panel gave focus to its window) keeps its
            // context until this side is read, so a ruled program on both sides switches once.
            awaitTerminalProgram(terminal)
        }
        preferencesVM.terminalPanel = panel
        // Re-evaluates the frontmost app, which the panel now stands in for or hands back to.
        terminalPanelChanges.send(())

        // While the panel has focus, another app's activation and a slow poll
        // re-evaluate too, in case it hides without a notification.
        terminalPanelRecheck = pid.map { pid in
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared)
                .mapToVoid()
                .merge(with: Timer.interval(seconds: Self.terminalPanelRecheckInterval).mapToVoid())
                .sink { [weak self] _ in self?.terminalPanelFocus.evaluate(pid) }
        }
    }

    static let terminalPanelRecheckInterval: TimeInterval = 0.5

    /// What programs wrote on the control pipe: `isp:` lines, handled in order.
    /// Writes that queued up between reads arrive together; other lines are ignored.
    func receiveTerminalControl(lines: String) {
        for line in lines.split(whereSeparator: \.isNewline) {
            TerminalControlCommand(line: line).map(receiveTerminalControl)
        }
    }

    /// Re-resolve the writer on each read. A tty-less helper can exit while its
    /// foreground ancestor still owns the tty.
    private func terminalWriterState(_ pid: pid_t, on tty: String) -> TerminalProcess.JobState {
        guard let owner = environment.ttyOwner(pid), owner.tty == tty else { return .gone }
        return environment.jobState(owner.pid, tty)
    }

    /// A terminal activation publishes its AppKind after its pane lookup. During
    /// that wait the previous app's pane is still cached, but can no longer switch.
    private func focusedTerminalApp(on tty: String) -> NSRunningApplication? {
        guard let app = appKind?.getApp(), let terminal = Terminal(app),
              preferencesVM.focusedTerminalTTY(terminal) == tty
        else { return nil }
        let front = environment.frontmostApplication()
        let panel = preferencesVM.terminalPanel
        guard front == app || panel == app else { return nil }
        let focused = Self.ruledApp(front: front, isOwn: front?.processIdentifier == getpid(), panel: panel) {
            environment.focusedApplication() ?? front
        }
        return focused == app ? app : nil
    }

    /// A program's command to its pane's input source (see `TerminalControlTracker`).
    /// On the focused pane it switches like a shortcut would, through the same
    /// select path as rules; elsewhere it only updates the state.
    private func receiveTerminalControl(_ message: TerminalControlCommand) {
        // Use the tty owner for foreground checks and the writer PID for its lifetime.
        guard let owner = environment.ttyOwner(message.pid) else { return }
        let tty = owner.tty
        // Only the pane's foreground job controls it: one in the background (`bg`, `&`)
        // must not switch the source under whoever is typing at the prompt.
        guard environment.jobState(owner.pid, tty) == .foreground else {
            IndicatorDiagnostics.record("terminal.isp ignored pid=\(owner.pid) tty=\(tty) cmd=\(message.command.name) background")
            return
        }
        let focusedApp = focusedTerminalApp(on: tty)
        let previousPID = preferencesVM.terminalControl.activePID(on: tty)
        preferencesVM.terminalControl.check(tty, state: terminalWriterState)
        var target: InputSource?

        func resolve(_ id: String) -> InputSource? {
            let source = InputSource.resolvePersistedIdentifier(id)
            if source == nil {
                IndicatorDiagnostics.record("terminal.isp unresolved id=\(id)")
            }
            return source
        }

        switch message.command {
        case let .select(id):
            if let source = resolve(id) {
                preferencesVM.terminalControl.select(source, on: tty, pid: message.pid)
                target = source
            }
        case let .push(id):
            if let source = resolve(id) {
                let live = focusedApp == nil ? nil : InputSourceSwitcher.inputSourceForReconciliation()
                preferencesVM.terminalControl.push(source, on: tty, pid: message.pid, live: live)
                target = source
            }
        case .pop:
            target = preferencesVM.terminalControl.pop(on: tty, pid: message.pid)
        case .release:
            preferencesVM.terminalControl.release(tty, pid: message.pid)
        }

        IndicatorDiagnostics.record("terminal.isp pid=\(message.pid) owner=\(owner.pid) tty=\(tty) cmd=\(message.command.name) focused=\(focusedApp != nil) source=\(target?.persistentIdentifier ?? "-")")
        guard let focusedApp else { return }
        if previousPID != preferencesVM.terminalControl.activePID(on: tty) {
            let context = AppKind.from(focusedApp, preferencesVM: preferencesVM)
            // Publishing a program context selects its saved source through the
            // reducer. A shell hook stays in the app context and switches directly.
            if context.getTerminalInfo() != nil || !preferencesVM.terminalControl.isControlled(tty) {
                appKind = context
                return
            }
        }
        if let target { terminalSwitches.send(target) }
    }

    private func requestTerminalRefresh(paneMayHaveChanged: Bool) {
        // After a pane switch the last caret sample is the other pane's; the helper's resample
        // usually lands before the lookup resolves. A job starting or ending leaves the pane as it is.
        if paneMayHaveChanged { CaretPalette.shared.markSampleStale() }
        terminalRefreshes.send(())
    }

    /// How long a forgotten program waits for its read before the terminal is published without one.
    static let terminalProbeGrace: TimeInterval = 0.3

    /// Forgets `terminal`'s program, which was read somewhere else (before the terminal left
    /// the front, or on the other side of its panel), and owes one publish: by the next read,
    /// or after `terminalProbeGrace` when the terminal doesn't answer.
    private func awaitTerminalProgram(_ terminal: Terminal) {
        preferencesVM.terminalPrograms[terminal] = nil
        // Its tty with it: the pane now in front is not known to be the one a program controls.
        preferencesVM.terminalTTYs[terminal] = nil
        terminalRepublishes[terminal] = Timer.delay(seconds: Self.terminalProbeGrace).sink { [weak self] _ in
            guard let self, self.terminalRepublishes.removeValue(forKey: terminal) != nil else { return }
            self.terminalProgramChanges.send(terminal)
        }
    }

    /// How long after a focus change the terminal is asked again for its focused pane.
    static let terminalFocusSettleMilliseconds = 100

    /// The least time between two probes that window title changes ask for.
    static let terminalTitleProbeInterval: TimeInterval = 1

    /// How long a change from a program to a shell waits before it is read again.
    static let terminalShellConfirmationDelay: TimeInterval = 0.25

    private func receiveTerminalProgram(_ reading: TerminalReading, for terminal: Terminal, recheck: @escaping TerminalLookup) {
        terminalWatcher.follow(reading.trail, for: terminal)
        // Before the gate: a held shell is always in the same pane, so this fires once, right away.
        if let pane = reading.pane, terminalPanes[terminal] != pane {
            terminalPanes[terminal] = pane
            if appKind.flatMap({ Terminal($0.getApp()) }) == terminal {
                IndicatorDiagnostics.record("terminal.paneFocus bundle=\(terminal.rawValue) pane=\(pane)")
                terminalPaneFocusChanges.send(terminal)
            }
        }
        terminalProgramGate.receive(reading, current: preferencesVM.terminalPrograms[terminal], for: terminal, recheck: recheck) { [weak self] published in
            guard let self else { return }
            // A held shell's recheck is a lookup of its own: what it went through, and the
            // program it found, are what to watch from here on.
            if published.trail != reading.trail { self.terminalWatcher.follow(published.trail, for: terminal) }
            let changed = self.updateTerminalProgram(published, for: terminal)
            let owed = self.terminalRepublishes.removeValue(forKey: terminal) != nil
            if changed || owed { self.terminalProgramChanges.send(terminal) }
        }
    }

    /// Records a terminal's program; true when it changed.
    private func updateTerminalProgram(_ reading: TerminalReading, for terminal: Terminal) -> Bool {
        let program = reading.program
        preferencesVM.terminalTTYs[terminal] = reading.tty
        // Control follows the controlling process, not what was read: it ends once the process
        // is gone, pauses while it is in the background (Ctrl-Z), and holds through a read
        // that predates it, since a just-started program is already the foreground job.
        var controlChanged = false
        if let tty = reading.tty {
            let previousPID = preferencesVM.terminalControl.activePID(on: tty)
            preferencesVM.terminalControl.check(tty, state: terminalWriterState)
            controlChanged = preferencesVM.terminalControl.activePID(on: tty) != previousPID
        }
        let changed = preferencesVM.terminalPrograms[terminal] != program
        IndicatorDiagnostics.record("terminal.program bundle=\(terminal.rawValue) program=\(program?.id ?? "shell") pane=\(reading.pane ?? "-") changed=\(changed)")
        if changed {
            preferencesVM.terminalPrograms[terminal] = program
        } else if controlChanged {
            // The same program on the same tty is the same app to `isSameAppOrWebsite`, so a
            // pane whose control ended under it is evaluated again the way `release` does it.
            preferencesVM.runtimeRuleChangeNotifier.notify()
        }
        return changed
    }

    private func watchTerminalProgram(_ app: NSRunningApplication, _ terminal: Terminal) -> AnyPublisher<AppKind, Never> {
        let preferencesVM = preferencesVM
        let probedProgram = environment.probedProgram
        // What was read before the terminal left the front may have ended, or be another
        // pane's: the terminal is published once its focused pane has been read again.
        awaitTerminalProgram(terminal)

        // A refresh (`TerminalWatcher`) reads the remembered tty again, and once
        // more a moment later in case the change it saw had not finished.
        let refreshes = terminalRefreshes
            .merge(with: terminalRefreshes.delay(for: .milliseconds(100), scheduler: DispatchQueue.main))
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .map { () -> TerminalLookup in { TerminalProcess.onQueue(terminal.refreshedProgram) } }

        // Re-ask which pane has focus on activation and on AX changes: a tab
        // or split switch may announce itself only as a title change, and
        // Alacritty's only per-window signal is a window switch.
        let axChanges = app.watchAX([
            .focusedUIElementChanged,
            .focusedWindowChanged,
            .titleChanged,
            .windowCreated,
        ], [.application, .window])
            .filter { $0.notification != .windowCreated }
            .share()
        // A program that animates the window title (an agent's spinner) changes it several
        // times a second for as long as it works, so titles ask less often than focus does.
        let titleChanges = axChanges
            .filter { $0.notification == .titleChanged }
            .mapToVoid()
            .throttle(for: .seconds(Self.terminalTitleProbeInterval), scheduler: DispatchQueue.main, latest: true)
        let focusChanges = axChanges
            .filter { $0.notification != .titleChanged }
            .mapToVoid()
            .share()
        // Asked once more a moment later: for some 20ms after focus moves to another split,
        // Ghostty still names the split it left, and an answer from then stays until the next
        // change. Each ask has its own throttle, so the second lands a settle time after the
        // first rather than at the end of the first's window.
        let settle = DispatchQueue.SchedulerTimeType.Stride.milliseconds(Self.terminalFocusSettleMilliseconds)
        let settledFocusChanges = focusChanges
            .delay(for: settle, scheduler: DispatchQueue.main)
            .throttle(for: .milliseconds(300), scheduler: DispatchQueue.main, latest: true)
        let probes = focusChanges
            .throttle(for: .milliseconds(300), scheduler: DispatchQueue.main, latest: true)
            .merge(with: settledFocusChanges)
            .merge(with: titleChanges)
            // The terminal in front can gain or lose its panel without being picked again.
            .merge(with: terminalPanelChanges)
            // Picking the terminal asks at once and, as after a focus change, once more:
            // a click on another split is what brought it to the front.
            .merge(with: Just(()).delay(for: settle, scheduler: DispatchQueue.main))
            .prepend(())
            .map { () -> TerminalLookup in { TerminalProcess.onQueue { probedProgram(terminal) } } }

        // Lookups run in order on one queue, so the latest one has the newest
        // answer. Results publish through terminalProgramChanges, held or not.
        let lookedUp = refreshes
            .merge(with: probes)
            .map { lookup in lookup().map { ($0, lookup) } }
            .switchToLatest()
            .compactMap { [weak self] reading, lookup -> Void? in
                self?.receiveTerminalProgram(reading, for: terminal, recheck: lookup)
                return nil
            }

        return terminalProgramChanges
            .filter { $0 == terminal }
            .mapToVoid()
            .merge(with: lookedUp, terminalWatcher.watching(terminal).setOutputType(to: Void.self))
            .map { AppKind.from(app, preferencesVM: preferencesVM) }
            .eraseToAnyPublisher()
    }
}

extension ApplicationVM {
    private func watchRuntimeRuleChange() {
        preferencesVM.runtimeRuleChanges
            .compactMap { [weak self] _ -> AppKind? in
                guard let self = self else { return nil }
                let app = self.appKind?.getApp() ?? self.environment.frontmostApplication()
                return AppKind.from(app, preferencesVM: self.preferencesVM)
            }
            .filter { appKind in
                !InputSourceSwitcher.isTemporaryInputWindowApplicationActivation(appKind.getApp())
            }
            .sink { [weak self] in self?.appKind = $0 }
            .store(in: cancelBag)
    }

    private func watchAppsDiffChange() {
        AppsDiff
            .publisher(preferencesVM: preferencesVM)
            .assign(to: &$appsDiff)
    }

    private func activateAccessibilitiesForCurrentApp() {
        $appKind
            .compactMap { $0 }
            .filter { [weak self] _ in self?.preferencesVM.preferences.isEnhancedModeEnabled == true }
            .filter { [weak self] in self?.preferencesVM.isHideIndicator($0) != true }
            .sink { $0.getApp().activateAccessibilities() }
            .store(in: cancelBag)
    }
}

extension ApplicationVM {
    /// Publishes terminal lookup results. A change from a program to a shell in
    /// the same pane is believed only once `recheck` still reads a shell after
    /// the hold: the focused pane can read as a shell for a moment (focus
    /// briefly away), and publishing that flips the input source twice. A
    /// shell in another pane, or where either pane is unknown, is a pane
    /// switch; it and every other change publish at once, ending any hold.
    @MainActor
    final class TerminalProgramGate {
        private let hold: () -> AnyPublisher<Void, Never>
        /// Per terminal, the pane whose shell is on hold, and the wait for its recheck.
        private var holds: [Terminal: (pane: String, recheck: AnyCancellable)] = [:]

        init(hold: @escaping () -> AnyPublisher<Void, Never>) {
            self.hold = hold
        }

        func receive(
            _ reading: TerminalReading,
            current: TerminalProgram?,
            for terminal: Terminal,
            recheck: @escaping TerminalLookup,
            publish: @escaping (TerminalReading) -> Void
        ) {
            guard let current, reading.program == nil, let pane = reading.pane, pane == current.pane else {
                holds[terminal] = nil
                publish(reading)
                return
            }
            // Another read of the held shell (a refresh reads twice) keeps the first deadline.
            guard holds[terminal]?.pane != pane else { return }

            IndicatorDiagnostics.record("terminal.hold program=\(current.id) pane=\(pane)")
            holds[terminal] = (pane, hold()
                .first()
                .flatMap { _ in recheck() }
                .sink(
                    receiveCompletion: { [weak self] _ in self?.holds[terminal] = nil },
                    receiveValue: publish
                ))
        }
    }
}
