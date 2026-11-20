import Combine
import XCTest
@testable import Input_Source_Pro

@MainActor
final class TerminalPanelFocusTests: XCTestCase {
    private static let ghostty: pid_t = 200
    private static let panel = TerminalPanelFocus.Attributes(isFrontmost: true, focusedWindowSubrole: "AXFloatingWindow")
    private static let window = TerminalPanelFocus.Attributes(isFrontmost: false, focusedWindowSubrole: "AXStandardWindow")
    private static let frontWindow = TerminalPanelFocus.Attributes(isFrontmost: true, focusedWindowSubrole: "AXStandardWindow")

    /// A tracker on a fake frontmost app and fake AX reads, answered by hand.
    @MainActor
    private final class Harness {
        /// What the next reads answer; nil is AX failing (no permission).
        var attributes: TerminalPanelFocus.Attributes?
        /// Reads not answered yet; a cancelled one is dropped unanswered.
        var pendingReads: [(pid: pid_t, flag: CancelFlag, answer: (TerminalPanelFocus.Attributes?) -> Void)] = []
        var reads = 0
        var changes: [pid_t?] = []

        lazy var focus = TerminalPanelFocus(
            environment: TerminalPanelFocus.Environment(
                read: { [unowned self] pid, answer in
                    reads += 1
                    let flag = CancelFlag()
                    pendingReads.append((pid, flag, answer))
                    return AnyCancellable(flag)
                }
            ),
            changed: { [unowned self] in changes.append($0) }
        )

        init() {
            focus.watch([TerminalPanelFocusTests.ghostty])
        }

        /// A notification from Ghostty, its read answered at once.
        func notify() {
            focus.evaluate(TerminalPanelFocusTests.ghostty)
            answerReads()
        }

        func answerReads() {
            let reads = pendingReads
            pendingReads = []
            reads.filter { !$0.flag.isCancelled }.forEach { $0.answer(attributes) }
        }
    }

    func testAFocusedPanelStandsInAndItsCollapseHandsBack() {
        let harness = Harness()
        harness.attributes = Self.panel
        harness.notify()
        XCTAssertEqual(harness.changes, [Self.ghostty])
        XCTAssertEqual(harness.focus.focusedPID, Self.ghostty)

        harness.attributes = Self.window
        harness.notify()
        XCTAssertEqual(harness.changes, [Self.ghostty, nil])
        XCTAssertNil(harness.focus.focusedPID)
    }

    func testRepeatedNotificationsActOnlyOnAChange() {
        let harness = Harness()
        harness.attributes = Self.window
        harness.notify()
        harness.notify()
        XCTAssertEqual(harness.changes, [])

        harness.attributes = Self.panel
        harness.notify()
        harness.notify()
        harness.notify()
        XCTAssertEqual(harness.changes, [Self.ghostty])
        XCTAssertEqual(harness.reads, 5)
    }

    /// The quick terminal over Ghostty's own window: the app stays in front,
    /// but the panel is another pane.
    func testAPanelOverItsOwnTerminalCountsUntilAWindowTakesFocusBack() {
        let harness = Harness()
        harness.attributes = Self.frontWindow
        harness.notify()
        XCTAssertEqual(harness.changes, [])

        harness.attributes = Self.panel
        harness.notify()
        harness.attributes = Self.frontWindow
        harness.notify()
        XCTAssertEqual(harness.changes, [Self.ghostty, nil])
        XCTAssertEqual(harness.reads, 3)
    }

    func testUnreadableAttributesCountAsNoPanel() {
        let harness = Harness()
        harness.attributes = nil
        harness.notify()
        XCTAssertEqual(harness.changes, [])

        harness.attributes = Self.panel
        harness.notify()
        // One read the terminal was too busy to answer keeps the panel.
        harness.attributes = nil
        harness.notify()
        XCTAssertEqual(harness.changes, [Self.ghostty])
        harness.attributes = Self.panel
        harness.notify()
        // Permission revoked while the panel has focus: the recheck's next read fails too.
        harness.attributes = nil
        harness.notify()
        harness.notify()
        XCTAssertEqual(harness.changes, [Self.ghostty, nil])
    }

