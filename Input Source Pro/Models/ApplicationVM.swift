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
    private weak var watchedTerminalApp: NSRunningApplication?
    private var terminalFocusRevision: UInt64 = 0
    private var terminalFocusSettleUntil: TimeInterval = 0
    private let terminalRefreshes = PassthroughSubject<Void, Never>()
    private let terminalControlRechecks = PassthroughSubject<Terminal, Never>()
    private var terminalControlPendingTTYs = Set<String>()
    private let terminalWriterChanges = PassthroughSubject<Void, Never>()
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
        var probedProgram: (Terminal, pid_t) -> TerminalReading
        var terminalPanelFocus: TerminalPanelFocus.Environment
        /// The process a program's command is traced back to, with its tty.
        var ttyOwner: (pid_t) -> TerminalProcess.TTYOwner? = { TerminalProcess.ttyOwner(ofPID: $0) }
        /// Where a controlling program's process stands on its tty.
        var jobState: (pid_t, String) -> TerminalProcess.JobState = TerminalProcess.jobState
        var temporaryInputWindowInProgress: () -> Bool = { false }
        var temporaryInputWindowRestored: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()

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
                terminalPanelFocus: .live,
                temporaryInputWindowInProgress: { InputSourceSwitcher.isTemporaryInputWindowInProgress },
                temporaryInputWindowRestored: InputSourceSwitcher.temporaryInputWindowRestored
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

                self.watchedTerminalApp = terminal == nil ? nil : app
                self.terminalControlPendingTTYs.removeAll()
                self.terminalFocusDidChange()
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
        terminalFocusDidChange()
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
    func receiveTerminalControl(lines: String) async {
        let epoch = preferencesVM.terminalControl.epoch
        guard preferencesVM.terminalControl.acceptsCommands(from: epoch) else { return }
        let messages = lines.split { $0 == "\n" || $0 == "\r\n" }.compactMap(TerminalControlCommand.init(line:))
        var remaining = messages[...]
        while !remaining.isEmpty {
            let waiting = environment.temporaryInputWindowInProgress()
            if waiting, let app = watchedTerminalApp {
                // A first push needs the live source of the pane we're returning to.
                // The FIFO already holds later batches while this delivery is suspended.
                let handback = environment.temporaryInputWindowRestored
                    .merge(with: Timer.delay(seconds: 1).mapToVoid())
                    .first()
                for await _ in handback.values { break }
                if !environment.temporaryInputWindowInProgress() {
                    for await _ in settledHandback(for: app).values { break }
                }
            }
            await receiveTerminalControl(&remaining, epoch: epoch, waitedForHandback: waiting)
        }
    }

    /// NSWorkspace can report the terminal in front while AX still reports ISP.
    /// Give AX the same 0.8s settling window as the app activation observer.
    private func settledHandback(for app: NSRunningApplication) -> AnyPublisher<Void, Never> {
        Timer.interval(seconds: 0.04)
            .prepend(Date())
            .prefix(21)
            .first { [weak self] _ in
                self?.watchedTerminalApp != app || self?.currentTerminalForControl() == app
            }
            .mapToVoid()
            .eraseToAnyPublisher()
    }

    private func receiveTerminalControl(
        _ remaining: inout ArraySlice<TerminalControlCommand>, epoch: UInt64, waitedForHandback: Bool
    ) async {
        // A focus-lost hook can reach the FIFO before the terminal's AX or tmux
        // notification reaches us. Verify the pane again after each handback.
        var focusedTTY: String?
        let windowStillOpen = waitedForHandback && environment.temporaryInputWindowInProgress()
        let initialApp = windowStillOpen ? nil : currentTerminalForControl()
        var publishReading: (() -> Void)?
        if let app = initialApp, let terminal = Terminal(app) {
            let pid = app.processIdentifier
            let probe = environment.probedProgram
            let lookup = { TerminalProcess.onQueue { probe(terminal, pid) } }
            // Ghostty can still name the departed split for 20 ms after its
            // focus-out hook fires, even before we receive any focus event.
            let ghosttySettleUntil = terminal == .ghostty ? ProcessInfo.processInfo.systemUptime + 0.020 : 0
            // If focus moves during the lookup, confirm the new pane once more.
            for _ in 0 ..< 2 {
                let revision = terminalFocusRevision
                let delay = max(terminalFocusSettleUntil, ghosttySettleUntil) - ProcessInfo.processInfo.systemUptime
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard currentTerminalForControl() == app else { break }
                guard revision == terminalFocusRevision else { continue }
                let reading = await withCheckedContinuation { continuation in
                    TerminalProcess.queue.async { continuation.resume(returning: probe(terminal, pid)) }
                }
                guard currentTerminalForControl() == app else { break }
                guard revision == terminalFocusRevision else { continue }
                publishReading = { self.receiveTerminalProgram(reading, for: terminal, recheck: lookup) }
                focusedTTY = reading.tty
                break
            }
        }
        func publishVerifiedPane() {
            publishReading?()
            publishReading = nil
        }
        // The lookup itself may have overlapped a selection from an ordinary rule.
        if !waitedForHandback, environment.temporaryInputWindowInProgress() { return }
        var changedTTYs = Set<String>()
        repeat {
            let message = remaining.removeFirst()
            if let tty = receiveTerminalControl(
                message, epoch: epoch, focusedTTY: focusedTTY, verifiedApp: initialApp, publishVerifiedPane: publishVerifiedPane
            ) {
                changedTTYs.insert(tty)
            }
        } while !remaining.isEmpty && (windowStillOpen || !environment.temporaryInputWindowInProgress())
        publishVerifiedPane()
        guard !changedTTYs.isEmpty, let watchedTerminalApp, let watched = Terminal(watchedTerminalApp),
              preferencesVM.terminalControl.acceptsCommands(from: epoch, in: watched) else { return }
        let currentApp = currentTerminalForControl()
        // The terminal may have changed during verification, or a preceding
        // command may have opened ISP's temporary input window mid-batch.
        // A change to the verified pane that did not switch live is still owed.
        guard focusedTTY == nil || currentApp != initialApp || changedTTYs.contains(where: { $0 == focusedTTY }) else { return }
        terminalControlPendingTTYs.formUnion(changedTTYs)
        if let app = currentApp, let terminal = Terminal(app) {
            terminalControlRechecks.send(terminal)
        }
    }

    private func terminalFocusDidChange() {
        terminalFocusRevision &+= 1
        terminalFocusSettleUntil = ProcessInfo.processInfo.systemUptime + Double(Self.terminalFocusSettleMilliseconds) / 1000
    }

    /// Re-resolve the writer on each read. A tty-less helper can exit while its
    /// foreground ancestor still owns the tty.
    private func terminalWriterState(_ writer: TerminalProcess.Identity, on tty: String) -> TerminalProcess.JobState {
        guard let owner = environment.ttyOwner(writer.pid), owner.tty == tty,
              owner.writerStartTime == writer.startTime else { return .gone }
        return environment.jobState(owner.pid, tty)
    }

    /// A helper can exit while both the foreground process group and its main program stay alive.
    /// Check only the writer of the pane being watched, for as long as it controls that pane.
    private func watchTerminalWriter(_ terminal: Terminal) -> AnyPublisher<Never, Never> {
        let preferencesVM = preferencesVM
        return terminalWriterChanges
            .prepend(())
            .map { _ -> String? in
                guard let tty = preferencesVM.focusedTerminalTTY(terminal),
                      preferencesVM.terminalControl.isControlled(tty, in: terminal) else { return nil }
                return tty
            }
            .removeDuplicates()
            .flatMapLatest { tty -> AnyPublisher<String, Never> in
                guard let tty else { return Empty().eraseToAnyPublisher() }
                return Timer.interval(seconds: 0.25).map { _ in tty }.eraseToAnyPublisher()
            }
            .handleEvents(receiveOutput: { [weak self] tty in
                guard let self, let writer = preferencesVM.terminalControl.activeWriter(on: tty, in: terminal),
                      self.terminalWriterState(writer, on: tty) != .foreground else { return }
                preferencesVM.terminalControl.check(tty, state: self.terminalWriterState)
                // Its exit can coincide with switching splits. Confirm the pane
                // before applying the rules that replace the writer's override.
                self.terminalControlPendingTTYs.insert(tty)
                self.terminalControlRechecks.send(terminal)
                self.terminalWriterChanges.send(())
            })
            .ignoreOutput()
            .eraseToAnyPublisher()
    }

    /// A terminal activation publishes its AppKind after its pane lookup. During
    /// that wait the previous app's pane is still cached, but can no longer switch.
    private func focusedTerminalApp(on tty: String) -> NSRunningApplication? {
        guard let app = currentTerminalForControl(), appKind?.getApp() == app,
              let terminal = Terminal(app), preferencesVM.focusedTerminalTTY(terminal) == tty
        else { return nil }
        return app
    }

    private func currentTerminalForControl() -> NSRunningApplication? {
        guard let app = watchedTerminalApp, let terminal = Terminal(app), preferencesVM.isTerminalEnabled(terminal) else { return nil }
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
    private func receiveTerminalControl(
        _ message: TerminalControlCommand, epoch: UInt64, focusedTTY: String?, verifiedApp: NSRunningApplication?, publishVerifiedPane: () -> Void
    ) -> String? {
        // Settings can change while verification is in flight. Keep the batch
        // only for terminals that have stayed enabled since it arrived.
        guard preferencesVM.terminalControl.acceptsCommands(from: epoch) else { return nil }
        // Use the tty owner for foreground checks and the writer PID for its lifetime.
        guard let owner = environment.ttyOwner(message.pid) else { return nil }
        let writer = TerminalProcess.Identity(pid: message.pid, startTime: owner.writerStartTime)
        let tty = owner.tty
        // Only the pane's foreground job controls it: one in the background (`bg`, `&`)
        // must not switch the source under whoever is typing at the prompt.
        let state = environment.jobState(owner.pid, tty)
        // A background writer can relinquish its own saved stack before resuming.
        guard state == .foreground || (state == .background && message.command == .release) else {
            IndicatorDiagnostics.record("terminal.isp ignored pid=\(owner.pid) tty=\(tty) cmd=\(message.command.name) background")
            return nil
        }
        let terminal = verifiedApp.flatMap(Terminal.init)
        let eligible = terminal.map { preferencesVM.terminalControl.acceptsCommands(from: epoch, in: $0) } == true
        let focusedApp = eligible && focusedTTY == tty && currentTerminalForControl() == verifiedApp ? verifiedApp : nil
        let focusedTerminal = focusedApp.flatMap(Terminal.init)
        let previousWriter = preferencesVM.terminalControl.activeWriter(on: tty, in: focusedTerminal)
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
                preferencesVM.terminalControl.select(source, on: tty, writer: writer, epoch: epoch)
                target = source
            }
        case let .push(id):
            if let source = resolve(id) {
                let live = focusedApp == nil ? nil : InputSourceSwitcher.inputSourceForReconciliation()
                preferencesVM.terminalControl.push(source, on: tty, writer: writer, live: live, epoch: epoch)
                target = source
            }
        case .pop:
            target = preferencesVM.terminalControl.pop(on: tty, writer: writer, epoch: epoch)
        case .release:
            preferencesVM.terminalControl.release(tty, writer: writer)
        }
        terminalWriterChanges.send(())

        IndicatorDiagnostics.record("terminal.isp pid=\(message.pid) owner=\(owner.pid) tty=\(tty) cmd=\(message.command.name) focused=\(focusedApp != nil) source=\(target?.persistentIdentifier ?? "-")")
        let controllerChanged = previousWriter != preferencesVM.terminalControl.activeWriter(on: tty, in: focusedTerminal)
        guard let focusedApp else { return controllerChanged || target != nil ? tty : nil }
        // The first push must see the keyboard in use before a newly discovered
        // program's rule can select another one. Publish after recording its command.
        let previousContext = appKind
        publishVerifiedPane()
        if appKind?.isSameAppOrWebsite(with: previousContext, detectAddressBar: true) == false { return nil }
        if controllerChanged {
            let context = AppKind.from(focusedApp, preferencesVM: preferencesVM)
            appKind = context
            return nil
        }
        if let target { terminalSwitches.send(target) }
        return nil
    }

    private func requestTerminalRefresh(paneMayHaveChanged: Bool) {
        // After a pane switch the last caret sample is the other pane's; the helper's resample
        // usually lands before the lookup resolves. A job starting or ending leaves the pane as it is.
        if paneMayHaveChanged {
            terminalFocusDidChange()
            CaretPalette.shared.markSampleStale()
        }
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

    private func receiveTerminalProgram(
        _ reading: TerminalReading, for terminal: Terminal, reapplyControl: Bool = false, recheck: @escaping TerminalLookup
    ) {
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
            let changed = self.updateTerminalProgram(published, for: terminal, reapplyControl: reapplyControl && published.tty == reading.tty)
            let owed = self.terminalRepublishes.removeValue(forKey: terminal) != nil
            if changed || owed { self.terminalProgramChanges.send(terminal) }
        }
    }

    /// Records a terminal's program; true when it changed.
    private func updateTerminalProgram(_ reading: TerminalReading, for terminal: Terminal, reapplyControl: Bool) -> Bool {
        let program = reading.program
        preferencesVM.terminalTTYs[terminal] = reading.tty
        // Control follows the controlling process, not what was read: it ends once the process
        // is gone, pauses while it is in the background (Ctrl-Z), and holds through a read
        // that predates it, since a just-started program is already the foreground job.
        var controlChanged = false
        if let tty = reading.tty {
            let previousWriter = preferencesVM.terminalControl.activeWriter(on: tty, in: terminal)
            preferencesVM.terminalControl.check(tty, state: terminalWriterState)
            controlChanged = preferencesVM.terminalControl.activeWriter(on: tty, in: terminal) != previousWriter
        }
        terminalWriterChanges.send(())
        // Two shell prompts both have a nil program. Moving between them still
        // changes the rules when either prompt controls its input source.
        let controlledShellTTY = reading.tty.flatMap { preferencesVM.terminalControl.isControlled($0, in: terminal) ? $0 : nil }
        let shellChanged = program == nil && appKind?.controlledShellTTY != controlledShellTTY
        let changed = preferencesVM.terminalPrograms[terminal] != program || shellChanged
        IndicatorDiagnostics.record("terminal.program bundle=\(terminal.rawValue) program=\(program?.id ?? "shell") pane=\(reading.pane ?? "-") changed=\(changed)")
        if changed {
            preferencesVM.terminalPrograms[terminal] = program
        }
        if !changed, controlChanged || reapplyControl,
           let tty = reading.tty, let focused = focusedTerminalApp(on: tty) {
            let context: AppKind = .from(focused, preferencesVM: preferencesVM)
            appKind = context
        }
        return changed
    }

    private func watchTerminalProgram(_ app: NSRunningApplication, _ terminal: Terminal) -> AnyPublisher<AppKind, Never> {
        let preferencesVM = preferencesVM
        let pid = app.processIdentifier
        let probedProgram = environment.probedProgram
        // What was read before the terminal left the front may have ended, or be another
        // pane's: the terminal is published once its focused pane has been read again.
        awaitTerminalProgram(terminal)

        // A refresh (`TerminalWatcher`) reads the remembered tty again, and once
        // more a moment later in case the change it saw had not finished.
        let refreshes = terminalRefreshes
            .merge(with: terminalRefreshes.delay(for: .milliseconds(100), scheduler: DispatchQueue.main))
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .map { () -> TerminalLookup in { TerminalProcess.onQueue { terminal.refreshedProgram(pid: pid) } } }

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
            .handleEvents(receiveOutput: { [weak self] _ in self?.terminalFocusDidChange() })
        let focusChanges = axChanges
            .filter { $0.notification != .titleChanged }
            .handleEvents(receiveOutput: { [weak self] _ in self?.terminalFocusDidChange() })
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
            .map { () -> TerminalLookup in { TerminalProcess.onQueue { probedProgram(terminal, pid) } } }

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

        // An earlier lookup may already be in flight when a writer exits or a
        // batch loses focus. Only a fresh, settled probe can settle that request.
        // The temporary input window's activation is intentionally ignored by
        // the app watcher. Verify the pane once it actually hands focus back.
        let restoredFocus = environment.temporaryInputWindowRestored
            .filter { [weak self] in self?.terminalControlPendingTTYs.isEmpty == false }
            .flatMapLatest { [weak self] _ -> AnyPublisher<Void, Never> in
                self?.settledHandback(for: app) ?? Empty().eraseToAnyPublisher()
            }
        let controlRechecks = terminalControlRechecks
            .filter { $0 == terminal }
            .mapToVoid()
            .merge(with: restoredFocus)
            .debounce(for: settle, scheduler: DispatchQueue.main)
            .flatMapLatest { [weak self] _ in
                let revision = self?.terminalFocusRevision
                let lookup = { TerminalProcess.onQueue { probedProgram(terminal, pid) } }
                return lookup().map { ($0, lookup, revision) }
            }
            .compactMap { [weak self] reading, lookup, revision -> Void? in
                guard let self, self.currentTerminalForControl() == app else { return nil }
                guard revision == self.terminalFocusRevision else {
                    self.terminalControlRechecks.send(terminal)
                    return nil
                }
                let reapply = reading.tty.map(self.terminalControlPendingTTYs.contains) == true
                self.terminalControlPendingTTYs.removeAll()
                self.receiveTerminalProgram(reading, for: terminal, reapplyControl: reapply, recheck: lookup)
                return nil
            }

        return terminalProgramChanges
            .filter { $0 == terminal }
            .mapToVoid()
            .merge(with: controlRechecks)
            .merge(with: lookedUp, terminalWatcher.watching(terminal).setOutputType(to: Void.self),
                   watchTerminalWriter(terminal).setOutputType(to: Void.self))
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
