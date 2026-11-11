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
        }
        let state = State()
        let environment = ApplicationVM.Environment(
            frontmostApplication: { ghostty },
            focusedApplication: { nil },
            isTerminalEnabled: { terminal in state.lock.withLock { terminal == .ghostty && state.isEnabled } },
            probedProgram: { _ in state.lock.withLock { state.reading } }
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
            for isEnabled in [false, true] {
                state.lock.withLock {
                    state.reading = TerminalReading(program: program, pane: pane)
                    state.isEnabled = isEnabled
                }
                preferencesVM.runtimeRuleChangeNotifier.notify()
            }
            waitUntil("\(key ?? "shell") in \(pane ?? "no pane") is read") {
                preferencesVM.terminalPrograms[.ghostty] == program
            }
        }

        waitUntil("the first probe reads pane A") { preferencesVM.terminalPrograms[.ghostty]?.pane == "A" }
        XCTAssertEqual(shows, 1)

        read("vim", pane: "A")
        XCTAssertEqual(shows, 1, "Another program in the same pane is not a new pane")

        read("vim", pane: "B")
        XCTAssertEqual(shows, 2)

        read(nil, pane: nil)
        read("vim", pane: "B")
        XCTAssertEqual(shows, 2, "A read without a pane neither shows nor forgets the pane")
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out: \(what)", file: file, line: line) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private static func inMemoryPreferencesVM() throws -> PreferencesVM {
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
    private final class FakeApp: NSRunningApplication, @unchecked Sendable {
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
