import AppKit
import Carbon
import Combine
import CoreGraphics

@MainActor
enum InputSourceSwitcher {
    struct PrivateSelectionQueue<Source: Equatable> {
        private var active: (id: UUID, target: Source, baseline: Source, observed: Source, isCurrent: Bool)?
        private var pending: (target: Source, previous: Source, select: () -> Void)?

        var isBusy: Bool { active != nil }

        mutating func begin(target: Source, current: Source) -> UUID {
            precondition(!isBusy)
            let id = UUID()
            active = (id, target, current, current, true)
            return id
        }

        mutating func enqueue(target: Source, current: Source, select: @escaping () -> Void) {
            precondition(isBusy)
            pending = (target, current, select)
            active?.observed = current
        }

        mutating func discardPending(current: Source? = nil) {
            if let current { _ = isUnexpectedSource(current) }
            pending = nil
            active?.isCurrent = false
        }

        mutating func finish(_ id: UUID, current: Source, fallback: (() -> Void)? = nil) -> (() -> Void)? {
            guard active?.id == id else { return nil }
            defer {
                active = nil
                pending = nil
            }
            // Notifications may lag behind the reply. A newer actual source
            // supersedes both the queued selection and the original fallback.
            guard !isUnexpectedSource(current) else { return nil }
            if let pending { return pending.select }
            return active?.isCurrent == true ? fallback : nil
        }

        mutating func isUnexpectedSource(_ actual: Source) -> Bool {
            guard let active else { return false }
            self.active?.observed = actual
            // The in-flight request can only produce its target. A different
            // transition, including back to the original source, is newer intent.
            let unexpected = actual != active.observed && actual != active.target
            if unexpected || (active.isCurrent && actual == active.target) {
                self.active?.baseline = actual
            }
            return unexpected
        }

        func sourceForReconciliation(_ actual: Source) -> Source {
            guard let active else { return actual }
            if let pending {
                // These sources can be observed before the newest request runs.
                // Neither the previous source nor a superseded activation is a
                // new user choice to remember for the current app or website.
                if actual == active.target || actual == active.baseline || actual == pending.previous {
                    return pending.target
                }
            } else if active.isCurrent, actual == active.baseline {
                return active.target
            } else if !active.isCurrent, actual == active.target {
                return active.baseline
            }
            return actual
        }
    }

    struct TemporarySelection<Source: Equatable> {
        private var pending: (id: UUID, target: Source, temporary: Source)?

        mutating func begin(target: Source, temporary: Source) -> UUID {
            let id = UUID()
            pending = (id, target, temporary)
            return id
        }

        mutating func finish(_ id: UUID) {
            guard pending?.id == id else { return }
            pending = nil
        }

        mutating func cancel() {
            pending = nil
        }

        func sourceForReconciliation(_ actual: Source) -> Source {
            guard let pending, actual == pending.temporary else { return actual }
            return pending.target
        }
    }

    /// Waits for focus to leave this app after the temporary input window hands it back.
    struct ApplicationRestoration {
        private(set) var remainingChecks: Int

        init(checks: Int) {
            remainingChecks = checks
        }

        /// Returns true once waiting should stop: any app but this one is frontmost, or the checks ran out.
        /// Not only the previous app: the user may have switched to another one, or the previous app quit.
        mutating func isFinished(frontPID: pid_t?, selfPID: pid_t) -> Bool {
            if let frontPID, frontPID != selfPID { return true }
            remainingChecks -= 1
            return remainingChecks <= 0
        }
    }

    struct Descriptor: CustomStringConvertible {
        let localizedName: String
        let inputSourceID: String
        let inputModeID: String?
        let isEnabled: Bool
        let isSelectable: Bool

        var description: String {
            let mode = inputModeID ?? "nil"
            return "\(localizedName) | sourceID=\(inputSourceID) | modeID=\(mode) | enabled=\(isEnabled) | selectable=\(isSelectable)"
        }
    }

    private struct SwitchTarget {
        let localizedName: String
        let sourceID: String
        let inputModeID: String?
        let isCJKV: Bool

        @MainActor
        func matches(_ inputSource: InputSource) -> Bool {
            if let inputModeID {
                return inputSource.inputModeID == inputModeID
            }

            return inputSource.id == sourceID
        }
    }