    func testATerminalNoLongerWatchedLosesItsPanelAndLateReads() {
        let harness = Harness()
        harness.attributes = Self.panel
        harness.notify()

        harness.focus.evaluate(Self.ghostty)
        harness.focus.watch([])
        harness.answerReads()
        harness.focus.evaluate(Self.ghostty)
        XCTAssertEqual(harness.changes, [Self.ghostty, nil])
        XCTAssertEqual(harness.reads, 2)
    }

    func testABurstWhileAReadIsInFlightBecomesOneMoreRead() {
        let harness = Harness()
        harness.attributes = Self.window
        for _ in 0 ..< 5 { harness.focus.evaluate(Self.ghostty) }
        XCTAssertEqual(harness.reads, 1, "A slow terminal: one read in flight")

        // The slow read answers what it saw before the panel showed; the one after it sees the panel.
        harness.answerReads()
        XCTAssertEqual(harness.reads, 2, "The burst becomes one more read")
        XCTAssertEqual(harness.changes, [])

        harness.attributes = Self.panel
        harness.answerReads()
        XCTAssertEqual(harness.changes, [Self.ghostty])
        XCTAssertEqual(harness.reads, 2, "Nothing asked meanwhile: no more reads")
    }

    func testLeavingTheWatchCancelsTheReadInFlightAndItsReread() {
        let harness = Harness()
        harness.attributes = Self.panel
        harness.focus.evaluate(Self.ghostty)
        harness.focus.evaluate(Self.ghostty)

        harness.focus.watch([])
        XCTAssertTrue(harness.pendingReads.allSatisfy(\.flag.isCancelled))
        harness.answerReads()
        XCTAssertEqual(harness.reads, 1, "No reread for a terminal that left")
        XCTAssertEqual(harness.changes, [])

        // Watched again: a fresh read, not one left over.
        harness.focus.watch([Self.ghostty])
        harness.notify()
        XCTAssertEqual(harness.reads, 2)
        XCTAssertEqual(harness.changes, [Self.ghostty])
    }

