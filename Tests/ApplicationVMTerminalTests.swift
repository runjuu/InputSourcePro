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
            probedProgram: { _, _ in
                state.lock.withLock {
                    state.probes += 1
                    return state.reading
                }
            },
            terminalPanelFocus: Self.standardTerminalWindow
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

    static func waitFor(_ what: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out: \(what)", file: file, line: line) }
            try await Task.sleep(nanoseconds: 10_000_000)
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
    func testAProgramWithoutARuleIsItsOwnContextWhileItControlsItsPane() async throws {
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
            probedProgram: { _, _ in TerminalReading(program: htop, pane: tty, tty: tty) },
            terminalPanelFocus: Self.standardTerminalWindow,
            ttyOwner: { _ in (pid, tty, 0) },
            jobState: { _, _ in .foreground }
        )
        let preferencesVM = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(preferencesVM, enabled: .ghostty, rules: ["claude"])
        defer { restore() }
        let applicationVM = ApplicationVM(preferencesVM: preferencesVM, environment: environment)
        let program = { applicationVM.appKind?.getTerminalInfo()?.program }

        try await Self.waitFor("htop is read in front") {
            preferencesVM.terminalPrograms[.ghostty] == htop && applicationVM.appKind?.getApp() === ghostty
        }
        XCTAssertNil(program(), "Without a rule, htop is the terminal's App Rule context")

        let source = InputSource.getCurrentInputSource().persistentIdentifier
        await applicationVM.receiveTerminalControl(lines: "isp:\(pid):select:\(source)\n")
        try await Self.waitFor("htop's pane becomes its own context") { program() == htop }

        await applicationVM.receiveTerminalControl(lines: "isp:\(pid):release\n")
        try await Self.waitFor("htop's pane goes back to the terminal's context") { program() == nil }
        XCTAssertTrue(applicationVM.appKind?.getApp() === ghostty)
    }

    func testControlledShellSourcesFollowPaneFocusAndAppActivation() async throws {
        let ghostty = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_101)
        let other = FakeApp(bundleIdentifier: "example.other", pid: 999_102)
        let firstTTY = "/dev/ttys101"
        let secondTTY = "/dev/ttys102"
        let preferencesVM = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(preferencesVM, enabled: .ghostty, rules: [])
        defer { restore() }
        let firstSource = InputSource.getCurrentInputSource()
        let secondSource = InputSource.sources.first { $0 != firstSource } ?? firstSource
        preferencesVM.terminalControl.select(firstSource, on: firstTTY, writer: .init(pid: 101, startTime: 0))
        preferencesVM.terminalControl.select(secondSource, on: secondTTY, writer: .init(pid: 102, startTime: 0))

        var front: NSRunningApplication = ghostty
        // The activation probe sees the first pane. The settling probe sees the
        // second one while the same terminal subscription is still installed.
        let lock = NSLock()
        var probed = false
        let vm = ApplicationVM(preferencesVM: preferencesVM, environment: .init(
            frontmostApplication: { front },
            focusedApplication: { nil },
            runningApplications: Just([ghostty, other]).eraseToAnyPublisher(),
            isTerminalEnabled: { $0 == .ghostty },
            probedProgram: { _, _ in
                let tty = lock.withLock {
                    defer { probed = true }
                    return probed ? secondTTY : firstTTY
                }
                return TerminalReading(program: nil, pane: tty, tty: tty)
            },
            terminalPanelFocus: Self.standardTerminalWindow,
            ttyOwner: { ($0, $0 == 101 ? firstTTY : secondTTY, 0) },
            jobState: { _, _ in .foreground }
        ))

        var shells: [AppKind] = []
        let subscription = vm.$appKind.compactMap { $0 }.sink { app in
            if app.controlledShellTTY != nil { shells.append(app) }
        }
        defer { subscription.cancel() }
        try await Self.waitFor("both controlled shell panes were published") { shells.count >= 2 }
        let first = try XCTUnwrap(shells.first)
        let second = try XCTUnwrap(shells.last)
        XCTAssertEqual(first.controlledShellTTY, firstTTY)
        XCTAssertEqual(second.controlledShellTTY, secondTTY)
        XCTAssertFalse(first.isSameAppOrWebsite(with: second))
        XCTAssertEqual(preferencesVM.getAppAutoSwitchKeyboard(first)?.inputSource, firstSource)
        XCTAssertEqual(preferencesVM.getAppAutoSwitchKeyboard(second)?.inputSource, secondSource)
        XCTAssertFalse(preferencesVM.appNeedCacheKeyboard(second))

        func activate(_ app: NSRunningApplication) {
            front = app
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                userInfo: [NSWorkspace.applicationUserInfoKey: app]
            )
        }
        activate(other)
        try await Self.waitFor("the other app is in front") { vm.appKind?.getApp() === other }
        activate(ghostty)
        try await Self.waitFor("the same shell regained focus") { vm.appKind?.controlledShellTTY == secondTTY }
        let refocused = try XCTUnwrap(vm.appKind)
        XCTAssertEqual(preferencesVM.getAppAutoSwitchKeyboard(refocused)?.inputSource, secondSource)
        // A source notification can beat publication of the receiving app.
        front = other
        vm.cacheKeyboardFor(refocused, keyboard: firstSource)
        XCTAssertEqual(preferencesVM.terminalControl.current(on: secondTTY, in: .ghostty), secondSource)
        front = ghostty
        vm.cacheKeyboardFor(refocused, keyboard: firstSource)
        try await Self.waitFor("a manual change updates the verified shell") {
            preferencesVM.terminalControl.current(on: secondTTY, in: .ghostty) == firstSource
        }
        XCTAssertNil(preferencesVM.appKeyboardCache.retrieve(refocused))

        await vm.receiveTerminalControl(lines: "isp:102:release\n")
        try await Self.waitFor("release restored the terminal's app context") { vm.appKind?.controlledShellTTY == nil }
        XCTAssertEqual(vm.appKind?.getId(), ghostty.bundleId())
        XCTAssertTrue(preferencesVM.terminalControl.isControlled(firstTTY))

        await vm.receiveTerminalControl(lines: "isp:102:select:\(secondSource.persistentIdentifier)\n")
        try await Self.waitFor("the shell took control from the terminal's app rule") { vm.appKind?.controlledShellTTY == secondTTY }
        XCTAssertEqual(preferencesVM.terminalControl.current(on: secondTTY, in: .ghostty), secondSource)
    }

    func testManualSourceChangesOnlyUpdateTheVerifiedPaneBeforeItsNextPush() async throws {
        let app = FakeApp(bundleIdentifier: Terminal.iterm.rawValue, pid: 999_119)
        let writer = TerminalProcess.Identity(pid: 119, startTime: 0)
        let tty = "/dev/ttys119"
        let live = InputSource.getCurrentInputSource()
        let original = OtherInputSource(tisInputSource: live.tisInputSource)
        let prefs = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(prefs, enabled: .iterm, rules: [])
        defer { restore() }
        prefs.terminalControl.select(original, on: tty, writer: writer)
        let lock = NSLock()
        var focusedTTY = tty
        let vm = ApplicationVM(preferencesVM: prefs, environment: .init(
            frontmostApplication: { app }, focusedApplication: { app },
            runningApplications: Just([app]).eraseToAnyPublisher(), isTerminalEnabled: { $0 == .iterm },
            probedProgram: { _, _ in lock.withLock { TerminalReading(program: nil, pane: focusedTTY, tty: focusedTTY) } },
            terminalPanelFocus: Self.standardTerminalWindow,
            ttyOwner: { ($0, tty, 0) }, jobState: { _, _ in .foreground }, inputSourceForReconciliation: { live }
        ))
        try await Self.waitFor("the original pane has focus") { vm.appKind?.controlledShellTTY == tty }
        let originalContext = try XCTUnwrap(vm.appKind)
        lock.withLock { focusedTTY = "/dev/ttys120" }
        vm.cacheKeyboardFor(originalContext, keyboard: live)
        await vm.receiveTerminalControl(lines: "isp:119:pop\n")
        XCTAssertEqual(prefs.terminalControl.current(on: tty, in: .iterm), original)

        lock.withLock { focusedTTY = tty }
        await vm.receiveTerminalControl(lines: "isp:119:pop\n")
        vm.cacheKeyboardFor(originalContext, keyboard: live)
        await vm.receiveTerminalControl(lines: "isp:119:push:\(live.persistentIdentifier)\n")
        XCTAssertEqual(prefs.terminalControl.pop(on: tty, writer: writer, in: .iterm), live)
    }

    func testFirstPushInTheFocusedPaneReadsTheSourceBeforeItsNotification() async throws {
        let app = FakeApp(bundleIdentifier: Terminal.iterm.rawValue, pid: 999_120)
        let tty = "/dev/ttys120"
        let secondTTY = "/dev/ttys121"
        let writer = TerminalProcess.Identity(pid: 120, startTime: 0)
        let secondWriter = TerminalProcess.Identity(pid: 121, startTime: 0)
        let selected = InputSource.getCurrentInputSource()
        let manual = OtherInputSource(tisInputSource: selected.tisInputSource)
        let prefs = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(prefs, enabled: .iterm, rules: [])
        defer { restore() }
        prefs.terminalControl.select(selected, on: tty, writer: writer)
        prefs.terminalControl.select(selected, on: secondTTY, writer: secondWriter)
        let lock = NSLock()
        var focusedTTY = tty
        let vm = ApplicationVM(preferencesVM: prefs, environment: .init(
            frontmostApplication: { app }, focusedApplication: { app },
            runningApplications: Just([app]).eraseToAnyPublisher(), isTerminalEnabled: prefs.isTerminalEnabled,
            probedProgram: { _, _ in lock.withLock { TerminalReading(program: nil, pane: focusedTTY, tty: focusedTTY) } },
            terminalPanelFocus: Self.standardTerminalWindow,
            ttyOwner: { ($0, $0 == writer.pid ? tty : secondTTY, 0) }, jobState: { _, _ in .foreground },
            inputSourceForReconciliation: { manual }
        ))
        try await Self.waitFor("the writer controls the focused shell") { vm.appKind?.controlledShellTTY == tty }
        let push = "isp:120:push:\(selected.persistentIdentifier)\n"
        // The user switched sources before ISP received the TIS notification.
        // The second push also beats the system applying the first selection.
        await vm.receiveTerminalControl(lines: push + push)
        XCTAssertEqual(prefs.terminalControl.pop(on: tty, writer: writer), selected)
        XCTAssertEqual(prefs.terminalControl.pop(on: tty, writer: writer), manual)

        // A resumed editor must first recover its source from before Ctrl-Z.
        prefs.terminalControl.select(selected, on: tty, writer: writer)
        prefs.terminalControl.check(tty) { _, _ in .background }
        await vm.receiveTerminalControl(lines: push)
        XCTAssertEqual(prefs.terminalControl.pop(on: tty, writer: writer), selected)

        // A focus-gained hook arrives before ISP discovers the other split.
        lock.withLock { focusedTTY = secondTTY }
        await vm.receiveTerminalControl(lines: "isp:121:push:\(selected.persistentIdentifier)\n")
        XCTAssertEqual(prefs.terminalControl.pop(on: secondTTY, writer: secondWriter), selected)
    }

    func testUnderlyingTerminalCannotSwitchAfterAnotherAppsPanelTakesKeyboardFocus() async throws {
        let app = FakeApp(bundleIdentifier: Terminal.iterm.rawValue, pid: 999_120)
        let overlay = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_121)
        let writer = TerminalProcess.Identity(pid: 120, startTime: 0)
        let tty = "/dev/ttys120"
        let target = InputSource.getCurrentInputSource()
        let overlaySource = OtherInputSource(tisInputSource: target.tisInputSource)
        let prefs = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(prefs, enabled: .iterm, rules: [])
        defer { restore() }
        var keyboardPID = app.processIdentifier
        let vm = ApplicationVM(preferencesVM: prefs, environment: .init(
            frontmostApplication: { app }, focusedApplication: { nil },
            runningApplications: Just([app, overlay]).eraseToAnyPublisher(), isTerminalEnabled: prefs.isTerminalEnabled,
            probedProgram: { _, _ in TerminalReading(program: nil, pane: tty, tty: tty) },
            terminalPanelFocus: Self.standardTerminalWindow,
            ttyOwner: { ($0, tty, 0) }, jobState: { _, _ in .foreground },
            inputSourceForReconciliation: { overlaySource }, hasKeyboardFocus: { $0 == keyboardPID }
        ))
        try await Self.waitFor("the regular window has been read") { prefs.focusedTerminalTTY(.iterm) == tty }
        var switched = false
        let switches = vm.terminalSwitches.sink { _ in switched = true }
        defer { switches.cancel() }
        // NSWorkspace still reports iTerm2 and the panel watcher has not fired.
        keyboardPID = overlay.processIdentifier
        await vm.receiveTerminalControl(lines: "isp:120:push:\(target.persistentIdentifier)\n")
        XCTAssertTrue(prefs.terminalControl.isControlled(tty, in: .iterm))
        XCTAssertNil(prefs.terminalControl.pop(on: tty, writer: writer, in: .iterm))
        XCTAssertNil(vm.appKind?.controlledShellTTY)
        XCTAssertFalse(switched)
    }

    func testPendingCommandReappliesWhenKeyboardFocusReturnsAndThePaneCanBeVerified() async throws {
        let app = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_122)
        let tty = "/dev/ttys122"
        let writer = TerminalProcess.Identity(pid: 122, startTime: 0)
        let program = TerminalProgram(key: "nvim", pane: tty, tty: tty)
        let target = InputSource.getCurrentInputSource()
        let original = OtherInputSource(tisInputSource: target.tisInputSource)
        let prefs = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(prefs, enabled: .ghostty, rules: ["nvim"])
        defer { restore() }
        prefs.terminalControl.select(original, on: tty, writer: writer)
        var hasFocus = true
        var focusChecks = 0
        let lock = NSLock()
        var probes = 0
        var handbackProbes: Int?
        let vm = ApplicationVM(preferencesVM: prefs, environment: .init(
            frontmostApplication: { app }, focusedApplication: { nil },
            runningApplications: Just([app]).eraseToAnyPublisher(), isTerminalEnabled: prefs.isTerminalEnabled,
            probedProgram: { _, _ in
                lock.withLock {
                    probes += 1
                    if let previous = handbackProbes {
                        handbackProbes = previous + 1
                        if previous == 1 { return TerminalReading(program: nil, pane: nil) }
                    }
                    return TerminalReading(program: program, pane: tty, tty: tty)
                }
            },
            terminalPanelFocus: .init(
                read: { _, _ in AnyCancellable {} },
                controlAttributes: { _ in
                    lock.withLock {
                        handbackProbes == 1 ? nil : .init(isFrontmost: true, focusedWindowSubrole: "AXStandardWindow")
                    }
                },
                ghosttyHasOnlyWindowSurfaces: { _ in false }
            ),
            ttyOwner: { ($0, tty, 0) }, jobState: { _, _ in .foreground },
            inputSourceForReconciliation: { original }, hasKeyboardFocus: { _ in
                focusChecks += 1
                return hasFocus
            }
        ))
        try await Self.waitFor("the controlled editor's activation probes") {
            vm.appKind?.getTerminalInfo()?.program == program && lock.withLock { probes >= 2 }
        }
        var published: [InputSource] = []
        let contexts = vm.$appKind.dropFirst().compactMap { app in
            app.flatMap { prefs.getAppAutoSwitchKeyboard($0)?.inputSource }
        }.sink { published.append($0) }
        defer { contexts.cancel() }

        hasFocus = false
        let probesBeforeHandback = lock.withLock { probes }
        await vm.receiveTerminalControl(lines: "isp:122:select:\(target.persistentIdentifier)\n")
        let checksAfterCommand = focusChecks
        try await Self.waitFor("a pending command waits for keyboard focus") { focusChecks > checksAfterCommand }
        XCTAssertEqual(prefs.terminalControl.current(on: tty, in: .ghostty), target)
        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(lock.withLock { probes }, probesBeforeHandback)

        // No activation or AX notification follows. The first check cannot
        // verify the panel, and the next one cannot identify a pane.
        lock.withLock { handbackProbes = 0 }
        hasFocus = true
        try await Self.waitFor("the editor reapplies its source after the panel closes") { published == [target] }
        XCTAssertEqual(lock.withLock { handbackProbes }, 3)
    }

    func testCommandsOnlyControlTerminalsEnabledWhenTheyArrived() async throws {
        let app = FakeApp(bundleIdentifier: Terminal.iterm.rawValue, pid: 999_113)
        let tty = "/dev/ttys113"
        let program = TerminalProgram(key: "nvim", pane: tty, tty: tty)
        let prefs = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(prefs, enabled: .ghostty, rules: [])
        defer { restore() }
        prefs.setTerminal(.ghostty, enabled: false)
        let vm = ApplicationVM(preferencesVM: prefs, environment: .init(
            frontmostApplication: { app }, focusedApplication: { nil },
            runningApplications: Just([app]).eraseToAnyPublisher(), isTerminalEnabled: prefs.isTerminalEnabled,
            probedProgram: { _, _ in TerminalReading(program: program, pane: tty, tty: tty) },
            terminalPanelFocus: Self.standardTerminalWindow,
            ttyOwner: { ($0, tty, 0) }, jobState: { _, _ in .foreground }
        ))
        let source = InputSource.getCurrentInputSource()
        let select = "isp:113:select:\(source.persistentIdentifier)\n"
        await vm.receiveTerminalControl(lines: select)
        XCTAssertFalse(prefs.terminalControl.isControlled(tty))

        // The same tmux pane can subsequently be displayed by either terminal.
        prefs.setTerminal(.ghostty, enabled: true)
        XCTAssertFalse(prefs.terminalControl.isControlled(tty, in: .ghostty))
        await vm.receiveTerminalControl(lines: select)
        XCTAssertTrue(prefs.terminalControl.isControlled(tty, in: .ghostty))
        await vm.receiveTerminalControl(lines: "isp:113:push:\(source.persistentIdentifier)\n")

        prefs.setTerminal(.iterm, enabled: true)
        try await Self.waitFor("iTerm reads the shared pane") { prefs.focusedTerminalTTY(.iterm) == tty }
        XCTAssertNil(vm.appKind?.getTerminalInfo())
        XCTAssertFalse(prefs.terminalControl.isControlled(tty, in: .iterm))
        var switches = 0
        let subscription = vm.terminalSwitches.sink { _ in switches += 1 }
        defer { subscription.cancel() }
        await vm.receiveTerminalControl(lines: "isp:113:pop\n")
        XCTAssertEqual(switches, 0, "The earlier push belongs to Ghostty")
        XCTAssertFalse(prefs.terminalControl.isControlled(tty, in: .iterm))
        // Even though the writer did not change, its first new command creates
        // a program context in the newly enabled terminal.
        await vm.receiveTerminalControl(lines: select)
        XCTAssertEqual(vm.appKind?.getTerminalInfo()?.program, program)
        XCTAssertTrue(prefs.terminalControl.isControlled(tty, in: .iterm))

        prefs.setTerminal(.iterm, enabled: false)
        await vm.receiveTerminalControl(lines: select)
        prefs.setTerminal(.iterm, enabled: true)
        try await Self.waitFor("re-enabled iTerm reads the shared pane") { prefs.focusedTerminalTTY(.iterm) == tty }
        XCTAssertNil(vm.appKind?.getTerminalInfo())
        XCTAssertFalse(prefs.terminalControl.isControlled(tty, in: .iterm))
        XCTAssertTrue(prefs.terminalControl.isControlled(tty, in: .ghostty))

        prefs.setTerminal(.iterm, enabled: false)
        prefs.setTerminal(.ghostty, enabled: false)
        XCTAssertFalse(prefs.terminalControl.isControlled(tty))
    }

    /// A job in the background (`bg`, `&`) can't take the pane from whoever is at the prompt.
    func testACommandFromABackgroundJobIsIgnored() async throws {
        let pid: pid_t = 999_012
        let tty = "/dev/ttys997"
        let ghostty = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_011)
        let environment = ApplicationVM.Environment(
            frontmostApplication: { ghostty },
            focusedApplication: { nil },
            runningApplications: Just([ghostty]).eraseToAnyPublisher(),
            isTerminalEnabled: { $0 == .ghostty },
            probedProgram: { _, _ in TerminalReading(program: nil, pane: tty, tty: tty) },
            terminalPanelFocus: Self.standardTerminalWindow,
            ttyOwner: { _ in (pid, tty, 0) },
            jobState: { _, _ in .background }
        )
        let preferencesVM = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(preferencesVM, enabled: .ghostty, rules: [])
        defer { restore() }
        let applicationVM = ApplicationVM(preferencesVM: preferencesVM, environment: environment)

        let source = InputSource.getCurrentInputSource().persistentIdentifier
        await applicationVM.receiveTerminalControl(lines: "isp:\(pid):select:\(source)\nisp:\(pid):push:\(source)\n")

        XCTAssertFalse(preferencesVM.terminalControl.isControlled(tty))
        XCTAssertNil(preferencesVM.terminalControl.current(on: tty, in: .ghostty))
    }

    func testBackgroundWriterCanReleaseItsOwnSavedStack() async throws {
        let app = FakeApp(bundleIdentifier: "example.other", pid: 999_110)
        let tty = "/dev/ttys110"
        let writer: pid_t = 110
        let prefs = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(prefs, enabled: .ghostty, rules: [])
        defer { restore() }
        let vm = ApplicationVM(preferencesVM: prefs, environment: .init(
            frontmostApplication: { app }, focusedApplication: { nil },
            runningApplications: Just([app]).eraseToAnyPublisher(), isTerminalEnabled: { _ in false },
            probedProgram: { _, _ in TerminalReading(program: nil, pane: nil) },
            terminalPanelFocus: Self.standardTerminalWindow,
            ttyOwner: { ($0, tty, 0) }, jobState: { _, _ in .background }
        ))
        prefs.terminalControl.select(InputSource.getCurrentInputSource(), on: tty, writer: .init(pid: writer, startTime: 0))
        prefs.terminalControl.check(tty) { _, _ in .background }
        await vm.receiveTerminalControl(lines: "isp:\(writer):release\n")
        prefs.terminalControl.check(tty) { _, _ in .foreground }
        XCTAssertFalse(prefs.terminalControl.isControlled(tty))
    }

    /// A program that died before its pane was read again leaves the next one nothing to `pop`.
    func testADeadProgramsStackIsNotInherited() async throws {
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
            probedProgram: { _, _ in TerminalReading(program: nil, pane: nil) },
            terminalPanelFocus: Self.standardTerminalWindow,
            ttyOwner: { ($0, tty, 0) },
            jobState: { pid, _ in pid == alive || state.lock.withLock { state.isAlive } ? .foreground : .gone }
        )
        let preferencesVM = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(preferencesVM, enabled: .ghostty, rules: [])
        defer { restore() }
        let applicationVM = ApplicationVM(preferencesVM: preferencesVM, environment: environment)

        let source = InputSource.getCurrentInputSource().persistentIdentifier
        await applicationVM.receiveTerminalControl(lines: "isp:\(dead):select:\(source)\nisp:\(dead):push:\(source)\n")
        XCTAssertTrue(preferencesVM.terminalControl.isControlled(tty))

        state.lock.withLock { state.isAlive = false }
        await applicationVM.receiveTerminalControl(lines: "isp:\(alive):pop\n")
        XCTAssertFalse(preferencesVM.terminalControl.isControlled(tty), "Nothing of the dead program's is left to pop")
    }

    /// A helper that exits without `release` hands the pane back even while its parent
    /// stays in the foreground and the terminal sends no further focus or title events.
    func testAWriterThatDiesWhileItsTTYAncestorLivesLeavesItsPaneUncontrolled() async throws {
        let pid: pid_t = 999_010
        let parent: pid_t = 999_020
        let tty = "/dev/ttys998"

        let ghostty = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_009)
        let htop = TerminalProgram(key: "htop", pane: tty, tty: tty)
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var probes = 0
            var isAlive = true
        }
        let state = State()
        let environment = ApplicationVM.Environment(
            frontmostApplication: { ghostty },
            focusedApplication: { nil },
            runningApplications: Just([ghostty]).eraseToAnyPublisher(),
            isTerminalEnabled: { $0 == .ghostty },
            probedProgram: { _, _ in
                state.lock.withLock { state.probes += 1 }
                return TerminalReading(program: htop, pane: tty, tty: tty)
            },
            terminalPanelFocus: Self.standardTerminalWindow,
            ttyOwner: { writer in
                guard writer == parent || (writer == pid && state.lock.withLock({ state.isAlive })) else { return nil }
                return (parent, tty, 0)
            },
            jobState: { owner, _ in owner == parent ? .foreground : .gone }
        )
        let preferencesVM = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(preferencesVM, enabled: .ghostty, rules: ["claude"])
        defer { restore() }
        let applicationVM = ApplicationVM(preferencesVM: preferencesVM, environment: environment)
        let program = { applicationVM.appKind?.getTerminalInfo()?.program }

        try await Self.waitFor("both activation probes read htop") {
            state.lock.withLock { state.probes >= 2 } && preferencesVM.terminalPrograms[.ghostty] == htop
        }
        // Wait for the settled activation probe's result to reach the main queue before the writer exits.
        let delivered = expectation(description: "settled probe delivered")
        TerminalProcess.queue.async { DispatchQueue.main.async { delivered.fulfill() } }
        await fulfillment(of: [delivered], timeout: 5)
        let source = InputSource.getCurrentInputSource().persistentIdentifier
        await applicationVM.receiveTerminalControl(lines: "isp:\(pid):select:\(source)\n")
        try await Self.waitFor("htop's pane becomes its own context") { program() == htop }

        let probes = state.lock.withLock {
            state.isAlive = false
            return state.probes
        }
        try await Self.waitFor("htop's pane goes back to the terminal's context") { program() == nil }
        XCTAssertFalse(preferencesVM.terminalControl.isControlled(tty))
        XCTAssertEqual(state.lock.withLock { state.probes }, probes + 1, "Confirm the pane once when the writer exits")
    }

    func testCommandFromPreviousTerminalWhileActivatedTerminalIsBeingRead() async throws {
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
            probedProgram: { terminal, _ in
                let path = terminal == .ghostty ? tty : "/dev/ttys-other"
                return TerminalReading(program: nil, pane: path, tty: path)
            },
            terminalPanelFocus: Self.standardTerminalWindow,
            ttyOwner: { ($0, tty, 0) }, jobState: { _, _ in .foreground }
        ))
        try await Self.waitFor("first tty") { preferencesVM.focusedTerminalTTY(.ghostty) == tty }
        var switches = 0
        let subscription = vm.terminalSwitches.sink { _ in switches += 1 }
        defer { subscription.cancel() }
        front = new
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared, userInfo: [NSWorkspace.applicationUserInfoKey: new])
        let source = InputSource.getCurrentInputSource().persistentIdentifier
        await vm.receiveTerminalControl(lines: "isp:1234:select:\(source)\n")
        XCTAssertTrue(preferencesVM.terminalControl.isControlled(tty))
        XCTAssertEqual(switches, 0, "old terminal's command should only update its pane")
    }

    func testCommandFromPaneJustLeftOnlyChangesThatPanesState() async throws {
        let app = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_105)
        let oldTTY = "/dev/ttys101"
        let newTTY = "/dev/ttys102"
        let prefs = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(prefs, enabled: .ghostty, rules: [])
        defer { restore() }
        let lock = NSLock()
        var focusedTTY = oldTTY
        let vm = ApplicationVM(preferencesVM: prefs, environment: .init(
            frontmostApplication: { app }, focusedApplication: { nil },
            runningApplications: Just([app]).eraseToAnyPublisher(), isTerminalEnabled: { $0 == .ghostty },
            probedProgram: { _, _ in
                let tty = lock.withLock { focusedTTY }
                return TerminalReading(program: nil, pane: tty, tty: tty)
            },
            terminalPanelFocus: Self.standardTerminalWindow,
            ttyOwner: { ($0, oldTTY, 0) }, jobState: { _, _ in .foreground }
        ))
        try await Self.waitFor("old pane read") { prefs.focusedTerminalTTY(.ghostty) == oldTTY }
        let source = InputSource.getCurrentInputSource()
        // A focus-lost hook arrives before the UI reports the split change.
        lock.withLock { focusedTTY = newTTY }
        var liveSwitches = 0
        let switches = vm.terminalSwitches.sink { _ in liveSwitches += 1 }
        defer { switches.cancel() }
        await vm.receiveTerminalControl(lines: "isp:1234:select:\(source.persistentIdentifier)\n")
        XCTAssertEqual(prefs.terminalControl.current(on: oldTTY, in: .ghostty), source)
        XCTAssertEqual(prefs.focusedTerminalTTY(.ghostty), newTTY)
        XCTAssertNil(vm.appKind?.controlledShellTTY)
        XCTAssertEqual(liveSwitches, 0)
    }

    func testGhosttyFocusOutHookWaitsForItsFocusedPaneToSettleWithoutAX() async throws {
        let app = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_109)
        let departedTTY = "/dev/ttys105"
        let arrivingTTY = "/dev/ttys106"
        let prefs = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(prefs, enabled: .ghostty, rules: [])
        defer { restore() }
        let lock = NSLock()
        var probeCount = 0
        var arrivingPaneVisibleAt = TimeInterval.infinity
        let vm = ApplicationVM(preferencesVM: prefs, environment: .init(
            frontmostApplication: { app }, focusedApplication: { nil },
            runningApplications: Just([app]).eraseToAnyPublisher(), isTerminalEnabled: { $0 == .ghostty },
            probedProgram: { _, _ in
                let tty = lock.withLock {
                    probeCount += 1
                    return ProcessInfo.processInfo.systemUptime < arrivingPaneVisibleAt ? departedTTY : arrivingTTY
                }
                return TerminalReading(program: nil, pane: tty, tty: tty)
            },
            terminalPanelFocus: Self.standardTerminalWindow,
            ttyOwner: { ($0, departedTTY, 0) }, jobState: { _, _ in .foreground }
        ))
        try await Self.waitFor("both activation probes") { lock.withLock { probeCount >= 2 } }

        var controlledPanes: [String] = []
        let contexts = vm.$appKind.compactMap { $0?.controlledShellTTY }.sink { controlledPanes.append($0) }
        defer { contexts.cancel() }
        let source = InputSource.getCurrentInputSource()
        let lines = "isp:1234:select:\(source.persistentIdentifier)\n"
        // The writer already lost focus, but Ghostty still reports its pane.
        lock.withLock { arrivingPaneVisibleAt = ProcessInfo.processInfo.systemUptime + 0.020 }
        await vm.receiveTerminalControl(lines: lines)
        XCTAssertEqual(prefs.terminalControl.current(on: departedTTY, in: .ghostty), source)
        XCTAssertEqual(prefs.focusedTerminalTTY(.ghostty), arrivingTTY)
        XCTAssertTrue(controlledPanes.isEmpty, "The departed pane's command must never publish a live switch")
    }

    func testFirstPushTakesControlBeforePublishingNewProgramsRule() async throws {
        let app = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_106)
        let tty = "/dev/ttys103"
        let program = TerminalProgram(key: "nvim", pane: tty, tty: tty)
        let prefs = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(prefs, enabled: .ghostty, rules: ["nvim"])
        defer { restore() }
        let lock = NSLock()
        var foreground: TerminalProgram?
        var probes = 0
        let vm = ApplicationVM(preferencesVM: prefs, environment: .init(
            frontmostApplication: { app }, focusedApplication: { nil },
            runningApplications: Just([app]).eraseToAnyPublisher(), isTerminalEnabled: { $0 == .ghostty },
            probedProgram: { _, _ in
                lock.withLock {
                    probes += 1
                    return TerminalReading(program: foreground, pane: tty, tty: tty)
                }
            },
            terminalPanelFocus: Self.standardTerminalWindow,
            ttyOwner: { ($0, tty, 0) }, jobState: { _, _ in .foreground }
        ))
        try await Self.waitFor("shell's activation probes") { lock.withLock { probes >= 2 } }
        var ownersAtPublication: [pid_t?] = []
        let changes = vm.$appKind.sink {
            if $0?.getTerminalInfo()?.program == program { ownersAtPublication.append(prefs.terminalControl.activeWriter(on: tty)?.pid) }
        }
        defer { changes.cancel() }
        lock.withLock { foreground = program }
        let source = InputSource.getCurrentInputSource()
        await vm.receiveTerminalControl(lines: "isp:1234:push:\(source.persistentIdentifier)\n")
        XCTAssertEqual(ownersAtPublication, [1234])
        XCTAssertEqual(prefs.terminalControl.pop(on: tty, writer: .init(pid: 1234, startTime: 0)), source)
    }

    func testSwitchDuringVerificationReconcilesTheNewFrontTerminal() async throws {
        let ghostty = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_107)
        let iterm = FakeApp(bundleIdentifier: Terminal.iterm.rawValue, pid: 999_108)
        let tty = "/dev/ttys104"
        let program = TerminalProgram(key: "nvim", pane: tty, tty: tty)
        let prefs = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(prefs, enabled: .ghostty, rules: ["nvim"])
        defer { restore() }
        prefs.setTerminal(.iterm, enabled: true)
        let source = InputSource.getCurrentInputSource()
        prefs.terminalControl.select(source, on: tty, writer: .init(pid: 1234, startTime: 0))
        var front: NSRunningApplication = ghostty
        var switchOnVerification = false
        let vm = ApplicationVM(preferencesVM: prefs, environment: .init(
            frontmostApplication: {
                if switchOnVerification {
                    switchOnVerification = false
                    DispatchQueue.main.async {
                        front = iterm
                        NSWorkspace.shared.notificationCenter.post(
                            name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                            userInfo: [NSWorkspace.applicationUserInfoKey: iterm]
                        )
                    }
                }
                return front
            },
            focusedApplication: { nil }, runningApplications: Just([ghostty, iterm]).eraseToAnyPublisher(),
            isTerminalEnabled: { _ in true },
            probedProgram: { terminal, _ in
                terminal == .iterm ? TerminalReading(program: program, pane: tty, tty: tty)
                    : TerminalReading(program: nil, pane: "/dev/ttys105", tty: "/dev/ttys105")
            },
            terminalPanelFocus: Self.standardTerminalWindow,
            ttyOwner: { ($0, tty, 0) }, jobState: { _, _ in .foreground }
        ))
        var reappliedRule = false
        let changes = vm.$appKind.sink { kind in
            if kind?.getTerminalInfo()?.program == program && !prefs.terminalControl.isControlled(tty) {
                reappliedRule = true
            }
        }
        defer { changes.cancel() }
        switchOnVerification = true
        await vm.receiveTerminalControl(lines: "isp:1234:release\n")
        try await Self.waitFor("iTerm reapplied its rule after release") { reappliedRule }
    }

    func testTemporaryInputWindowHandbackRechecksCommandsFromItsBatchAndItsTimeInFront() async throws {
        let terminal = FakeApp(bundleIdentifier: Terminal.iterm.rawValue, pid: 999_111)
        let temporaryWindow = FakeApp(bundleIdentifier: "example.isp", pid: getpid())
        let tty = "/dev/ttys111"
        let writer = TerminalProcess.Identity(pid: 111, startTime: 0)
        let program = TerminalProgram(key: "nvim", pane: tty, tty: tty)
        let source = InputSource.getCurrentInputSource()
        var liveSource: InputSource = OtherInputSource(tisInputSource: source.tisInputSource)
        let prefs = try Self.inMemoryPreferencesVM()
        let restore = Self.setTerminalPreferences(prefs, enabled: .iterm, rules: ["nvim"])
        defer { restore() }
        prefs.terminalControl.select(source, on: tty, writer: writer)
        var front: NSRunningApplication = terminal
        var focused: NSRunningApplication = terminal
        var windowOpen = false
        var handbackWaits = 0
        var laggingFocusReads = 0
        var writerAlive = true
        let restored = PassthroughSubject<Void, Never>()
        let lock = NSLock()
        var probes = 0
        var pane = tty
        var pauseNextProbe: (() -> Void)?
        let vm = ApplicationVM(preferencesVM: prefs, environment: .init(
            frontmostApplication: { front }, focusedApplication: {
                if front == terminal && focused == temporaryWindow { laggingFocusReads += 1 }
                return focused
            },
            runningApplications: Just([terminal]).eraseToAnyPublisher(), isTerminalEnabled: { $0 == .iterm },
            probedProgram: { _, _ in
                let (reading, pause) = lock.withLock {
                    probes += 1
                    defer { pauseNextProbe = nil }
                    return (TerminalReading(program: pane == tty ? program : nil, pane: pane, tty: pane), pauseNextProbe)
                }
                pause?()
                return reading
            },
            terminalPanelFocus: Self.standardTerminalWindow,
            ttyOwner: { writerAlive ? ($0, tty, 0) : nil }, jobState: { _, _ in .foreground },
            temporaryInputWindowInProgress: { windowOpen },
            temporaryInputWindowRestored: restored.handleEvents(receiveSubscription: { _ in handbackWaits += 1 }).eraseToAnyPublisher(),
            inputSourceForReconciliation: { liveSource }
        ))
        try await Self.waitFor("both activation probes") { lock.withLock { probes >= 2 } }
        let delivered = expectation(description: "settled probe delivered")
        TerminalProcess.queue.async { DispatchQueue.main.async { delivered.fulfill() } }
        await fulfillment(of: [delivered], timeout: 5)

        var publishedProgramSources = 0
        let contexts = vm.$appKind.dropFirst().sink { app in
            if app?.getTerminalInfo()?.program == program { publishedProgramSources += 1 }
        }
        // A CJKV selection brings up ISP's temporary window during the first command.
        func openWindow() {
            windowOpen = true
            front = temporaryWindow
            focused = temporaryWindow
        }
        func handBackWindow() {
            windowOpen = false
            front = terminal
            restored.send()
        }
        var switchCount = 0
        let switches = vm.terminalSwitches.sink { selected in
            switchCount += 1
            liveSource = selected
            openWindow()
        }
        defer { contexts.cancel(); switches.cancel() }
        let initialWaits = handbackWaits
        let selectLine = "isp:111:select:\(source.persistentIdentifier)\n"
        let batch = Task { await vm.receiveTerminalControl(lines: selectLine + selectLine + "isp:111:release\n") }
        try await Self.waitFor("the release waits for the first command's window") { handbackWaits > initialWaits }
        XCTAssertTrue(prefs.terminalControl.isControlled(tty))
        handBackWindow()
        try await Self.waitFor("NSWorkspace has handed back before AX") { laggingFocusReads > 0 }
        focused = terminal
        await batch.value
        XCTAssertEqual(switchCount, 1, "Selecting the same source on focus return must not open another window")
        XCTAssertFalse(prefs.terminalControl.isControlled(tty))
        XCTAssertEqual(publishedProgramSources, 1, "The unchanged editor reapplies its terminal rule")

        // A first push arriving during another handback remembers the live source.
        openWindow()
        let beforePush = handbackWaits
        let push = Task { await vm.receiveTerminalControl(lines: "isp:111:push:\(source.persistentIdentifier)\n") }
        try await Self.waitFor("the first push waits") { handbackWaits > beforePush }
        XCTAssertFalse(prefs.terminalControl.isControlled(tty))
        focused = terminal
        handBackWindow()
        await push.value
        XCTAssertEqual(prefs.terminalControl.pop(on: tty, writer: writer), source)

        // A writer can also exit while the temporary window is in front, with
        // no further command to prompt a fresh probe after handback.
        openWindow()
        writerAlive = false
        let beforeExit = publishedProgramSources
        try await Self.waitFor("the writer exits while the temporary window has focus") {
            !prefs.terminalControl.isControlled(tty)
        }
        let beforeExitHandback = laggingFocusReads
        handBackWindow()
        try await Self.waitFor("AX still reports ISP after the writer exits") { laggingFocusReads > beforeExitHandback }
        focused = terminal
        try await Self.waitFor("the writer's exit reapplies its program rule") { publishedProgramSources == beforeExit + 1 }
        writerAlive = true
        let beforeAnotherPane = publishedProgramSources

        // An independent command while the window is frontmost stays with its
        // pane if the terminal hands focus back to a different one.
        openWindow()
        let beforeSelect = handbackWaits
        let select = Task { await vm.receiveTerminalControl(lines: "isp:111:select:\(source.persistentIdentifier)\n") }
        try await Self.waitFor("the select waits") { handbackWaits > beforeSelect }
        let otherTTY = "/dev/ttys112"
        lock.withLock { pane = otherTTY }
        focused = terminal
        handBackWindow()
        await select.value
        XCTAssertTrue(prefs.terminalControl.isControlled(tty))
        XCTAssertEqual(prefs.focusedTerminalTTY(.iterm), otherTTY)
        XCTAssertEqual(publishedProgramSources, beforeAnotherPane)
        XCTAssertNil(vm.appKind?.getTerminalInfo())

        // A focus-gained hook can arrive after the restoration notification.
        // Its first push still needs the actual source once AX catches up.
        prefs.terminalControl.release(tty, writer: writer)
        openWindow()
        lock.withLock { pane = tty }
        handBackWindow()
        let beforeLatePush = laggingFocusReads
        let latePush = Task { await vm.receiveTerminalControl(lines: "isp:111:push:\(source.persistentIdentifier)\n") }
        try await Self.waitFor("the focus-gained hook checks AX") { laggingFocusReads > beforeLatePush }
        focused = terminal
        await latePush.value
        XCTAssertEqual(prefs.terminalControl.pop(on: tty, writer: writer), source)

        // A lookup can span the entire temporary window's lifetime. Its old
        // pane must not decide whether the returning pane's first push is live.
        prefs.terminalControl.release(tty, writer: writer)
        let probeStarted = expectation(description: "command lookup read the old pane")
        let resumeProbe = DispatchSemaphore(value: 0)
        lock.withLock {
            pane = otherTTY
            pauseNextProbe = {
                probeStarted.fulfill()
                _ = resumeProbe.wait(timeout: .now() + 5)
            }
        }
        let overlappingPush = Task { await vm.receiveTerminalControl(lines: "isp:111:push:\(source.persistentIdentifier)\n") }
        await fulfillment(of: [probeStarted], timeout: 5)
        openWindow()
        lock.withLock { pane = tty }
        handBackWindow()
        focused = terminal
        resumeProbe.signal()
        await overlappingPush.value
        XCTAssertEqual(prefs.focusedTerminalTTY(.iterm), tty)
        XCTAssertEqual(prefs.terminalControl.pop(on: tty, writer: writer), source)
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

    private static var standardTerminalWindow: TerminalPanelFocus.Environment {
        .init(
            read: { _, _ in AnyCancellable {} },
            controlAttributes: { _ in .init(isFrontmost: true, focusedWindowSubrole: "AXStandardWindow") }
        )
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

    final class OtherInputSource: InputSource {
        override var persistentIdentifier: String { "test.other-input-source" }
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
