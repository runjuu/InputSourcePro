import AppKit
import Carbon
import CoreGraphics

@MainActor
enum InputSourceSwitcher {
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

        var persistentIdentifier: String {
            if let inputModeID, !inputModeID.isEmpty {
                return "\(sourceID)::\(inputModeID)"
            }

            return sourceID
        }

        @MainActor
        func matches(_ inputSource: InputSource) -> Bool {
            if let inputModeID {
                return inputSource.inputModeID == inputModeID
            }

            return inputSource.id == sourceID
        }
    }

    private struct ShortcutFallback {
        let previousShortcut: HotKeyInfo
        let nonCJKVSource: TISInputSource
    }

    private static let logger = ISPLogger(category: String(describing: InputSourceSwitcher.self))
    private static var pendingWorkItems: [DispatchWorkItem] = []
    private static var temporaryInputWindow: NSWindow?
    private static var temporaryInputWindowPreviousApplication: NSRunningApplication?
    private static let temporaryInputWindowDuration: TimeInterval = 0.08
    // App activation notifications can arrive after the hidden window has already closed.
    private static let temporaryInputWindowActivationSuppressionDuration: TimeInterval = 0.5
    private static var temporaryInputWindowActivationSuppressionEndTime: TimeInterval = 0
    private static let syntheticEventUserData: Int64 = 0x49535043534A4B56 // "ISPCSJKV"

    private(set) static var isShowingTemporaryInputWindow = false

    static var isHandlingTemporaryInputWindowActivation: Bool {
        isShowingTemporaryInputWindow ||
            ProcessInfo.processInfo.systemUptime < temporaryInputWindowActivationSuppressionEndTime
    }

    static func isTemporaryInputWindowApplicationActivation(_ application: NSRunningApplication) -> Bool {
        guard isHandlingTemporaryInputWindowActivation else { return false }
        return application.bundleIdentifier == Bundle.main.bundleIdentifier
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

    static func switchToInputSource(
        sourceID: String,
        cJKVFixStrategy: CJKVFixStrategy? = CJKVFixStrategy.defaultStrategy
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
            cJKVFixStrategy: cJKVFixStrategy
        )
    }

    static func switchToInputMode(
        modeID: String,
        cJKVFixStrategy: CJKVFixStrategy? = CJKVFixStrategy.defaultStrategy
    ) {
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
            cJKVFixStrategy: cJKVFixStrategy
        )
    }

    static func switchToInputSource(
        _ inputSource: InputSource,
        cJKVFixStrategy: CJKVFixStrategy?,
        allowShortcutFallback: Bool = true
    ) {
        cancelPendingWorkItems()
        let target = SwitchTarget(
            localizedName: inputSource.name,
            sourceID: inputSource.id,
            inputModeID: inputSource.inputModeID,
            isCJKV: inputSource.isCJKVR
        )

        if inputSource.isCJKVR, let modeID = inputSource.inputModeID {
            return switchToInputMode(
                modeID: modeID,
                cJKVFixStrategy: allowShortcutFallback ? cJKVFixStrategy : nil
            )
        }

        switchToTarget(
            target,
            tisTarget: inputSource.tisInputSource,
            cJKVFixStrategy: allowShortcutFallback ? cJKVFixStrategy : nil
        )
    }

    private static func switchToTarget(
        _ target: SwitchTarget,
        tisTarget: TISInputSource,
        cJKVFixStrategy: CJKVFixStrategy?
    ) {
        let shortcutFallback: ShortcutFallback?

        if target.isCJKV,
           cJKVFixStrategy == .previousInputSourceShortcut,
           let previousShortcut = getPreviousInputSourceShortcut(),
           let nonCJKVSource = resolveNonCJKVSource(),
           canPostShortcuts()
        {
            syntheticEventEndTime = ProcessInfo.processInfo.systemUptime + 0.35
            shortcutFallback = ShortcutFallback(
                previousShortcut: previousShortcut,
                nonCJKVSource: nonCJKVSource
            )
        } else {
            shortcutFallback = nil
        }

        if target.isCJKV, cJKVFixStrategy == .temporaryInputWindow {
            switchToCJKVTargetWithTemporaryInputWindow(target, tisTarget: tisTarget)
            return
        }

        selectInputSource(tisTarget, reason: "target")
        scheduleSelectionVerification(
            for: target,
            tisTarget: tisTarget,
            shortcutFallback: shortcutFallback
        )
    }

    private static func switchToCJKVTargetWithTemporaryInputWindow(
        _ target: SwitchTarget,
        tisTarget: TISInputSource
    ) {
        logger.debug { "Applying CJKV fix using temporary input window" }
        selectInputSource(tisTarget, reason: "CJKV target")
        showTemporaryInputWindow()

        scheduleWorkItem(after: temporaryInputWindowDuration + 0.05) {
            let currentInputSource = InputSource.getCurrentInputSource()
            guard !isCurrentInputSourceMatched(currentInputSource, with: target) else { return }

            selectInputSource(tisTarget, reason: "CJKV target mismatch fallback")
            scheduleSelectionVerification(
                for: target,
                tisTarget: tisTarget,
                remainingAttempts: 2
            )
        }
    }

    @discardableResult
    private static func selectInputSource(_ source: TISInputSource, reason: String) -> OSStatus {
        let status = TISSelectInputSource(source)
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
        syntheticEventEndTime = 0
        closeTemporaryInputWindow(restorePreviousApplication: true)
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

    private static func scheduleSelectionVerification(
        for target: SwitchTarget,
        tisTarget: TISInputSource,
        shortcutFallback: ShortcutFallback? = nil,
        didApplyShortcutFallback: Bool = false,
        remainingAttempts: Int = 3
    ) {
        guard remainingAttempts > 0 else { return }

        scheduleWorkItem(after: 0.05, execute: {
            let currentInputSource = InputSource.getCurrentInputSource()

            guard !isCurrentInputSourceMatched(currentInputSource, with: target) else { return }

            if let shortcutFallback, !didApplyShortcutFallback {
                logger.debug {
                    "Direct input source selection did not stick for \(target.localizedName) (\(target.persistentIdentifier)); applying CJKV shortcut fallback."
                }

                applyShortcutFallback(
                    shortcutFallback,
                    for: target,
                    tisTarget: tisTarget,
                    remainingAttempts: remainingAttempts - 1
                )
                return
            }

            logger.debug {
                "Retrying input source selection for \(target.localizedName) (\(target.persistentIdentifier)); current=\(currentInputSource.persistentIdentifier)"
            }

            selectInputSource(tisTarget, reason: "verification retry")
            scheduleSelectionVerification(
                for: target,
                tisTarget: tisTarget,
                shortcutFallback: nil,
                didApplyShortcutFallback: didApplyShortcutFallback,
                remainingAttempts: remainingAttempts - 1
            )
        })
    }

    private static func applyShortcutFallback(
        _ shortcutFallback: ShortcutFallback,
        for target: SwitchTarget,
        tisTarget: TISInputSource,
        remainingAttempts: Int
    ) {
        logger.debug { "Applying CJKV shortcut fallback for \(target.localizedName)" }
        selectInputSource(shortcutFallback.nonCJKVSource, reason: "CJKV bounce")

        scheduleWorkItem(after: 0.1, execute: {
            triggerShortcut(shortcutFallback.previousShortcut, onFinish: { currentInputSource in
                if !isCurrentInputSourceMatched(currentInputSource, with: target) {
                    selectInputSource(tisTarget, reason: "CJKV fallback target retry")
                }

                scheduleSelectionVerification(
                    for: target,
                    tisTarget: tisTarget,
                    shortcutFallback: nil,
                    didApplyShortcutFallback: true,
                    remainingAttempts: remainingAttempts
                )
            })
        })
    }

    private static func isCurrentInputSourceMatched(_ currentInputSource: InputSource, with target: SwitchTarget) -> Bool {
        if let inputModeID = target.inputModeID, !inputModeID.isEmpty {
            return currentInputSource.inputModeID == inputModeID ||
                currentInputSource.persistentIdentifier == target.persistentIdentifier
        }

        return currentInputSource.id == target.sourceID
    }

    /// Adapted from macism's showTemporaryInputWindow approach.
    /// macism is MIT licensed, copyright (c) 2023 https://github.com/laishulu.
    private static func showTemporaryInputWindow() {
        closeTemporaryInputWindow(restorePreviousApplication: false)

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        temporaryInputWindowPreviousApplication = NSWorkspace.shared.frontmostApplication

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
        isShowingTemporaryInputWindow = true

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(textView)

        scheduleWorkItem(after: temporaryInputWindowDuration) {
            closeTemporaryInputWindow(restorePreviousApplication: true)
        }
    }

    private static func closeTemporaryInputWindow(restorePreviousApplication: Bool) {
        guard let window = temporaryInputWindow else {
            isShowingTemporaryInputWindow = false
            temporaryInputWindowPreviousApplication = nil
            return
        }

        temporaryInputWindow = nil
        window.orderOut(nil)
        window.close()
        suppressTemporaryInputWindowActivation()
        isShowingTemporaryInputWindow = false

        defer {
            temporaryInputWindowPreviousApplication = nil
        }

        guard restorePreviousApplication,
              let previousApplication = temporaryInputWindowPreviousApplication,
              previousApplication.bundleIdentifier != Bundle.main.bundleIdentifier,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        else { return }

        previousApplication.activate(options: [])
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