    private static let logger = ISPLogger(category: String(describing: InputSourceSwitcher.self))
    private static var temporarySelection = TemporarySelection<InputSource>()
    private static var pendingWorkItems: [DispatchWorkItem] = []
    private static var pendingPrivateSelection: PrivateInputSourceSelector.Request?
    private static var privateSelectionQueue = PrivateSelectionQueue<InputSource>()
    private static var privateSelectionActivationObserver: NSObjectProtocol?
    private static var temporaryInputWindow: NSWindow?
    private static var temporaryInputWindowPreviousApplication: NSRunningApplication?
    private static let temporaryInputWindowDuration: TimeInterval = 0.08
    // App activation notifications can arrive after the hidden window has already closed.
    private static let temporaryInputWindowActivationSuppressionDuration: TimeInterval = 0.5
    private static var temporaryInputWindowActivationSuppressionEndTime: TimeInterval = 0
    private static let syntheticEventUserData: Int64 = 0x49535043534A4B56 // "ISPCSJKV"
    private static var restoration: ApplicationRestoration?
    private static var restorationTimer: AnyCancellable?
    private static let restorationCheckInterval: TimeInterval = 0.01
    private static let restorationCheckLimit = 50

    private(set) static var isShowingTemporaryInputWindow = false

    private static let restored = PassthroughSubject<Void, Never>()

    /// Sends once the temporary input window has closed and focus has left this app,
    /// or once waiting for that has given up.
    static var temporaryInputWindowRestored: AnyPublisher<Void, Never> { restored.eraseToAnyPublisher() }

    /// True from the moment a temporary input window is requested until `temporaryInputWindowRestored` sends.
    static var isTemporaryInputWindowInProgress: Bool {
        isShowingTemporaryInputWindow || restoration != nil
    }

    /// The app the temporary input window took focus from, until `temporaryInputWindowRestored` sends.
    static var temporaryInputWindowPreviousPID: pid_t? {
        temporaryInputWindowPreviousApplication?.processIdentifier
    }

    static var isHandlingTemporaryInputWindowActivation: Bool {
        isShowingTemporaryInputWindow ||
            ProcessInfo.processInfo.systemUptime < temporaryInputWindowActivationSuppressionEndTime
    }

    static func isTemporaryInputWindowApplicationActivation(_ application: NSRunningApplication) -> Bool {
        guard isHandlingTemporaryInputWindowActivation else { return false }
        return isSelf(application)
    }

