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
    }

    private static let logger = ISPLogger(category: String(describing: InputSourceSwitcher.self))
    private static var pendingWorkItems: [DispatchWorkItem] = []

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

    static func switchToInputSource(sourceID: String, useCJKVFix: Bool = true) {
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
            allowShortcutFallback: useCJKVFix
        )
    }

    static func switchToInputMode(modeID: String, useCJKVFix: Bool = true) {
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
            allowShortcutFallback: useCJKVFix
        )
    }

    static func switchToInputSource(_ inputSource: InputSource, useCJKVFix: Bool) {
        cancelPendingWorkItems()
        let target = SwitchTarget(
            localizedName: inputSource.name,
            sourceID: inputSource.id,
            inputModeID: inputSource.inputModeID,
            isCJKV: inputSource.isCJKVR
        )

        if inputSource.isCJKVR, let modeID = inputSource.inputModeID {
            return switchToInputMode(modeID: modeID, useCJKVFix: useCJKVFix)
        }

        switchToTarget(
            target,
            tisTarget: inputSource.tisInputSource,
            allowShortcutFallback: useCJKVFix
        )
    }

    private static func switchToTarget(
        _ target: SwitchTarget,
        tisTarget: TISInputSource,
        allowShortcutFallback: Bool
    ) {
        if target.isCJKV,
           allowShortcutFallback,
           let previousShortcut = getPreviousInputSourceShortcut(),
           let nonCJKVSource = resolveNonCJKVSource(),
           canPostShortcuts()
        {
            logger.debug { "Applying CJKV fix using previous input source shortcut" }
            selectInputSource(tisTarget, reason: "CJKV target")
            selectInputSource(nonCJKVSource, reason: "CJKV bounce")
            
            scheduleWorkItem(after: 0.1, execute: {
                triggerShortcut(previousShortcut, onFinish: { currentInputSouce in
                    if currentInputSouce.tisInputSource.id != tisTarget.id {
                        selectInputSource(tisTarget, reason: "CJKV target mismatch fallback")
                    }
                })
            })
        } else {
            selectInputSource(tisTarget, reason: "target")
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
        
        keyDown.flags = hotKey.modifiers
        keyUp.flags = hotKey.modifiers
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        
        scheduleWorkItem(after: 0.1, execute: {
            let kVK_Command: CGKeyCode = 55
            if let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_Command, keyDown: true),
               let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: kVK_Command, keyDown: false) {
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
}
