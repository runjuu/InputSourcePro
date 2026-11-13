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
            $0.terminalRules = programs.map { TerminalRule(program: $0) }
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