    private static func isSelf(_ application: NSRunningApplication?) -> Bool {
        application?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// End time for the synthetic event suppression window.
    /// ShortcutTriggerManager checks this to ignore flagsChanged events generated
    /// by synthetic keyboard events during CJKV input source fix.
    static var syntheticEventEndTime: TimeInterval = 0

    static var isSuppressingSyntheticEvents: Bool {
        ProcessInfo.processInfo.systemUptime < syntheticEventEndTime
    }

    static func isSyntheticEvent(_ event: CGEvent?) -> Bool {
        guard let event else { return false }

        if event.getIntegerValueField(.eventSourceUserData) == syntheticEventUserData {
            return true
        }

        let eventPID = event.getIntegerValueField(.eventSourceUnixProcessID)
        return isSuppressingSyntheticEvents && eventPID == Int64(ProcessInfo.processInfo.processIdentifier)
    }

    static func discoverInputSources() -> [Descriptor] {
        return inputSourceList().map { source in
            Descriptor(
                localizedName: source.name,
                inputSourceID: source.id,
                inputModeID: source.inputModeID,
                isEnabled: source.isEnabled,
                isSelectable: source.isSelectable
            )
        }
    }

    static func logAvailableInputSources() {
        let sources = discoverInputSources()
        let description = sources.map(\.description).joined(separator: "\n")
        logger.debug { "Discovered input sources (\(sources.count)):\n\(description)" }
    }

    static func inputSourceForReconciliation() -> InputSource {
        if let request = pendingPrivateSelection,
           request.deadline <= ProcessInfo.processInfo.systemUptime || PrivateInputSourceSelector.keyFocusPID() != request.pid {
            cancelPrivateSelection()
        }
        let actual = InputSource.getCurrentInputSource()
        if privateSelectionQueue.isUnexpectedSource(actual) {
            // Preserve a newer external choice after an already-sent activation finishes.
            cancelPrivateSelection()
            if let pid = PrivateInputSourceSelector.keyFocusPID() {
                privateSelectionQueue.enqueue(target: actual, current: actual) {
                    guard PrivateInputSourceSelector.keyFocusPID() == pid else { return }
                    selectInputSource(actual.tisInputSource, reason: "newer external selection")
                }
            }
        }
        return temporarySelection.sourceForReconciliation(privateSelectionQueue.sourceForReconciliation(actual))
    }

    static func prepareForContextChange() -> Bool {
        guard privateSelectionQueue.isBusy else { return false }
        cancelPrivateSelection(current: InputSource.getCurrentInputSource())
        return true
    }

    static func switchToInputSource(
        sourceID: String,
        cJKVFixStrategy: CJKVFixStrategy? = CJKVFixStrategy.defaultStrategy,
        expectedPID: pid_t? = nil
    ) {
        cancelPendingWorkItems()
        guard let tisTarget = resolveInputSourceBySourceID(sourceID) else {
            logger.debug { "No input source found for sourceID=\(sourceID)" }
            return
        }

        let target = SwitchTarget(
            localizedName: tisTarget.name,
            sourceID: tisTarget.id,
            inputModeID: tisTarget.inputModeID,
            isCJKV: isCJKVInputSource(tisTarget)
        )

        switchToTarget(
            target,
            tisTarget: tisTarget,
            cJKVFixStrategy: cJKVFixStrategy,
            expectedPID: expectedPID
        )
    }

    static func switchToInputMode(
        modeID: String,
        cJKVFixStrategy: CJKVFixStrategy? = CJKVFixStrategy.defaultStrategy,
        expectedPID: pid_t? = nil
    ) {
        cancelPendingWorkItems()
        guard let tisTarget = resolveInputSourceByModeID(modeID) else {
            logger.debug { "No input source found for modeID=\(modeID)" }
            return
        }

        let target = SwitchTarget(
            localizedName: tisTarget.name,
            sourceID: tisTarget.id,
            inputModeID: modeID,
            isCJKV: isCJKVInputSource(tisTarget)
        )

        switchToTarget(
            target,
            tisTarget: tisTarget,
            cJKVFixStrategy: cJKVFixStrategy,
            expectedPID: expectedPID
        )
    }

    static func switchToInputSource(
        _ inputSource: InputSource,
        cJKVFixStrategy: CJKVFixStrategy?,
        expectedPID: pid_t? = nil
    ) {
        cancelPendingWorkItems()
        let target = SwitchTarget(
            localizedName: inputSource.name,
            sourceID: inputSource.id,
            inputModeID: inputSource.inputModeID,
            isCJKV: inputSource.isCJKVR
        )

        if inputSource.isCJKVR, let modeID = inputSource.inputModeID {
            return switchToInputMode(modeID: modeID, cJKVFixStrategy: cJKVFixStrategy, expectedPID: expectedPID)
        }

        switchToTarget(
            target,
            tisTarget: inputSource.tisInputSource,
            cJKVFixStrategy: cJKVFixStrategy,
            expectedPID: expectedPID
        )
    }

    private static func switchToTarget(
        _ target: SwitchTarget,
        tisTarget: TISInputSource,
        cJKVFixStrategy: CJKVFixStrategy?,
        expectedPID: pid_t?
    ) {
        IndicatorDiagnostics.record("switch.target source=\(target.sourceID) mode=\(target.inputModeID ?? "nil") strategy=\(String(describing: cJKVFixStrategy))")
        // Cancelling a sent IPC cannot recall it. Keep later selections behind
        // its bounded wait; a timed-out receiver could still process it later.
        if privateSelectionQueue.isBusy {
            guard let pid = expectedPID ?? PrivateInputSourceSelector.keyFocusPID() else { return }
            privateSelectionQueue.enqueue(
                target: InputSource(tisInputSource: tisTarget),
                current: InputSource.getCurrentInputSource()
            ) {
                guard PrivateInputSourceSelector.keyFocusPID() == pid else { return }
                switchToTarget(target, tisTarget: tisTarget, cJKVFixStrategy: cJKVFixStrategy, expectedPID: pid)
            }
            return
        }
        guard target.isCJKV,
              let cJKVFixStrategy
        else {
            selectInputSource(tisTarget, reason: "target")
            return
        }

        switch cJKVFixStrategy {
        case .temporaryInputWindow:
            switchToCJKVTargetWithTemporaryInputWindow(target, tisTarget: tisTarget)
        case .previousInputSourceShortcut:
            switchToCJKVTargetWithPreviousInputSourceShortcut(target, tisTarget: tisTarget)
        case .directActivation:
            switchToCJKVTargetWithDirectActivation(tisTarget, expectedPID: expectedPID)
        }
    }

    private static func switchToCJKVTargetWithDirectActivation(_ source: TISInputSource, expectedPID: pid_t?) {
        let fallbackPID = expectedPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        switch PrivateInputSourceSelector.prepare(source, expectedPID: expectedPID) {
        case let .failure(error):
            logger.debug { "Direct activation could not start: \(error)" }
            IndicatorDiagnostics.record("switch.directActivation prepare=\(error)")
            guard error != .focusChanged, error != .invalidSource,
                  let fallbackPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == fallbackPID
            else { return }
            selectInputSource(source, reason: "direct activation unavailable fallback")

        case let .success(request):
            let target = InputSource(tisInputSource: source)
            let transactionID = privateSelectionQueue.begin(target: target, current: InputSource.getCurrentInputSource())
            pendingPrivateSelection = request
            privateSelectionActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { notification in
                MainActor.assumeIsolated {
                    guard pendingPrivateSelection === request,
                          let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          app.processIdentifier != request.pid
                    else { return }
                    cancelPrivateSelection()
                }
            }
            PrivateInputSourceSelector.select(request) { result in
                IndicatorDiagnostics.record("switch.directActivation pid=\(request.pid) result=\(result)")
                let actual = InputSource.getCurrentInputSource()
                var fallback: (() -> Void)?
                if pendingPrivateSelection === request,
                   request.validationFailure(
                       focusPID: PrivateInputSourceSelector.keyFocusPID,
                       now: { ProcessInfo.processInfo.systemUptime }
                   ) == nil {
                    if case let .failure(error) = result {
                        logger.debug { "Direct activation failed: \(error)" }
                        if error != .cancelled, error != .focusChanged, error != .timedOut {
                            fallback = { selectInputSource(source, reason: "direct activation failed fallback") }
                        }
                    } else if actual != target {
                        fallback = { selectInputSource(source, reason: "direct activation source mismatch fallback") }
                    }
                }
                let nextSelection = privateSelectionQueue.finish(transactionID, current: actual, fallback: fallback)
                if pendingPrivateSelection === request { cancelPrivateSelection() }
                nextSelection?()
            }
        }
    }

    private static func cancelPrivateSelection(current: InputSource? = nil) {
        privateSelectionQueue.discardPending(current: current)
        if let request = pendingPrivateSelection {
            request.cancel()
            pendingPrivateSelection = nil
        }
        if let observer = privateSelectionActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            privateSelectionActivationObserver = nil
        }
    }

