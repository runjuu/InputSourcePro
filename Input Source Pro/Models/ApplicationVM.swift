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
    private var lastTerminalHandback: TimeInterval?
    private struct PaneKeyboardObservation {
        let id = UUID()
        let app: NSRunningApplication
        let terminal: Terminal
        let tty: String
        let writer: TerminalProcess.Identity
        let source: InputSource
        let epoch: UInt64
    }
    private var pendingPaneKeyboard: PaneKeyboardObservation?
    private var verifyingPaneKeyboard = false
    private struct FocusedControlWriter {
        let app: NSRunningApplication
        let tty: String
        let writer: TerminalProcess.Identity
        let focusRevision: UInt64
    }
    private let terminalRefreshes = PassthroughSubject<Void, Never>()
    private let herdrFocusChanges = PassthroughSubject<HerdrDesktop.Focus, Never>()
    private let terminalControlRechecks = PassthroughSubject<Terminal, Never>()
    private var terminalControlPendingTTYs = Set<String>()
    private let terminalWriterChanges = PassthroughSubject<Void, Never>()
    /// Sources a program switched its focused pane to; `IndicatorVM` selects them.
    let terminalSwitches = PassthroughSubject<InputSource, Never>()
    private let terminalProgramGate = TerminalProgramGate {
        Timer.delay(seconds: ApplicationVM.terminalShellConfirmationDelay).mapToVoid().eraseToAnyPublisher()
    }
    private lazy var terminalWatcher = TerminalWatcher(
        refresh: { [weak self] in self?.requestTerminalRefresh(paneMayHaveChanged: $0) },
        focusHerdr: { [weak self] in self?.herdrFocusChanges.send($0) }
    )
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
        var inputSourceForReconciliation: @MainActor () -> InputSource = { InputSourceSwitcher.inputSourceForReconciliation() }
        var hasKeyboardFocus: (pid_t) -> Bool = { _ in true }

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
                temporaryInputWindowRestored: InputSourceSwitcher.temporaryInputWindowRestored,
                hasKeyboardFocus: { pid in
                    if let focused = PrivateInputSourceSelector.keyFocusPID() { return focused == pid }
                    guard let app: UIElement = try? systemWideElement.attribute(.focusedApplication) else { return false }
                    return (try? app.pid()) == pid
                }
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
                self.lastTerminalHandback = nil
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

    /// TIS can announce the new window's source before its app or pane is
    /// published. Only update a controlled pane after confirming it still has focus.
    func cacheKeyboardFor(_ context: AppKind, keyboard: InputSource) {
        pendingPaneKeyboard = nil
        guard let pane = preferencesVM.controlledTerminalPane(context) else {
            preferencesVM.cacheKeyboardFor(context, keyboard: keyboard)
            return
        }
        let app = context.getApp()
        guard preferencesVM.terminalControl.current(on: pane.tty, in: pane.terminal) != keyboard,
              currentTerminalForControl() == app,
              let writer = preferencesVM.terminalControl.activeWriter(on: pane.tty, in: pane.terminal) else { return }
        pendingPaneKeyboard = PaneKeyboardObservation(
            app: app, terminal: pane.terminal, tty: pane.tty, writer: writer, source: keyboard,
            epoch: preferencesVM.terminalControl.epoch
        )
        guard !verifyingPaneKeyboard else { return }
        verifyingPaneKeyboard = true
        Task { @MainActor in
            defer { verifyingPaneKeyboard = false }
            while let observation = pendingPaneKeyboard {
                let reading = await verifiedTerminalReading(for: observation.app)
                guard pendingPaneKeyboard?.id == observation.id else { continue }
                if let tty = reading?.tty { followObservedKeyboard(in: observation.app, on: tty) }
                pendingPaneKeyboard = nil
            }
        }
    }

    private func followObservedKeyboard(in app: NSRunningApplication, on tty: String) {
        guard let observation = pendingPaneKeyboard, observation.app == app, observation.tty == tty else { return }
        pendingPaneKeyboard = nil
        guard currentTerminalForControl() == app,
              preferencesVM.terminalControl.acceptsCommands(from: observation.epoch, in: observation.terminal),
              preferencesVM.terminalControl.activeWriter(on: tty, in: observation.terminal) == observation.writer,
              terminalWriterState(observation.writer, on: tty) == .foreground,
              environment.inputSourceForReconciliation() == observation.source else { return }
        preferencesVM.terminalControl.follow(observation.source, on: tty, in: observation.terminal)
    }

    /// What programs wrote on the control pipe: `isp:` lines, handled in order.
    /// Writes that queued up between reads arrive together; other lines are ignored.
    func receiveTerminalControl(lines: String) async {
        let epoch = preferencesVM.terminalControl.epoch
        guard preferencesVM.terminalControl.acceptsCommands(from: epoch) else { return }
        let messages = lines.split { $0 == "\n" || $0 == "\r\n" }.compactMap(TerminalControlCommand.init(line:))
        guard !messages.isEmpty else { return }
        var remaining = messages[...]
        var previousFocus = appKind.flatMap { context -> FocusedControlWriter? in
            guard let pane = preferencesVM.controlledTerminalPane(context),
                  preferencesVM.focusedTerminalTTY(pane.terminal) == pane.tty,
                  let writer = preferencesVM.terminalControl.activeWriter(on: pane.tty, in: pane.terminal),
                  context.getApp() == currentTerminalForControl() else { return nil }
            return FocusedControlWriter(app: context.getApp(), tty: pane.tty, writer: writer, focusRevision: terminalFocusRevision)
        }
        while !remaining.isEmpty {
            let waiting = environment.temporaryInputWindowInProgress()
            var windowStillOpen = waiting
            if let app = watchedTerminalApp {
                if waiting {
                    // A first push needs the live source of the pane we're returning to.
                    // The FIFO already holds later batches while this delivery is suspended.
                    let handback = environment.temporaryInputWindowRestored
                        .merge(with: Timer.delay(seconds: 1).mapToVoid())
                        .first()
                    for await _ in handback.values { break }
                    windowStillOpen = environment.temporaryInputWindowInProgress()
                }
                // A terminal's focus-gained hook can write after the window is
                // already closed, while AX still names ISP as the focused app.
                let recentlyRestored = lastTerminalHandback.map { ProcessInfo.processInfo.systemUptime - $0 <= 0.8 } ?? false
                if (waiting || recentlyRestored) && !windowStillOpen {
                    for await _ in settledHandback(for: app).values { break }
                }
            }
            await receiveTerminalControl(&remaining, epoch: epoch, windowStillOpen: windowStillOpen, previousFocus: &previousFocus)
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
        _ remaining: inout ArraySlice<TerminalControlCommand>, epoch: UInt64, windowStillOpen: Bool,
        previousFocus: inout FocusedControlWriter?
    ) async {
        // A focus-lost hook can reach the FIFO before the terminal's AX or tmux
        // notification reaches us. Verify the pane again after each handback.
        var focusedTTY: String?
        let handbackBeforeLookup = lastTerminalHandback
        let initialApp = windowStillOpen ? nil : currentTerminalForControl()
        var publishReading: (() -> Void)?
        if let app = initialApp, let terminal = Terminal(app) {
            let lookup = controlLookup(for: app, terminal: terminal)
            if let reading = await verifiedTerminalReading(for: app) {
                publishReading = { self.receiveTerminalProgram(reading, for: terminal, recheck: lookup) }
                focusedTTY = reading.tty
            }
        }
        func publishVerifiedPane() {
            publishReading?()
            publishReading = nil
        }
        // An ordinary rule can open and even close a window during the lookup.
        // Keep the commands queued and verify the pane after that handback.
        guard handbackBeforeLookup == lastTerminalHandback,
              windowStillOpen || !environment.temporaryInputWindowInProgress() else { return }
        var changedTTYs = Set<String>()
        repeat {
            let message = remaining.removeFirst()
            if let tty = receiveTerminalControl(
                message, epoch: epoch, focusedTTY: focusedTTY, verifiedApp: initialApp,
                previousFocus: &previousFocus, publishVerifiedPane: publishVerifiedPane
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
        terminalControlRechecks.send(watched)
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
        // A nonactivating panel can take keyboard focus without changing the
        // frontmost app or delivering its Accessibility notification yet.
        guard environment.hasKeyboardFocus(app.processIdentifier) else { return nil }
        let front = environment.frontmostApplication()
        let panel = preferencesVM.terminalPanel
        guard front == app || panel == app else { return nil }
        let focused = Self.ruledApp(front: front, isOwn: front?.processIdentifier == getpid(), panel: panel) {
            environment.focusedApplication() ?? front
        }
        return focused == app ? app : nil
    }

    /// A verified pane for a live source change. If focus moves during the
    /// lookup, confirm the new pane once after the transition settles.
    func verifiedTerminalReading(for app: NSRunningApplication) async -> TerminalReading? {
        guard let terminal = Terminal(app) else { return nil }
        let lookup = controlLookup(for: app, terminal: terminal)
        // Ghostty can still name the departed split for 20 ms after its
        // focus-out hook fires, even before we receive any focus event.
        let ghosttySettleUntil = terminal == .ghostty ? ProcessInfo.processInfo.systemUptime + 0.020 : 0
        for _ in 0 ..< 2 {
            let revision = terminalFocusRevision
            let delay = max(terminalFocusSettleUntil, ghosttySettleUntil) - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, currentTerminalForControl() == app else { return nil }
            guard revision == terminalFocusRevision else { continue }
            for await reading in lookup().values {
                if revision == terminalFocusRevision, currentTerminalForControl() == app { return reading }
            }
            if revision == terminalFocusRevision { break }
        }
        return nil
    }

    /// Asking Ghostty for all surfaces still finds the quick terminal while it
    /// is hidden. Confirm the panel against AX after the tty probe, including
    /// when the panel appeared over a normal Ghostty window without an event.
    private func controlLookup(for app: NSRunningApplication, terminal: Terminal) -> TerminalLookup {
        let probe = environment.probedProgram
        let pid = app.processIdentifier
        return validatingPanel(for: app, terminal: terminal, forControl: true) {
            TerminalProcess.onQueue { probe(terminal, pid) }
        }
    }

    /// A pending command is settled by a verified tty (including another
    /// pane), or by a known unsupported configuration. Retry unanswered reads
    /// while this terminal remains watched. Only one probe runs at a time.
    private func pendingControlReading(
        for app: NSRunningApplication, lookup: @escaping TerminalLookup, requestRevision: @escaping () -> UInt64
    ) -> AnyPublisher<TerminalReading, Never> {
        var previousRequest: UInt64?
        var retryAt: TimeInterval = 0
        var retryDelay: TimeInterval = 0
        return Timer.interval(seconds: 0.25)
            .prepend(Date())
            .delay(for: .milliseconds(Self.terminalFocusSettleMilliseconds), scheduler: DispatchQueue.main)
            .flatMapFirst { [weak self] _ -> AnyPublisher<TerminalReading, Never> in
                let revision = requestRevision()
                let now = ProcessInfo.processInfo.systemUptime
                guard let self, revision != previousRequest || now >= retryAt,
                      now >= self.terminalFocusSettleUntil, !self.environment.temporaryInputWindowInProgress(),
                      self.currentTerminalForControl() == app else { return Empty().eraseToAnyPublisher() }
                // A terminal that stays unreadable (e.g. Automation denied)
                // gets at most one probe per minute after the initial retries.
                retryDelay = revision == previousRequest ? min(60, retryDelay * 2) : 0.5
                previousRequest = revision
                retryAt = now + retryDelay
                return lookup().filter { _ in revision == requestRevision() }.eraseToAnyPublisher()
            }
            .first()
            .eraseToAnyPublisher()
    }

    private func validatingPanel(
        for app: NSRunningApplication, terminal: Terminal, forControl: Bool, lookup: @escaping TerminalLookup
    ) -> TerminalLookup {
        { [weak self] in
            guard let self, !forControl || self.currentTerminalForControl() == app else { return Empty().eraseToAnyPublisher() }
            let panel = self.preferencesVM.terminalPanel == app
            let pid = app.processIdentifier
            let panelEnvironment = self.environment.terminalPanelFocus
            let revision = self.terminalFocusRevision
            return lookup().flatMap { [weak self] reading -> AnyPublisher<TerminalReading, Never> in
                guard let self else { return Empty().eraseToAnyPublisher() }
                // Ordinary probes can also reapply a writer or discover its exit
                // before its timer fires. Verify those reads on either side of
                // Ghostty's panel, while ordinary non-panel rules keep their fast path.
                let controlsPane = reading.tty.map {
                    self.preferencesVM.terminalControl.isControlled($0, in: terminal) || self.terminalControlPendingTTYs.contains($0)
                } == true
                let checkPanel = panel || terminal == .ghostty && (forControl || controlsPane)
                if forControl || checkPanel || controlsPane {
                    guard revision == self.terminalFocusRevision, self.currentTerminalForControl() == app else {
                        return Empty().eraseToAnyPublisher()
                    }
                }
                guard checkPanel else { return Just(reading).eraseToAnyPublisher() }
                return TerminalProcess.onQueue { () -> TerminalPanelFocus.Focus? in
                    if let focus = panelEnvironment.controlAttributes(pid)?.focus { return focus }
                    if !panel, terminal == .ghostty, panelEnvironment.ghosttyHasOnlyWindowSurfaces(pid) { return .window }
                    return nil
                }
                    .compactMap { [weak self] focus in
                        guard let self, let focus, revision == self.terminalFocusRevision, self.currentTerminalForControl() == app else { return nil }
                        let focused = focus == .panel
                        if focused != panel {
                            self.terminalPanelFocus.reconcile(pid, isFocused: focused)
                            return nil
                        }
                        return focus == .background ? nil : reading
                    }
                    .eraseToAnyPublisher()
            }
            // A failed command probe leaves the focused pane and its keyboard in place.
            .filter { !forControl || $0.tty != nil || $0.paneControlUnavailable }
            .eraseToAnyPublisher()
        }
    }

    /// A program's command to its pane's input source (see `TerminalControlTracker`).
    /// On the focused pane it switches like a shortcut would, through the same
    /// select path as rules; elsewhere it only updates the state.
    private func receiveTerminalControl(
        _ message: TerminalControlCommand, epoch: UInt64, focusedTTY: String?, verifiedApp: NSRunningApplication?,
        previousFocus: inout FocusedControlWriter?, publishVerifiedPane: () -> Void
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
        // A command can finish its pane lookup before a preceding manual
        // change finishes its own. A push must remember that change in order.
        if let focusedApp { followObservedKeyboard(in: focusedApp, on: tty) }
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
                let live = focusedTerminal.map { ($0, environment.inputSourceForReconciliation()) }
                // TIS can already know about a manual switch whose notification
                // hasn't arrived. Sample it only for the writer that stayed in
                // focus; a resumed pane still needs its own remembered source.
                let useLiveForCurrentWriter = previousFocus?.app == focusedApp && previousFocus?.tty == tty
                    && previousFocus?.writer == writer && previousFocus?.focusRevision == terminalFocusRevision
                    && previousWriter == writer && !InputSourceSwitcher.hasSupersededPrivateSelection
                preferencesVM.terminalControl.push(
                    source, on: tty, writer: writer, live: live, useLiveForCurrentWriter: useLiveForCurrentWriter, epoch: epoch
                )
                target = source
            }
        case .pop:
            target = preferencesVM.terminalControl.pop(on: tty, writer: writer, in: focusedTerminal, epoch: epoch)
        case .release:
            preferencesVM.terminalControl.release(tty, writer: writer)
        }
        // Consecutive commands in one delivery stack their preceding result,
        // even while the system is still applying that selection.
        if target != nil, previousFocus?.tty == tty { previousFocus = nil }
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
        // A focus-gained hook may repeat its selection when ISP's temporary
        // window hands focus back. Opening that window again would retrigger the hook.
        if let target, target != environment.inputSourceForReconciliation() || InputSourceSwitcher.hasSupersededPrivateSelection {
            terminalSwitches.send(target)
        }
        return nil
    }

    /// How many times a lookup that reads nothing is tried, and the wait between tries.
    nonisolated static let terminalLookupAttempts = 3
    nonisolated static let terminalLookupRetryDelay: TimeInterval = 0.3

    /// `read` on `TerminalProcess.queue`, tried again after `delay` while it
    /// reads nothing, up to `attempts` times. A new terminal may not have its tty yet. Cancelled (a newer lookup), it stops, and a
    /// read still queued is skipped rather than holding up the newer one.
    static func retriedLookup(
        attempts: Int = terminalLookupAttempts,
        delay: @escaping () -> AnyPublisher<Void, Never> = {
            Timer.delay(seconds: ApplicationVM.terminalLookupRetryDelay).mapToVoid().eraseToAnyPublisher()
        },
        _ read: @escaping (_ isLastTry: Bool) -> TerminalReading?
    ) -> AnyPublisher<TerminalReading, Never> {
        let flag = CancelFlag()
        return TerminalProcess.onQueue { flag.isCancelled ? nil : read(attempts <= 1) }
            .handleEvents(receiveCancel: flag.cancel)
            .flatMap { reading -> AnyPublisher<TerminalReading, Never> in
                if let reading { return Just(reading).eraseToAnyPublisher() }
                guard attempts > 1 else { return Empty().eraseToAnyPublisher() }
                return delay().first()
                    .flatMap { _ in Self.retriedLookup(attempts: attempts - 1, delay: delay, read) }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
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

    private func activationLookups(for app: NSRunningApplication, terminal: Terminal) -> AnyPublisher<TerminalLookup, Never> {
        let pid = app.processIdentifier
        let probedProgram = environment.probedProgram
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
        return focusChanges
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
            .eraseToAnyPublisher()
    }

    private func watchTerminalProgram(_ app: NSRunningApplication, _ terminal: Terminal) -> AnyPublisher<AppKind, Never> {
        let preferencesVM = preferencesVM
        let pid = app.processIdentifier
        // What was read before the terminal left the front may have ended, or be another
        // pane's: the terminal is published once its focused pane has been read again.
        awaitTerminalProgram(terminal)

        // A refresh (`TerminalWatcher`) reads the remembered tty again, and once
        // more a moment later in case the change it saw had not finished.
        let refreshes = terminalRefreshes
            .merge(with: terminalRefreshes.delay(for: .milliseconds(100), scheduler: DispatchQueue.main))
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
        let lookups: AnyPublisher<TerminalLookup, Never>
        if terminal == .herdr {
            var focused: HerdrDesktop.Focus?
            let changes = herdrFocusChanges.handleEvents(receiveOutput: { [weak self] focus in
                focused = focus
                self?.terminalProgramGate.cancel(for: terminal)
                self?.terminalFocusDidChange()
                CaretPalette.shared.markSampleStale()
            })
            lookups = changes.merge(with: refreshes.compactMap { focused })
                .map { focus -> TerminalLookup in
                    { Self.retriedLookup { last in terminal.herdrReading(focus, pid: pid, lastTry: last) } }
                }.eraseToAnyPublisher()
        } else {
            lookups = refreshes.map { () -> TerminalLookup in
                { TerminalProcess.onQueue { terminal.refreshedProgram(pid: pid) }.compactMap { $0 }.eraseToAnyPublisher() }
            }.merge(with: activationLookups(for: app, terminal: terminal)).eraseToAnyPublisher()
        }
        let lookedUp = lookups
            .map { [weak self] lookup in
                let checked = self?.validatingPanel(for: app, terminal: terminal, forControl: false, lookup: lookup) ?? lookup
                return checked().map { ($0, checked) }
            }
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
            .handleEvents(receiveOutput: { [weak self] _ in
                self?.lastTerminalHandback = ProcessInfo.processInfo.systemUptime
                self?.terminalFocusDidChange()
            })
            .filter { [weak self] in self?.terminalControlPendingTTYs.isEmpty == false }
        let recheckControl = controlLookup(for: app, terminal: terminal)
        var controlRequest: UInt64 = 0
        let controlRechecks = terminalControlRechecks
            .filter { $0 == terminal }
            .mapToVoid()
            .merge(with: restoredFocus)
            // A new request invalidates an in-flight answer. The existing timer
            // will probe again, so bursts of commands never queue extra probes.
            .handleEvents(receiveOutput: { controlRequest &+= 1 })
            .flatMapFirst { [weak self] _ -> AnyPublisher<TerminalReading, Never> in
                guard let self else { return Empty().eraseToAnyPublisher() }
                return self.pendingControlReading(for: app, lookup: recheckControl, requestRevision: { controlRequest })
            }
            .compactMap { [weak self] reading -> Void? in
                guard let self, !self.terminalControlPendingTTYs.isEmpty else { return nil }
                let reapply = reading.tty.map(self.terminalControlPendingTTYs.contains) == true
                self.terminalControlPendingTTYs.removeAll()
                self.receiveTerminalProgram(reading, for: terminal, reapplyControl: reapply, recheck: recheckControl)
                return nil
            }

        return terminalProgramChanges
            .filter { $0 == terminal }
            .mapToVoid()
            .merge(with: controlRechecks)
            .merge(with: lookedUp, terminalWatcher.watching(terminal).setOutputType(to: Void.self),
                   watchTerminalWriter(terminal).setOutputType(to: Void.self))
            // Leaving the front ends a Herdr pane lookup still retrying.
            .handleEvents(receiveCancel: { [weak self] in
                self?.terminalProgramGate.cancel(for: terminal)
            })
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

        func cancel(for terminal: Terminal) { holds[terminal] = nil }

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
