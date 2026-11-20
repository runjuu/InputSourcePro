import Combine
import CoreData
import XCTest
@testable import Input_Source_Pro

@MainActor
final class ApplicationVMTerminalTests: XCTestCase {
    func testFlippingTheFrontTerminalsSwitchRebuildsItsSubscription() {
        var isEnabled = false
        let evaluations = PassthroughSubject<Void, Never>()
        var subscribed: [String] = []
        var cancelled: [String] = []

        let subscription = ApplicationVM.frontmostSubscriptions(
            evaluations: evaluations.eraseToAnyPublisher(),
            ruledApp: { "ghostty" },
            watchedTerminal: { _ in isEnabled ? Terminal.ghostty : nil },
            subscribe: { app, terminal -> AnyPublisher<Void, Never> in
                let label = "\(app):\(terminal?.rawValue ?? "-")"
                subscribed.append(label)
                return Empty(completeImmediately: false)
                    .handleEvents(receiveCancel: { cancelled.append(label) })
                    .eraseToAnyPublisher()
            }
        )
        .sink { _ in }
        defer { subscription.cancel() }
        let plain = "ghostty:-"
        let watched = "ghostty:\(Terminal.ghostty.rawValue)"
        XCTAssertEqual(subscribed, [plain])

        evaluations.send(())
        XCTAssertEqual(subscribed, [plain], "Same app, same switch: kept")

        isEnabled = true
        evaluations.send(())
        XCTAssertEqual(subscribed, [plain, watched])
        XCTAssertEqual(cancelled, [plain])

        evaluations.send(())
        XCTAssertEqual(subscribed.count, 2)

        isEnabled = false
        evaluations.send(())
        XCTAssertEqual(subscribed, [plain, watched, plain])
        XCTAssertEqual(cancelled, [plain, watched], "Switched off: its watch stops")
    }