    private static func switchToCJKVTargetWithTemporaryInputWindow(
        _ target: SwitchTarget,
        tisTarget: TISInputSource
    ) {
        logger.debug { "Applying CJKV fix using temporary input window" }
        selectInputSource(tisTarget, reason: "CJKV target")
        // A window requested while the previous one is still handing focus back takes over that wait.
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        temporaryInputWindowPreviousApplication = applicationToRestore(
            frontmost: frontmostApplication,
            frontmostIsSelf: isSelf(frontmostApplication),
            restoring: temporaryInputWindowPreviousApplication
        )
        restoration = nil
        restorationTimer = nil
        isShowingTemporaryInputWindow = true
        if let app = temporaryInputWindowPreviousApplication, CaretPalette.shared.point(for: app) != nil {
            // The indicator's queued activation can place itself from that sample; let it run first, as activating
            // the window blocks the main thread on the input method's session activation.
            scheduleWorkItem(after: 0.001) { showTemporaryInputWindow() }
        } else {
            // Without a sample the activation is deferred anyway, and the deferral would only queue the window
            // behind the activation pipeline.
            showTemporaryInputWindow()
        }

        scheduleWorkItem(after: temporaryInputWindowDuration + 0.05) {
            let currentInputSource = InputSource.getCurrentInputSource()
            if !target.matches(currentInputSource) {
                selectInputSource(tisTarget, reason: "CJKV target mismatch fallback")
            }
        }
    }