    /// The quick terminal end to end through `ApplicationVM`, with only the
    /// system faked: running and frontmost apps, the panel's AX attributes and
    /// Ghostty's probe. The panel takes focus while TextEdit stays frontmost,
    /// so Ghostty's rules apply to the program on the panel's tty; once it
    /// collapses, TextEdit's apply again.
    func testAPanelHandsTheRulesToItsTerminalUntilItCollapses() throws {
        let textEdit = ApplicationVMTerminalTests.FakeApp(bundleIdentifier: "com.apple.TextEdit", pid: 999_001)
        let ghostty = ApplicationVMTerminalTests.FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_002)
        let tty = "/dev/ttys009"
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var attributes = TerminalPanelFocusTests.panel
            var probes = 0
        }
        let state = State()

        let environment = ApplicationVM.Environment(
            frontmostApplication: { textEdit },
            focusedApplication: { nil },
            runningApplications: Just([textEdit, ghostty]).eraseToAnyPublisher(),
            isTerminalEnabled: { $0 == .ghostty },
            probedProgram: { _, _ in
                state.lock.withLock { state.probes += 1 }
                return TerminalReading(program: TerminalProgram(key: "claude", pane: tty), pane: tty)
            },
            terminalPanelFocus: TerminalPanelFocus.Environment(
                read: { _, answer in
                    let flag = CancelFlag()
                    DispatchQueue.main.async { if !flag.isCancelled { answer(state.lock.withLock { state.attributes }) } }
                    return AnyCancellable(flag)
                },
                controlAttributes: { _ in state.lock.withLock { state.attributes } }
            )
        )
        let preferencesVM = try ApplicationVMTerminalTests.inMemoryPreferencesVM()
        let restore = ApplicationVMTerminalTests.setTerminalPreferences(preferencesVM, enabled: .ghostty, rules: ["claude", "vim"])
        defer { restore() }
        // Last read in Ghostty's window, not its panel.
        preferencesVM.terminalPrograms[.ghostty] = TerminalProgram(key: "vim", pane: "/dev/ttys001")
        let applicationVM = ApplicationVM(preferencesVM: preferencesVM, environment: environment)
        let ruledApp = { applicationVM.appKind?.getApp() }
        var programs: [String] = []
        let recording = applicationVM.$appKind.sink { programs += $0?.getTerminalInfo().map { [$0.program.key] } ?? [] }
        defer { recording.cancel() }

        ApplicationVMTerminalTests.waitUntil("Ghostty's panel stands in and its tty is probed") {
            ruledApp() === ghostty && preferencesVM.terminalPrograms[.ghostty]?.pane == tty
        }
        XCTAssertTrue(preferencesVM.terminalPanel === ghostty)
        XCTAssertGreaterThan(state.lock.withLock { state.probes }, 0)
        XCTAssertEqual(programs, ["claude"], "The window's program never stands in for the panel's")

        // Collapsed without a notification: the recheck while it had focus notices.
        state.lock.withLock { state.attributes = Self.window }
        ApplicationVMTerminalTests.waitUntil("TextEdit's rules apply again") { ruledApp() === textEdit }
        XCTAssertNil(preferencesVM.terminalPanel)
        XCTAssertNil(preferencesVM.terminalPrograms[.ghostty], "The panel's program is not the window's")
    }

    /// The quick terminal over Ghostty in front: the probe asks for the
    /// panel's pane while it has focus, and for the window's once it hides.
    func testAPanelOverItsOwnTerminalIsProbedAsThePanel() throws {
        let ghostty = ApplicationVMTerminalTests.FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_004)
        let (panelTTY, windowTTY) = ("/dev/ttys009", "/dev/ttys001")
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var attributes = TerminalPanelFocusTests.panel
        }
        let state = State()

        let environment = ApplicationVM.Environment(
            frontmostApplication: { ghostty },
            focusedApplication: { nil },
            runningApplications: Just([ghostty]).eraseToAnyPublisher(),
            isTerminalEnabled: { $0 == .ghostty },
            probedProgram: { terminal, _ in
                // Runs on the probe queue, which knows whether the panel has focus.
                terminal.isPanelFocused
                    ? TerminalReading(program: TerminalProgram(key: "zsh-tool", pane: panelTTY), pane: panelTTY)
                    : TerminalReading(program: TerminalProgram(key: "claude", pane: windowTTY), pane: windowTTY)
            },
            terminalPanelFocus: TerminalPanelFocus.Environment(
                read: { _, answer in
                    let flag = CancelFlag()
                    DispatchQueue.main.async { if !flag.isCancelled { answer(state.lock.withLock { state.attributes }) } }
                    return AnyCancellable(flag)
                },
                controlAttributes: { _ in state.lock.withLock { state.attributes } }
            )
        )
        let preferencesVM = try ApplicationVMTerminalTests.inMemoryPreferencesVM()
        let restore = ApplicationVMTerminalTests.setTerminalPreferences(preferencesVM, enabled: .ghostty, rules: ["claude", "zsh-tool"])
        defer { restore() }
        let applicationVM = ApplicationVM(preferencesVM: preferencesVM, environment: environment)
        let program = { applicationVM.appKind?.getTerminalInfo()?.program.key }

        ApplicationVMTerminalTests.waitUntil("the panel's pane is probed") {
            preferencesVM.terminalPanel === ghostty && program() == "zsh-tool"
        }

        // Hidden without a notification: the recheck while it had focus notices.
        state.lock.withLock { state.attributes = Self.frontWindow }
        ApplicationVMTerminalTests.waitUntil("the window's pane is probed again") {
            preferencesVM.terminalPanel == nil && program() == "claude"
        }
        XCTAssertTrue(applicationVM.appKind?.getApp() === ghostty)
    }

    func testHiddenPanelCommandsCannotSwitchTheAppOrWindowUnderneath() async throws {
        for overGhostty in [false, true] {
            try await checkHiddenPanel(overGhostty: overGhostty, writerExits: false)
        }
    }

    func testWriterExitRechecksThePanelBeforeApplyingItsRule() async throws {
        try await checkHiddenPanel(overGhostty: false, writerExits: true)
    }

    func testUnansweredPanelReadCannotAuthorizeTheGhosttyWindowBehindIt() async throws {
        let ghostty = ApplicationVMTerminalTests.FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_203)
        let tty = "/dev/ttys203"
        let writer = TerminalProcess.Identity(pid: 203, startTime: 0)
        let source = InputSource.getCurrentInputSource()
        let prefs = try ApplicationVMTerminalTests.inMemoryPreferencesVM()
        let restore = ApplicationVMTerminalTests.setTerminalPreferences(prefs, enabled: .ghostty, rules: ["vim"])
        defer { restore() }
        let lock = NSLock()
        var attributes: TerminalPanelFocus.Attributes?
        var onlyWindowSurfaces = false
        let vm = ApplicationVM(preferencesVM: prefs, environment: .init(
            frontmostApplication: { ghostty }, focusedApplication: { ghostty },
            runningApplications: Just([ghostty]).eraseToAnyPublisher(), isTerminalEnabled: prefs.isTerminalEnabled,
            probedProgram: { _, _ in
                TerminalReading(program: TerminalProgram(key: "vim", pane: tty, tty: tty), pane: tty, tty: tty)
            },
            terminalPanelFocus: .init(
                read: { _, _ in AnyCancellable {} },
                controlAttributes: { _ in lock.withLock { attributes } },
                ghosttyHasOnlyWindowSurfaces: { _ in lock.withLock { onlyWindowSurfaces } }
            ),
            ttyOwner: { ($0, tty, 0) }, jobState: { _, _ in .foreground }
        ))
        try await ApplicationVMTerminalTests.waitFor("ordinary rules read the window") {
            vm.appKind?.getTerminalInfo()?.program.tty == tty
        }
        // The quick terminal opens over this window without a notification.
        // Apple Events still return the window, and AX cannot confirm it.
        await vm.receiveTerminalControl(lines: "isp:203:push:\(source.persistentIdentifier)\n")
        XCTAssertTrue(prefs.terminalControl.isControlled(tty, in: .ghostty))
        XCTAssertNil(prefs.terminalControl.pop(on: tty, writer: writer), "The hidden window must not capture the live source")

        lock.withLock { attributes = .init(isFrontmost: true, focusedWindowSubrole: nil) }
        let ambiguous = await vm.verifiedTerminalReading(for: ghostty)
        XCTAssertNil(ambiguous)
        lock.withLock { onlyWindowSurfaces = true }
        let verified = await vm.verifiedTerminalReading(for: ghostty)
        XCTAssertEqual(verified?.tty, tty, "With only regular window surfaces the Apple Event identifies the pane")
    }

    private func checkHiddenPanel(overGhostty: Bool, writerExits: Bool) async throws {
        let ghostty = ApplicationVMTerminalTests.FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_201)
        let other = ApplicationVMTerminalTests.FakeApp(bundleIdentifier: "com.apple.TextEdit", pid: 999_202)
        let front = overGhostty ? ghostty : other
        let panelTTY = "/dev/ttys201"
        let windowTTY = "/dev/ttys202"
        let writer = TerminalProcess.Identity(pid: 201, startTime: 0)
        let source = InputSource.getCurrentInputSource()
        let prefs = try ApplicationVMTerminalTests.inMemoryPreferencesVM()
        let restore = ApplicationVMTerminalTests.setTerminalPreferences(prefs, enabled: .ghostty, rules: ["vim"])
        defer { restore() }
        if writerExits { prefs.terminalControl.select(source, on: panelTTY, writer: writer) }

        let lock = NSLock()
        var attributes = Self.panel
        var reportedPanel = false
        var alive = true
        let vm = ApplicationVM(preferencesVM: prefs, environment: .init(
            frontmostApplication: { front }, focusedApplication: { nil },
            runningApplications: Just([ghostty, other]).eraseToAnyPublisher(), isTerminalEnabled: prefs.isTerminalEnabled,
            probedProgram: { terminal, _ in
                let tty = terminal.isPanelFocused ? panelTTY : windowTTY
                let program = TerminalProgram(key: "vim", pane: tty, tty: tty)
                return TerminalReading(program: program, pane: tty, tty: tty)
            },
            terminalPanelFocus: .init(
                read: { _, answer in
                    // Report the panel opening. Its dismissal produces no notification.
                    guard !reportedPanel else { return AnyCancellable {} }
                    reportedPanel = true
                    DispatchQueue.main.async { answer(Self.panel) }
                    return AnyCancellable {}
                },
                controlAttributes: { _ in lock.withLock { attributes } }
            ),
            ttyOwner: { alive ? ($0, panelTTY, 0) : nil }, jobState: { _, _ in .foreground }
        ))
        try await ApplicationVMTerminalTests.waitFor("quick terminal is active") {
            prefs.terminalPanel == ghostty && vm.appKind?.getTerminalInfo()?.program.tty == panelTTY
        }
        var hiddenPanePublications = 0
        var switches = 0
        let contexts = vm.$appKind.dropFirst().sink {
            if $0?.getTerminalInfo()?.program.tty == panelTTY { hiddenPanePublications += 1 }
        }
        let changes = vm.terminalSwitches.sink { _ in switches += 1 }
        defer { contexts.cancel(); changes.cancel() }
        lock.withLock { attributes = overGhostty ? Self.frontWindow : Self.window }
        if writerExits {
            alive = false
        } else {
            await vm.receiveTerminalControl(lines: "isp:201:push:\(source.persistentIdentifier)\n")
            XCTAssertTrue(prefs.terminalControl.isControlled(panelTTY))
            XCTAssertNil(prefs.terminalControl.pop(on: panelTTY, writer: writer), "The hidden pane cannot remember the actual front app's source")
        }
        try await ApplicationVMTerminalTests.waitFor("focus is handed back to the window underneath") {
            prefs.terminalPanel == nil && (overGhostty ? vm.appKind?.getTerminalInfo()?.program.tty == windowTTY : vm.appKind?.getApp() == other)
        }
        XCTAssertEqual(hiddenPanePublications, 0)
        XCTAssertEqual(switches, 0)
    }

    func testRulesFollowISPThenAPanelThenTheFocusedApp() {
        XCTAssertEqual(ApplicationVM.ruledApp(front: "isp", isOwn: true, panel: "ghostty") { "x" }, "isp")
        XCTAssertEqual(ApplicationVM.ruledApp(front: "textedit", isOwn: false, panel: "ghostty") { "x" }, "ghostty")
        XCTAssertEqual(ApplicationVM.ruledApp(front: "textedit", isOwn: false, panel: nil) { "focused" }, "focused")
    }

    func testOnlyAFloatingWindowOfTheFrontmostAppIsAPanel() {
        typealias Attributes = TerminalPanelFocus.Attributes
        XCTAssertEqual(Self.panel.focus, .panel)
        XCTAssertEqual(Attributes(isFrontmost: false, focusedWindowSubrole: "AXFloatingWindow").focus, .background)
        XCTAssertEqual(Attributes(isFrontmost: true, focusedWindowSubrole: "AXStandardWindow").focus, .window)
        XCTAssertNil(Attributes(isFrontmost: true, focusedWindowSubrole: nil).focus)
        XCTAssertNil(Attributes(isFrontmost: true, focusedWindowSubrole: "AXUnknown").focus)
    }

    func testIndicatorOverAPanelFollowsItsCaretUntilHidden() {
        let changes = PassthroughSubject<Void, Never>()
        let hidden = PassthroughSubject<Void, Never>()
        var caret: CGPoint?
        var points: [CGPoint] = []
        let subscription = IndicatorWindowController.panelCaretPublisher(
            changes: changes.eraseToAnyPublisher(),
            point: { caret },
            until: hidden.eraseToAnyPublisher()
        )
        .sink { points.append($0) }
        defer { subscription.cancel() }

        changes.send(()) // no sample yet
        for y: CGFloat in [983, 950, 950, 869] {
            caret = CGPoint(x: 30.5, y: y)
            changes.send(())
        }
        hidden.send(())
        caret = CGPoint(x: 30.5, y: 500)
        changes.send(())
        XCTAssertEqual(points.map(\.y), [983, 950, 869])
    }

    func testAnAppThatIsGoneReadsAsNothing() {
        XCTAssertNil(TerminalPanelFocus.attributes(of: -1))
    }
}
