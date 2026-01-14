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

    struct Shortcut {
        let keyCode: CGKeyCode
        let modifiers: CGEventFlags
    }

    enum ShortcutKind: String {
        case previous
        case next
        case custom
    }

    private struct SwitchTarget {
        let localizedName: String
        let sourceID: String
        let inputModeID: String?
        let isCJKV: Bool
    }

    private struct InputSourceIdentity {
        let sourceID: String
        let inputModeID: String?
    }

    private static let logger = ISPLogger(category: String(describing: InputSourceSwitcher.self))
    private static let focusStabilizationDelay: TimeInterval = 0.05

    private static let fallbackKeyCodeKey = "inputSourceFallbackShortcutKeyCode"
    private static let fallbackModifierKey = "inputSourceFallbackShortcutModifiers"

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

    @discardableResult
    static func switchToInputSource(sourceID: String, useCJKVFix: Bool = true) -> Bool {
        guard let tisTarget = resolveInputSourceBySourceID(sourceID) else {
            logger.debug { "No input source found for sourceID=\(sourceID)" }
            return false
        }

        let target = SwitchTarget(
            localizedName: tisTarget.name,
            sourceID: tisTarget.id,
            inputModeID: tisTarget.inputModeID,
            isCJKV: isCJKVInputSource(tisTarget)
        )

        return switchToTarget(
            target,
            tisTarget: tisTarget,
            allowShortcutFallback: useCJKVFix
        )
    }

    @discardableResult
    static func switchToInputMode(modeID: String, useCJKVFix: Bool = true) -> Bool {
        guard let tisTarget = resolveInputSourceByModeID(modeID) else {
            logger.debug { "No input source found for modeID=\(modeID)" }
            return false
        }

        let target = SwitchTarget(
            localizedName: tisTarget.name,
            sourceID: tisTarget.id,
            inputModeID: modeID,
            isCJKV: isCJKVInputSource(tisTarget)
        )

        return switchToTarget(
            target,
            tisTarget: tisTarget,
            allowShortcutFallback: useCJKVFix
        )
    }

    @discardableResult
    static func switchToInputSource(_ inputSource: InputSource, useCJKVFix: Bool) -> Bool {
        let target = SwitchTarget(
            localizedName: inputSource.name,
            sourceID: inputSource.id,
            inputModeID: inputSource.inputModeID,
            isCJKV: inputSource.isCJKVR
        )

        if inputSource.isCJKVR, let modeID = inputSource.inputModeID {
            return switchToInputMode(modeID: modeID, useCJKVFix: useCJKVFix)
        }

        return switchToTarget(
            target,
            tisTarget: inputSource.tisInputSource,
            allowShortcutFallback: useCJKVFix
        )
    }

    private static func switchToTarget(
        _ target: SwitchTarget,
        tisTarget: TISInputSource,
        allowShortcutFallback: Bool
    ) -> Bool {
        stabilizeFocusIfNeeded()

        if isTargetAlreadyActive(target) {
            logger.debug { "Already using input source: \(target.localizedName) (\(target.sourceID))" }
            return true
        }

        if !tisTarget.isEnabled {
            logger.debug { "Input source not enabled: \(target.localizedName) (\(target.sourceID))" }
            return false
        }

        if target.isCJKV,
           allowShortcutFallback,
           let previousShortcut = systemSelectPreviousShortcut()
        {
            if let nonCJKVSource = resolveNonCJKVSource() {
                logger.debug { "Applying CJKV fix using previous input source shortcut" }
                _ = selectInputSource(tisTarget, reason: "CJKV target")
                _ = selectInputSource(nonCJKVSource, reason: "CJKV bounce")
                if canPostShortcuts() {
                    _ = postShortcut(previousShortcut)
                }
                return true
            }
        }

        let status = selectInputSource(tisTarget, reason: "target")
        if status == noErr {
            return true
        }

        guard allowShortcutFallback else {
            return false
        }

        return attemptShortcutFallback()
    }

    private static func isTargetAlreadyActive(_ target: SwitchTarget) -> Bool {
        return matchesTarget(target)
    }

    @discardableResult
    private static func selectInputSource(_ source: TISInputSource, reason: String) -> OSStatus {
        let status = TISSelectInputSource(source)
        if status != noErr {
            logger.debug { "TISSelectInputSource failed (\(reason)) with status \(status)" }
        }
        return status
    }

    private static func matchesTarget(_ target: SwitchTarget) -> Bool {
        guard let current = currentIdentity() else { return false }

        if let targetModeID = target.inputModeID {
            return current.inputModeID == targetModeID
        }

        return current.sourceID == target.sourceID
    }

    private static func attemptShortcutFallback() -> Bool {
        guard let (shortcut, kind) = resolveSwitchShortcut() else {
            logger.debug { "No input source shortcut available for fallback." }
            return false
        }

        guard canPostShortcuts() else {
            return false
        }

        logger.debug { "Attempting shortcut fallback using \(kind.rawValue) input source shortcut." }
        guard postShortcut(shortcut) else {
            return false
        }

        return true
    }

    private static func canPostShortcuts() -> Bool {
        // Posting CGEvents requires Accessibility permission. Input Monitoring is recommended
        // for reliable key event delivery on newer macOS versions.
        let hasAccessibility = PermissionsVM.checkAccessibility(prompt: false)
        if !hasAccessibility {
            logger.debug { "Accessibility permission missing; cannot post input source shortcut." }
            return false
        }

        let hasInputMonitoring = PermissionsVM.checkInputMonitoring(prompt: false)
        if !hasInputMonitoring {
            logger.debug { "Input Monitoring permission missing; shortcut posting may be unreliable." }
        }

        return true
    }

    private static func resolveSwitchShortcut() -> (Shortcut, ShortcutKind)? {
        if let previous = systemSelectPreviousShortcut() {
            return (previous, .previous)
        }

        if let next = systemSelectNextShortcut() {
            return (next, .next)
        }

        if let fallback = fallbackShortcutFromDefaults() {
            return (fallback, .custom)
        }

        return nil
    }

    static func systemSelectPreviousShortcut() -> Shortcut? {
        return symbolicHotkeyShortcut(symbolicKey: "60")
    }

    static func systemSelectNextShortcut() -> Shortcut? {
        return symbolicHotkeyShortcut(symbolicKey: "61")
    }

    private static func symbolicHotkeyShortcut(symbolicKey: String) -> Shortcut? {
        guard let dict = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys"),
              let symbolichotkeys = dict["AppleSymbolicHotKeys"] as? NSDictionary,
              let symbolichotkey = symbolichotkeys[symbolicKey] as? NSDictionary,
              let enabled = symbolichotkey["enabled"] as? NSNumber,
              enabled.intValue == 1,
              let value = symbolichotkey["value"] as? NSDictionary,
              let parameters = value["parameters"] as? NSArray,
              parameters.count >= 3,
              let keyCode = (parameters[1] as? NSNumber)?.intValue,
              let modifiers = (parameters[2] as? NSNumber)?.uint64Value
        else {
            return nil
        }

        return Shortcut(
            keyCode: CGKeyCode(keyCode),
            modifiers: CGEventFlags(rawValue: modifiers)
        )
    }

    private static func fallbackShortcutFromDefaults() -> Shortcut? {
        registerFallbackDefaultsIfNeeded()

        let keyCodeValue = UserDefaults.standard.integer(forKey: fallbackKeyCodeKey)
        let modifierValue = UserDefaults.standard.integer(forKey: fallbackModifierKey)

        return Shortcut(
            keyCode: CGKeyCode(keyCodeValue),
            modifiers: CGEventFlags(rawValue: UInt64(modifierValue))
        )
    }

    private static func registerFallbackDefaultsIfNeeded() {
        UserDefaults.standard.register(defaults: [
            fallbackKeyCodeKey: Int(kVK_Space),
            fallbackModifierKey: Int(CGEventFlags.maskControl.rawValue)
        ])
    }

    private static func postShortcut(_ shortcut: Shortcut) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            logger.debug { "Failed to create CGEventSource for shortcut posting." }
            return false
        }

        let modifiers = modifierKeyCodes(from: shortcut.modifiers)
        for keyCode in modifiers {
            CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?
                .post(tap: .cghidEventTap)
        }

        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: shortcut.keyCode,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: shortcut.keyCode,
            keyDown: false
        ) else {
            return false
        }

        keyDown.flags = shortcut.modifiers
        keyUp.flags = shortcut.modifiers

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        for keyCode in modifiers.reversed() {
            CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?
                .post(tap: .cghidEventTap)
        }

        return true
    }

    private static func modifierKeyCodes(from flags: CGEventFlags) -> [CGKeyCode] {
        var keyCodes: [CGKeyCode] = []

        if flags.contains(.maskShift) {
            keyCodes.append(CGKeyCode(kVK_Shift))
        }
        if flags.contains(.maskControl) {
            keyCodes.append(CGKeyCode(kVK_Control))
        }
        if flags.contains(.maskAlternate) {
            keyCodes.append(CGKeyCode(kVK_Option))
        }
        if flags.contains(.maskCommand) {
            keyCodes.append(CGKeyCode(kVK_Command))
        }

        return keyCodes
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

    private static func currentIdentity() -> InputSourceIdentity? {
        let currentSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return InputSourceIdentity(
            sourceID: currentSource.id,
            inputModeID: currentSource.inputModeID
        )
    }

    private static func stabilizeFocusIfNeeded() {
        guard focusStabilizationDelay > 0 else { return }
        wait(focusStabilizationDelay)
    }

    private static func wait(_ delay: TimeInterval) {
        let deadline = Date().addingTimeInterval(delay)
        RunLoop.current.run(until: deadline)
    }
}