    private static func switchToCJKVTargetWithPreviousInputSourceShortcut(
        _ target: SwitchTarget,
        tisTarget: TISInputSource
    ) {
        guard let previousShortcut = getPreviousInputSourceShortcut(),
              let nonCJKVSource = resolveNonCJKVSource(),
              canPostShortcuts()
        else {
            selectInputSource(tisTarget, reason: "CJKV target shortcut fallback")
            return
        }

        // Suppress modifier event processing in ShortcutTriggerManager for the duration
        // of the CJKV fix sequence (~300ms) to prevent synthetic keyboard events from
        // corrupting modifier tracking state and blocking subsequent shortcut triggers.
        syntheticEventEndTime = ProcessInfo.processInfo.systemUptime + 0.35
        logger.debug { "Applying CJKV fix using previous input source shortcut" }
        // The non-CJKV bounce is an implementation detail, not the user's choice
        // to remember for the active app while the shortcut finishes.
        let selectionID = temporarySelection.begin(
            target: InputSource(tisInputSource: tisTarget),
            temporary: InputSource(tisInputSource: nonCJKVSource)
        )
        selectInputSource(tisTarget, reason: "CJKV target")
        selectInputSource(nonCJKVSource, reason: "CJKV bounce")

        scheduleWorkItem(after: 0.1, execute: {
            triggerShortcut(previousShortcut, onFinish: { currentInputSource in
                defer { temporarySelection.finish(selectionID) }
                if !target.matches(currentInputSource) {
                    selectInputSource(tisTarget, reason: "CJKV target mismatch fallback")
                }
            })
        })
    }

    @discardableResult
    private static func selectInputSource(_ source: TISInputSource, reason: String) -> OSStatus {
        let status = TISSelectInputSource(source)
        IndicatorDiagnostics.record("switch.TISSelect source=\(source.id) reason=\(reason) status=\(status)")
        if status != noErr {
            logger.debug { "TISSelectInputSource failed (\(reason)) with status \(status)" }
        }
        return status
    }

    private static func canPostShortcuts() -> Bool {
        if PermissionsVM.checkAccessibility(prompt: false) {
            return true
        } else {
            logger.debug { "Accessibility permission missing; cannot post input source shortcut." }
            return true
        }
    }

    private static func resolveNonCJKVSource() -> TISInputSource? {
        return inputSourceList().first(where: { !isCJKVInputSource($0) && $0.isSelectable && $0.isEnabled })
    }

    private static func resolveInputSourceByModeID(_ modeID: String) -> TISInputSource? {
        return inputSourceList().first(where: { $0.inputModeID == modeID && $0.isSelectable })
    }

    private static func resolveInputSourceBySourceID(_ sourceID: String) -> TISInputSource? {
        let matches = inputSourceList().filter { $0.id == sourceID && $0.isSelectable }
        if matches.isEmpty {
            return nil
        }

        if matches.count > 1 {
            logger.debug { "Multiple input sources found for sourceID=\(sourceID). Prefer inputModeID selection." }
        }

        if let base = matches.first(where: { $0.inputModeID == nil }) {
            return base
        }

        return matches.first
    }

    private static func inputSourceList() -> [TISInputSource] {
        let inputSourceNSArray = TISCreateInputSourceList(nil, false).takeRetainedValue() as NSArray
        return inputSourceNSArray as? [TISInputSource] ?? []
    }

    private static func isCJKVInputSource(_ source: TISInputSource) -> Bool {
        guard let lang = source.sourceLanguages.first else { return false }
        return lang == "ru" || lang == "ko" || lang == "ja" || lang == "vi" || lang.hasPrefix("zh")
    }

    private static func cancelPendingWorkItems() {
        cancelPrivateSelection(current: privateSelectionQueue.isBusy ? InputSource.getCurrentInputSource() : nil)
        temporarySelection.cancel()
        syntheticEventEndTime = 0
        closeTemporaryInputWindow()
        guard !pendingWorkItems.isEmpty else { return }
        pendingWorkItems.forEach { $0.cancel() }
        pendingWorkItems.removeAll()
    }

