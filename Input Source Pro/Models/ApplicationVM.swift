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
    private let terminalProgramGate = TerminalProgramGate {
        Timer.delay(seconds: ApplicationVM.terminalShellConfirmationDelay).mapToVoid().eraseToAnyPublisher()
    }
    private lazy var terminalWatcher = TerminalWatcher { [weak self] in self?.requestTerminalRefresh() }

    lazy var windowAXNotificationPublisher = ApplicationVM
        .createWindowAXNotificationPublisher(preferencesVM: preferencesVM)

    /// What picking the app rules apply to reads from the system; tests fake it.
    struct Environment {
        var frontmostApplication: () -> NSRunningApplication?
        /// The system-wide focused app when enhanced mode is on, else nil.
        var focusedApplication: () -> NSRunningApplication?
        var isTerminalEnabled: (Terminal) -> Bool
        /// Asks a terminal for its focused pane; runs off the main thread.
        var probedProgram: (Terminal) -> TerminalReading

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
                isTerminalEnabled: preferencesVM.isTerminalEnabled,
                probedProgram: TerminalProbe.program
            )
        }
    }

    private let environment: Environment

    init(preferencesVM: PreferencesVM, environment: Environment? = nil) {
        self.preferencesVM = preferencesVM
        self.environment = environment ?? .live(preferencesVM)
        appKind = .from(self.environment.frontmostApplication(), preferencesVM: preferencesVM)

        activateAccessibilitiesForCurrentApp()
        watchApplicationChange()
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
                // A terminal's switch flipped while it is in front starts or stops its watch.
                preferencesVM.runtimeRuleChanges,
            ])
            .eraseToAnyPublisher()

        Self.frontmostSubscriptions(
            evaluations: evaluations,
            ruledApp: { () -> NSRunningApplication? in
                // ISP's own window when it is in front, else the focused app.
                let frontmost = environment.frontmostApplication()
                let app = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                    ? frontmost
                    : environment.focusedApplication() ?? frontmost
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
            .removeDuplicates(by: { $0.isSameAppOrWebsite(with: $1, detectAddressBar: true) })
            .sink { [weak self] in self?.appKind = $0 }
            .store(in: cancelBag)
    }
}

extension ApplicationVM {
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
    private func requestTerminalRefresh() {
        // The pane may have changed; the helper's resample usually lands before the lookup resolves.
        CaretPalette.shared.markSampleStale()
        terminalRefreshes.send(())
    }

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
        terminalProgramGate.receive(reading, current: preferencesVM.terminalPrograms[terminal], for: terminal, recheck: recheck) { [weak self] reading in
            guard let self, self.updateTerminalProgram(reading, for: terminal) else { return }
            self.terminalProgramChanges.send(terminal)
        }
    }

    /// Records a terminal's program; true when it changed.
    private func updateTerminalProgram(_ reading: TerminalReading, for terminal: Terminal) -> Bool {
        let program = reading.program
        let changed = preferencesVM.terminalPrograms[terminal] != program
        IndicatorDiagnostics.record("terminal.program bundle=\(terminal.rawValue) program=\(program?.id ?? "shell") pane=\(reading.pane ?? "-") changed=\(changed)")
        if changed {
            preferencesVM.terminalPrograms[terminal] = program
        }
        return changed
    }

    private func watchTerminalProgram(_ app: NSRunningApplication, _ terminal: Terminal) -> AnyPublisher<AppKind, Never> {
        let preferencesVM = preferencesVM
        let probedProgram = environment.probedProgram

        // A refresh (`TerminalWatcher`) reads the remembered tty again, and once
        // more a moment later in case the change it saw had not finished.
        let refreshes = terminalRefreshes
            .merge(with: terminalRefreshes.delay(for: .milliseconds(100), scheduler: DispatchQueue.main))
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .map { () -> TerminalLookup in { TerminalProcess.onQueue(terminal.refreshedProgram) } }

        // Re-ask which pane has focus on activation and on AX changes: a tab
        // or split switch may announce itself only as a title change, and
        // Alacritty's only per-window signal is a window switch.
        let probes = app.watchAX([
            .focusedUIElementChanged,
            .focusedWindowChanged,
            .titleChanged,
            .windowCreated,
        ], [.application, .window])
            .filter { $0.notification != .windowCreated }
            .mapToVoid()
            .throttle(for: .milliseconds(300), scheduler: DispatchQueue.main, latest: true)
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

        // The last known program answers at once; a probe, lookup or refresh corrects it.
        return terminalProgramChanges
            .filter { $0 == terminal }
            .mapToVoid()
            .merge(with: lookedUp, terminalWatcher.watching(terminal).setOutputType(to: Void.self))
            .prepend(())
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
            // Browser URL and terminal program changes republish the same app; each activation is several AX round trips.
            .removeDuplicates { $0.getApp().processIdentifier == $1.getApp().processIdentifier }
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