    /// Each new focused pane of the terminal in front shows the indicator once,
    /// through the same path as a newly focused field; the same pane read
    /// again and a read without a pane don't.
    func testANewPaneOfTheFrontTerminalShowsTheIndicatorOnce() throws {
        let ghostty = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_003)
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var reading = TerminalReading(program: TerminalProgram(key: "claude", pane: "A"), pane: "A")
            var isEnabled = true
            var probes = 0
            var delivered = 0
        }
        let state = State()
        let environment = ApplicationVM.Environment(
            frontmostApplication: { ghostty },
            focusedApplication: { nil },
            runningApplications: Just([ghostty]).eraseToAnyPublisher(),
            isTerminalEnabled: { terminal in state.lock.withLock { terminal == .ghostty && state.isEnabled } },
            probedProgram: { _ in
                state.lock.withLock {
                    state.probes += 1
                    return state.reading
                }
            },
            terminalPanelFocus: TerminalPanelFocus.Environment(
                read: { _, _ in AnyCancellable {} }
            )
        )
        let preferencesVM = try Self.inMemoryPreferencesVM()
        let applicationVM = ApplicationVM(preferencesVM: preferencesVM, environment: environment)
        var shows = 0
        let subscription = IndicatorWindowController.focusTriggeredIndicatorPublisher(
            initialEvent: nil,
            inputSource: InputSource.getCurrentInputSource(),
            focusedInputs: applicationVM.terminalPaneFocusChanges.filter { $0 == .ghostty }.mapToVoid().eraseToAnyPublisher()
        ) { _ in
            shows += 1
            return Just(()).eraseToAnyPublisher()
        }
        .sink { _ in }
        defer { subscription.cancel() }

        // Each read is waited on. Flipping Ghostty's switch off and on rebuilds its watch, which probes at once.
        func read(_ key: String?, pane: String?) {
            let program = key.map { TerminalProgram(key: $0, pane: pane) }
            let (probes, delivered) = state.lock.withLock { (state.probes, state.delivered) }
            for isEnabled in [false, true] {
                state.lock.withLock {
                    state.reading = TerminalReading(program: program, pane: pane)
                    state.isEnabled = isEnabled
                }
                preferencesVM.runtimeRuleChangeNotifier.notify()
            }
            // The watch forgets the program when it is rebuilt, so a shell is not read just because
            // none is stored: wait for the probe, then for a hop queued behind its delivery.
            Self.waitUntil("the rebuilt watch probes") { state.lock.withLock { state.probes > probes } }
            TerminalProcess.queue.async {
                DispatchQueue.main.async { state.lock.withLock { state.delivered += 1 } }
            }
            Self.waitUntil("the probe's reading is delivered") { state.lock.withLock { state.delivered > delivered } }
            Self.waitUntil("\(key ?? "shell") in \(pane ?? "no pane") is read") {
                preferencesVM.terminalPrograms[.ghostty] == program
            }
        }

        Self.waitUntil("the first probe reads pane A") { preferencesVM.terminalPrograms[.ghostty]?.pane == "A" }
        XCTAssertEqual(shows, 1)

        read("vim", pane: "A")
        XCTAssertEqual(shows, 1, "Another program in the same pane is not a new pane")

        read("vim", pane: "B")
        XCTAssertEqual(shows, 2)

        read(nil, pane: nil)
        read("vim", pane: "B")
        XCTAssertEqual(shows, 2, "A read without a pane neither shows nor forgets the pane")
    }

    static func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out: \(what)", file: file, line: line) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Stores Terminal Rules' preferences for one test: `terminal`'s switch on and a rule per
    /// program. They live in the test host's own defaults, so call the result to put back
    /// what was there.
    static func setTerminalPreferences(_ preferencesVM: PreferencesVM, enabled terminal: Terminal, rules programs: [String]) -> () -> Void {
        let defaults = UserDefaults.standard
        let keys = ["terminalRules", "enabledTerminals"]
        let saved = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        preferencesVM.update {
            // A rule needs an installed keyboard to apply.
            let keyboard = InputSource.getCurrentInputSource().persistentIdentifier
            $0.terminalRules = programs.map { TerminalRule(program: $0, inputSourceId: keyboard) }
            $0.enabledTerminals = [terminal.rawValue]
        }
        return {
            for key in keys {
                if let value = saved[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }

    /// Only a program a rule matches is a context of its own: one without a rule
    /// stays the terminal's App Rule context, so running it re-applies nothing.
    func testOnlyAProgramWithARuleIsItsOwnContext() throws {
        let ghostty = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_005)
        let preferencesVM = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(preferencesVM, enabled: .ghostty, rules: ["claude"])
        defer { restore() }
        let shell = AppKind.from(ghostty, preferencesVM: preferencesVM)
        XCTAssertNil(shell.getTerminalInfo())

        preferencesVM.terminalPrograms[.ghostty] = TerminalProgram(key: "make", pane: "A")
        let make = AppKind.from(ghostty, preferencesVM: preferencesVM)
        XCTAssertNil(make.getTerminalInfo())
        XCTAssertTrue(make.isSameAppOrWebsite(with: shell, detectAddressBar: true))
        XCTAssertEqual(make.getId(), shell.getId())

        preferencesVM.terminalPrograms[.ghostty] = TerminalProgram(key: "claude", pane: "A")
        let claude = AppKind.from(ghostty, preferencesVM: preferencesVM)
        XCTAssertEqual(claude.getTerminalInfo()?.program.key, "claude")
        XCTAssertFalse(claude.isSameAppOrWebsite(with: make, detectAddressBar: true))
        XCTAssertFalse(preferencesVM.appNeedCacheKeyboard(claude))

        // A rule whose keyboard is not installed applies nothing, so its program is no context either.
        preferencesVM.saveTerminalRule(TerminalRule(program: "nvim", inputSourceId: "com.example.not-installed"))
        preferencesVM.terminalPrograms[.ghostty] = TerminalProgram(key: "nvim", pane: "A")
        XCTAssertNil(AppKind.from(ghostty, preferencesVM: preferencesVM).getTerminalInfo())
    }

    /// A program without a rule is its own context while it controls its pane with
    /// `isp:` commands, and back in the terminal's App Rule context once it releases it.
    func testAProgramWithoutARuleIsItsOwnContextWhileItControlsItsPane() throws {
        // The process the commands are traced back to, and its tty.
        let pid: pid_t = 999_008
        let tty = "/dev/ttys999"

        let ghostty = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_007)
        let htop = TerminalProgram(key: "htop", pane: tty, tty: tty)
        let environment = ApplicationVM.Environment(
            frontmostApplication: { ghostty },
            focusedApplication: { nil },
            runningApplications: Just([ghostty]).eraseToAnyPublisher(),
            isTerminalEnabled: { $0 == .ghostty },
            probedProgram: { _ in TerminalReading(program: htop, pane: tty, tty: tty) },
            terminalPanelFocus: TerminalPanelFocus.Environment(
                read: { _, _ in AnyCancellable {} }
            ),
            ttyOwner: { _ in (pid, tty) },
            jobState: { _, _ in .foreground }
        )
        let preferencesVM = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(preferencesVM, enabled: .ghostty, rules: ["claude"])
        defer { restore() }
        let applicationVM = ApplicationVM(preferencesVM: preferencesVM, environment: environment)
        let program = { applicationVM.appKind?.getTerminalInfo()?.program }

        Self.waitUntil("htop is read in front") {
            preferencesVM.terminalPrograms[.ghostty] == htop && applicationVM.appKind?.getApp() === ghostty
        }
        XCTAssertNil(program(), "Without a rule, htop is the terminal's App Rule context")

        let source = InputSource.getCurrentInputSource().persistentIdentifier
        applicationVM.receiveTerminalControl(lines: "isp:\(pid):select:\(source)\n")
        Self.waitUntil("htop's pane becomes its own context") { program() == htop }

        applicationVM.receiveTerminalControl(lines: "isp:\(pid):release\n")
        Self.waitUntil("htop's pane goes back to the terminal's context") { program() == nil }
        XCTAssertTrue(applicationVM.appKind?.getApp() === ghostty)
    }

    /// A job in the background (`bg`, `&`) can't take the pane from whoever is at the prompt.
    func testACommandFromABackgroundJobIsIgnored() throws {
        let pid: pid_t = 999_012
        let tty = "/dev/ttys997"
        let ghostty = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_011)
        let environment = ApplicationVM.Environment(
            frontmostApplication: { ghostty },
            focusedApplication: { nil },
            runningApplications: Just([ghostty]).eraseToAnyPublisher(),
            isTerminalEnabled: { $0 == .ghostty },
            probedProgram: { _ in TerminalReading(program: nil, pane: tty, tty: tty) },
            terminalPanelFocus: TerminalPanelFocus.Environment(
                read: { _, _ in AnyCancellable {} }
            ),
            ttyOwner: { _ in (pid, tty) },
            jobState: { _, _ in .background }
        )
        let preferencesVM = try Self.inMemoryPreferencesVM()
        let applicationVM = ApplicationVM(preferencesVM: preferencesVM, environment: environment)

        let source = InputSource.getCurrentInputSource().persistentIdentifier
        applicationVM.receiveTerminalControl(lines: "isp:\(pid):select:\(source)\nisp:\(pid):push:\(source)\n")

        XCTAssertFalse(preferencesVM.terminalControl.isControlled(tty))
        XCTAssertNil(preferencesVM.terminalControl.current(on: tty))
    }

    /// A program that died before its pane was read again leaves the next one nothing to `pop`.
    func testADeadProgramsStackIsNotInherited() throws {
        let (dead, alive): (pid_t, pid_t) = (999_014, 999_015)
        let tty = "/dev/ttys996"
        let ghostty = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_013)
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var isAlive = true
        }
        let state = State()
        let environment = ApplicationVM.Environment(
            frontmostApplication: { ghostty },
            focusedApplication: { nil },
            runningApplications: Just([ghostty]).eraseToAnyPublisher(),
            isTerminalEnabled: { $0 == .ghostty },
            probedProgram: { _ in TerminalReading(program: nil, pane: nil) },
            terminalPanelFocus: TerminalPanelFocus.Environment(
                read: { _, _ in AnyCancellable {} }
            ),
            ttyOwner: { ($0, tty) },
            jobState: { pid, _ in pid == alive || state.lock.withLock { state.isAlive } ? .foreground : .gone }
        )
        let preferencesVM = try Self.inMemoryPreferencesVM()
        let applicationVM = ApplicationVM(preferencesVM: preferencesVM, environment: environment)

        let source = InputSource.getCurrentInputSource().persistentIdentifier
        applicationVM.receiveTerminalControl(lines: "isp:\(dead):select:\(source)\nisp:\(dead):push:\(source)\n")
        XCTAssertTrue(preferencesVM.terminalControl.isControlled(tty))

        state.lock.withLock { state.isAlive = false }
        applicationVM.receiveTerminalControl(lines: "isp:\(alive):pop\n")
        XCTAssertFalse(preferencesVM.terminalControl.isControlled(tty), "Nothing of the dead program's is left to pop")
    }

    /// A program that dies without `release` hands its pane back to the rules, even when
    /// the next reading of that tty already shows another program (here another htop).
    func testAWriterThatDiesWhileItsTTYAncestorLivesLeavesItsPaneUncontrolled() throws {
        let pid: pid_t = 999_010
        let parent: pid_t = 999_020
        let tty = "/dev/ttys998"

        let ghostty = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_009)
        let htop = TerminalProgram(key: "htop", pane: tty, tty: tty)
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var isEnabled = true
            var probes = 0
            var isAlive = true
            var isDelivered = false
        }
        let state = State()
        let environment = ApplicationVM.Environment(
            frontmostApplication: { ghostty },
            focusedApplication: { nil },
            runningApplications: Just([ghostty]).eraseToAnyPublisher(),
            isTerminalEnabled: { terminal in state.lock.withLock { terminal == .ghostty && state.isEnabled } },
            probedProgram: { _ in
                state.lock.withLock { state.probes += 1 }
                return TerminalReading(program: htop, pane: tty, tty: tty)
            },
            terminalPanelFocus: TerminalPanelFocus.Environment(
                read: { _, _ in AnyCancellable {} }
            ),
            ttyOwner: { writer in
                guard writer == parent || (writer == pid && state.lock.withLock({ state.isAlive })) else { return nil }
                return (parent, tty)
            },
            jobState: { owner, _ in owner == parent ? .foreground : .gone }
        )
        let preferencesVM = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(preferencesVM, enabled: .ghostty, rules: ["claude"])
        defer { restore() }
        let applicationVM = ApplicationVM(preferencesVM: preferencesVM, environment: environment)
        let program = { applicationVM.appKind?.getTerminalInfo()?.program }

        Self.waitUntil("htop is read in front") {
            preferencesVM.terminalPrograms[.ghostty] == htop && applicationVM.appKind?.getApp() === ghostty
        }
        let source = InputSource.getCurrentInputSource().persistentIdentifier
        applicationVM.receiveTerminalControl(lines: "isp:\(pid):select:\(source)\n")
        Self.waitUntil("htop's pane becomes its own context") { program() == htop }

        // It dies; flipping Ghostty's switch off and on rebuilds its watch, which reads the pane again.
        let probes = state.lock.withLock {
            state.isAlive = false
            return state.probes
        }
        for isEnabled in [false, true] {
            state.lock.withLock { state.isEnabled = isEnabled }
            preferencesVM.runtimeRuleChangeNotifier.notify()
        }
        Self.waitUntil("the pane is read again") { state.lock.withLock { state.probes > probes } }
        // A hop queued behind the probe's delivery.
        TerminalProcess.queue.async {
            DispatchQueue.main.async { state.lock.withLock { state.isDelivered = true } }
        }
        Self.waitUntil("the reading is delivered") { state.lock.withLock { state.isDelivered } }
        XCTAssertFalse(preferencesVM.terminalControl.isControlled(tty))
        Self.waitUntil("htop's pane goes back to the terminal's context") { program() == nil }
    }

    func testCommandFromPreviousTerminalWhileActivatedTerminalIsBeingRead() throws {
        let old = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_091)
        let new = FakeApp(bundleIdentifier: Terminal.iterm.rawValue, pid: 999_092)
        var front: NSRunningApplication = old
        let tty = "/dev/ttys-review"
        let preferencesVM = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(preferencesVM, enabled: .ghostty, rules: [])
        defer { restore() }
        preferencesVM.setTerminal(.iterm, enabled: true)
        let vm = ApplicationVM(preferencesVM: preferencesVM, environment: .init(
            frontmostApplication: { front },
            focusedApplication: { nil },
            runningApplications: Just([old, new]).eraseToAnyPublisher(),
            isTerminalEnabled: { _ in true },
            probedProgram: { terminal in
                let path = terminal == .ghostty ? tty : "/dev/ttys-other"
                return TerminalReading(program: nil, pane: path, tty: path)
            },
            terminalPanelFocus: .init(read: { _, _ in AnyCancellable {} }),
            ttyOwner: { ($0, tty) }, jobState: { _, _ in .foreground }
        ))
        Self.waitUntil("first tty") { preferencesVM.focusedTerminalTTY(.ghostty) == tty }
        var switches = 0
        let subscription = vm.terminalSwitches.sink { _ in switches += 1 }
        defer { subscription.cancel() }
        front = new
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared, userInfo: [NSWorkspace.applicationUserInfoKey: new])
        let source = InputSource.getCurrentInputSource().persistentIdentifier
        vm.receiveTerminalControl(lines: "isp:1234:select:\(source)\n")
        XCTAssertTrue(preferencesVM.terminalControl.isControlled(tty))
        XCTAssertEqual(switches, 0, "old terminal's command should only update its pane")
    }

    func testRulesAreSavedByIdAndSwitchesAreStoredOnce() throws {
        let preferencesVM = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(preferencesVM, enabled: .ghostty, rules: ["claude"])
        defer { restore() }

        var claude = try XCTUnwrap(preferencesVM.terminalRules.first)
        claude.disabled = true
        preferencesVM.saveTerminalRule(claude)
        let nvim = TerminalRule(program: "nvim")
        preferencesVM.saveTerminalRule(nvim)
        XCTAssertEqual(preferencesVM.terminalRules, [claude, nvim], "Same id replaces, a new id appends")
        XCTAssertNil(preferencesVM.getTerminalRule(program: TerminalProgram(key: "claude")), "A disabled rule matches nothing")

        preferencesVM.deleteTerminalRules(ids: [claude.id])
        XCTAssertEqual(preferencesVM.terminalRules, [nvim])

        preferencesVM.setTerminal(.ghostty, enabled: true)
        preferencesVM.setTerminal(.iterm, enabled: true)
        XCTAssertEqual(preferencesVM.preferences.enabledTerminals, [Terminal.ghostty.rawValue, Terminal.iterm.rawValue])
        preferencesVM.setTerminal(.ghostty, enabled: false)
        XCTAssertFalse(preferencesVM.isTerminalEnabled(.ghostty))
        XCTAssertTrue(preferencesVM.isTerminalEnabled(.iterm))
    }

    static func inMemoryPreferencesVM() throws -> PreferencesVM {
        let container = NSPersistentContainer(name: "Main", managedObjectModel: PreferencesVM.managedObjectModel)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        let preferencesVM = PreferencesVM(permissionsVM: PermissionsVM(), container: container)
        preferencesVM.mainStorage.refresh()
        return preferencesVM
    }

    /// An app that isn't running: AX on its pid answers nothing.
    final class FakeApp: NSRunningApplication, @unchecked Sendable {
        private let fakeBundleIdentifier: String
        private let pid: pid_t

        init(bundleIdentifier: String, pid: pid_t) {
            fakeBundleIdentifier = bundleIdentifier
            self.pid = pid
            super.init()
        }

        override var bundleIdentifier: String? { fakeBundleIdentifier }
        override var processIdentifier: pid_t { pid }
        override var isTerminated: Bool { false }
        // NSRunningApplication compares its own process handle, which fakes don't have.
        override func isEqual(_ object: Any?) -> Bool { (object as AnyObject?) === self }
        override var hash: Int { ObjectIdentifier(self).hashValue }
    }
}