    private static func scheduleWorkItem(after delay: TimeInterval, execute work: @escaping () -> Void) {
        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem {
            guard let item = workItem else { return }
            defer { removePendingWorkItem(item) }
            guard !item.isCancelled else { return }
            work()
        }

        guard let item = workItem else { return }
        pendingWorkItems.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private static func removePendingWorkItem(_ item: DispatchWorkItem) {
        if let index = pendingWorkItems.firstIndex(where: { $0 === item }) {
            pendingWorkItems.remove(at: index)
        }
    }

    /// Adapted from macism's showTemporaryInputWindow approach.
    /// macism is MIT licensed, copyright (c) 2023 https://github.com/laishulu.
    private static func showTemporaryInputWindow() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            closeTemporaryInputWindow()
            return
        }

        let screenRect = screen.visibleFrame
        let windowSize = NSSize(width: 3, height: 3)
        let contentRect = NSRect(
            x: screenRect.maxX - windowSize.width - 8,
            y: screenRect.minY + 8,
            width: windowSize.width,
            height: windowSize.height
        )

        let window = TemporaryInputWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: NSRect(origin: .zero, size: windowSize))

        window.contentView = textView
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        temporaryInputWindow = window
        suppressTemporaryInputWindowActivation()
        IndicatorDiagnostics.record("switch.temporaryWindow show previousPID=\(temporaryInputWindowPreviousApplication?.processIdentifier ?? 0) frame=\(window.frame)")

        window.makeKeyAndOrderFront(nil)
        IndicatorDiagnostics.record("switch.temporaryWindow step=orderedFront")
        NSApp.activate(ignoringOtherApps: true)
        IndicatorDiagnostics.record("switch.temporaryWindow step=activated")
        window.makeFirstResponder(textView)
        IndicatorDiagnostics.record("switch.temporaryWindow step=firstResponder")

        scheduleWorkItem(after: temporaryInputWindowDuration) {
            closeTemporaryInputWindow()
        }
    }

    /// The app a new temporary input window hands focus back to. While the previous window is still
    /// handing focus back, this app or no app can be frontmost; the app being restored is the one to return to.
    static func applicationToRestore<App>(frontmost: App?, frontmostIsSelf: Bool, restoring: App?) -> App? {
        frontmost == nil || frontmostIsSelf ? restoring ?? frontmost : frontmost
    }

    private static func closeTemporaryInputWindow() {
        guard isShowingTemporaryInputWindow else { return }
        isShowingTemporaryInputWindow = false
        if let window = temporaryInputWindow {
            IndicatorDiagnostics.record("switch.temporaryWindow close previousPID=\(temporaryInputWindowPreviousApplication?.processIdentifier ?? 0)")
            temporaryInputWindow = nil
            window.orderOut(nil)
            window.close()
            IndicatorDiagnostics.record("switch.temporaryWindow step=closed")
            suppressTemporaryInputWindowActivation()
        }

        guard let previousApplication = temporaryInputWindowPreviousApplication,
              !isSelf(previousApplication),
              isSelf(NSWorkspace.shared.frontmostApplication),
              previousApplication.activate(options: [])
        else {
            IndicatorDiagnostics.record("switch.temporaryWindow restored reason=no-handback previousPID=\(temporaryInputWindowPreviousApplication?.processIdentifier ?? 0) frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
            finishRestoration()
            return
        }

        IndicatorDiagnostics.record("switch.temporaryWindow step=previousActivated")
        waitForRestoration()
    }

    // Not a scheduled work item: the next switch cancels those, but must not cut this wait short.
    // Polled, not notified: consumers read frontmostApplication, which in 19 of 32 measured switches still
    // returned this app when didActivateApplicationNotification for the previous app arrived (~10ms before the poll).
    private static func waitForRestoration() {
        restoration = ApplicationRestoration(checks: restorationCheckLimit)
        restorationTimer = Timer.interval(seconds: restorationCheckInterval)
            .sink { _ in checkRestoration() }
    }

    private static func checkRestoration() {
        guard var current = restoration else { return }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard current.isFinished(frontPID: frontPID, selfPID: ProcessInfo.processInfo.processIdentifier) else {
            restoration = current
            return
        }
        IndicatorDiagnostics.record("switch.temporaryWindow restored previousPID=\(temporaryInputWindowPreviousApplication?.processIdentifier ?? 0) frontPID=\(frontPID ?? 0) remainingChecks=\(current.remainingChecks)")
        finishRestoration()
    }

    private static func finishRestoration() {
        restoration = nil
        restorationTimer = nil
        temporaryInputWindowPreviousApplication = nil
        restored.send()
    }

    private static func suppressTemporaryInputWindowActivation() {
        temporaryInputWindowActivationSuppressionEndTime = ProcessInfo.processInfo.systemUptime +
            temporaryInputWindowActivationSuppressionDuration
    }
}

private final class TemporaryInputWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension InputSourceSwitcher {
    struct HotKeyInfo {
        let keyCode: CGKeyCode
        let modifiers: CGEventFlags
    }

    /// Retrieves the "Select Previous Input Source" shortcut from system defaults.
    /// Target ID 60 is the system standard for "Select Previous Input Source".
    static func getPreviousInputSourceShortcut() -> HotKeyInfo? {
        guard let dict = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys"),
              let hotKeys = dict["AppleSymbolicHotKeys"] as? [String: Any],
              let inputSourceDict = hotKeys["60"] as? [String: Any] else {
            
            logger.debug { "Could not find Input Source shortcut in global preferences." }
            return nil
        }
        
        if let enabled = inputSourceDict["enabled"] as? Bool, !enabled {
            logger.debug { "The 'Select Previous Input Source' shortcut is currently disabled in System Settings." }
            return nil
        }
        
        guard let value = inputSourceDict["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int],
              parameters.count >= 3 else {
            logger.debug { "Invalid parameter format found in plist." }
            return nil
        }
        
        let rawKeyCode = parameters[1]
        let rawModifiers = parameters[2]
        let cgModifiers = convertCarbonModifiersToCGFlags(carbonFlags: rawModifiers)
        
        return HotKeyInfo(keyCode: CGKeyCode(rawKeyCode), modifiers: cgModifiers)
    }

    /// Helper to convert legacy Carbon modifier integers to modern CGEventFlags
    static func convertCarbonModifiersToCGFlags(carbonFlags: Int) -> CGEventFlags {
        var flags = CGEventFlags()
        
        // Carbon modifier bitmasks
        if (carbonFlags & 131072) != 0 { flags.insert(.maskShift) }
        if (carbonFlags & 262144) != 0 { flags.insert(.maskControl) }
        if (carbonFlags & 524288) != 0 { flags.insert(.maskAlternate) } // Option key
        if (carbonFlags & 1048576) != 0 { flags.insert(.maskCommand) }
        
        return flags
    }

    /// Triggers the specified keyboard shortcut programmatically.
    static func triggerShortcut(_ hotKey: HotKeyInfo, onFinish: @escaping ((InputSource) -> Void)) {
        let source = CGEventSource(stateID: .hidSystemState)
        
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: hotKey.keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: hotKey.keyCode, keyDown: false)
        else {
            logger.debug { "Failed to create key press event." }
            onFinish(InputSource.getCurrentInputSource())
            return
        }
        
        markSyntheticEvent(keyDown)
        markSyntheticEvent(keyUp)
        keyDown.flags = hotKey.modifiers
        keyUp.flags = hotKey.modifiers
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        
        scheduleWorkItem(after: 0.1, execute: {
            let kVK_Command: CGKeyCode = 55
            if let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_Command, keyDown: true),
               let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: kVK_Command, keyDown: false) {
                markSyntheticEvent(cmdDown)
                markSyntheticEvent(cmdUp)
                cmdDown.flags = .maskCommand
                cmdUp.flags = []
                cmdDown.post(tap: .cghidEventTap)
                cmdUp.post(tap: .cghidEventTap)
            } else {
                logger.debug {
                    "Failed to create Command event."
                }
            }
            
            scheduleWorkItem(after: 0.1, execute: {
                onFinish(InputSource.getCurrentInputSource())
            })
        })
    }

    private static func markSyntheticEvent(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventUserData)
    }
}
