import AppKit
import Carbon
import Combine
import KeyboardShortcuts

enum ShortcutTriggerMode: String, CaseIterable, Identifiable, Codable {
    case keyboardShortcut
    case singleModifier

    var id: Self { self }

    var name: String {
        switch self {
        case .keyboardShortcut:
            return "Keyboard Shortcuts".i18n()
        case .singleModifier:
            return "Modifier Combination".i18n()
        }
    }
}

enum SingleModifierTrigger: String, CaseIterable, Identifiable, Codable {
    case singlePress
    case doublePress

    var id: Self { self }

    var name: String {
        switch self {
        case .singlePress:
            return "Press Once".i18n()
        case .doublePress:
            return "Press Twice".i18n()
        }
    }
}

enum SingleModifierKey: String, CaseIterable, Identifiable, Codable {
    case leftShift
    case rightShift
    case leftControl
    case rightControl
    case leftOption
    case rightOption
    case leftCommand
    case rightCommand

    var id: Self { self }

    var name: String {
        switch self {
        case .leftShift:
            return "Left Shift".i18n()
        case .rightShift:
            return "Right Shift".i18n()
        case .leftControl:
            return "Left Control".i18n()
        case .rightControl:
            return "Right Control".i18n()
        case .leftOption:
            return "Left Option".i18n()
        case .rightOption:
            return "Right Option".i18n()
        case .leftCommand:
            return "Left Command".i18n()
        case .rightCommand:
            return "Right Command".i18n()
        }
    }

    var sortOrder: Int {
        switch self {
        case .leftShift:
            return 0
        case .rightShift:
            return 1
        case .leftControl:
            return 2
        case .rightControl:
            return 3
        case .leftOption:
            return 4
        case .rightOption:
            return 5
        case .leftCommand:
            return 6
        case .rightCommand:
            return 7
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .leftShift:
            return UInt16(kVK_Shift)
        case .rightShift:
            return UInt16(kVK_RightShift)
        case .leftControl:
            return UInt16(kVK_Control)
        case .rightControl:
            return UInt16(kVK_RightControl)
        case .leftOption:
            return UInt16(kVK_Option)
        case .rightOption:
            return UInt16(kVK_RightOption)
        case .leftCommand:
            return UInt16(kVK_Command)
        case .rightCommand:
            return UInt16(kVK_RightCommand)
        }
    }

    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .leftShift, .rightShift:
            return .shift
        case .leftControl, .rightControl:
            return .control
        case .leftOption, .rightOption:
            return .option
        case .leftCommand, .rightCommand:
            return .command
        }
    }

    static func from(keyCode: UInt16) -> SingleModifierKey? {
        switch keyCode {
        case UInt16(kVK_Shift):
            return .leftShift
        case UInt16(kVK_RightShift):
            return .rightShift
        case UInt16(kVK_Control):
            return .leftControl
        case UInt16(kVK_RightControl):
            return .rightControl
        case UInt16(kVK_Option):
            return .leftOption
        case UInt16(kVK_RightOption):
            return .rightOption
        case UInt16(kVK_Command):
            return .leftCommand
        case UInt16(kVK_RightCommand):
            return .rightCommand
        default:
            return nil
        }
    }
}

struct ModifierCombo: Hashable, Codable, Identifiable {
    let keys: Set<SingleModifierKey>

    init(keys: Set<SingleModifierKey>) {
        self.keys = keys
    }

    var id: String {
        orderedKeys.map(\.rawValue).joined(separator: "+")
    }

    var orderedKeys: [SingleModifierKey] {
        keys.sorted { $0.sortOrder < $1.sortOrder }
    }

    var displayName: String {
        orderedKeys.map(\.name).joined(separator: " + ")
    }

    var isSingle: Bool {
        keys.count == 1
    }

    var singleKey: SingleModifierKey? {
        guard keys.count == 1 else { return nil }
        return keys.first
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let single = try? container.decode(SingleModifierKey.self) {
            keys = [single]
            return
        }

        if let array = try? container.decode([SingleModifierKey].self) {
            keys = Set(array)
            return
        }

        if let set = try? container.decode(Set<SingleModifierKey>.self) {
            keys = set
            return
        }

        keys = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let ordered = orderedKeys

        if ordered.count == 1 {
            try container.encode(ordered[0])
        } else {
            try container.encode(ordered)
        }
    }
}

struct ShortcutBinding {
    let id: String
    let mode: ShortcutTriggerMode
    let modifierCombo: ModifierCombo?
    let singleModifierTrigger: SingleModifierTrigger
    let onTrigger: () -> Void
}

@MainActor
final class ShortcutTriggerManager {
    private var cancelBag = CancelBag()
    private var modifierTapTimestamps: [SingleModifierKey: TimeInterval] = [:]
    private let doublePressInterval: TimeInterval

    /// Maximum duration (in seconds) a modifier can be held for the shortcut to trigger
    /// If held longer, user may have forgotten or changed their mind
    private let maxHoldDuration: TimeInterval = 0.8
    /// Prevent triggering if any other key was pressed shortly before the modifier release
    private let otherKeyPressSuppressInterval: TimeInterval = 0.2

    /// Tracks which modifier keys are currently pressed down (key: modifier key, value: press timestamp)
    private var pressedModifiers: [SingleModifierKey: TimeInterval] = [:]
    /// Tracks whether a combo has been invalidated by extra modifiers or other key activity
    private var comboInvalidated: Set<ModifierCombo> = []
    /// Tracks whether all keys in a combo were pressed at least once during the current hold cycle
    private var comboCompleted: Set<ModifierCombo> = []
    /// Tracks the earliest press timestamp for each combo in the current hold cycle
    private var comboPressTimestamps: [ModifierCombo: TimeInterval] = [:]
    /// Timestamp of the most recent key-down per keyCode (includes modifier keys).
    private var lastKeyDownTimestamps: [UInt16: TimeInterval] = [:]

    /// Event monitors for flagsChanged
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?

    /// CGEvent tap for keyDown/keyUp monitoring (requires Input Monitoring permission)
    private var keyEventTap: CFMachPort?
    private var keyEventRunLoopSource: CFRunLoopSource?

    /// Current bindings
    private var currentBindingsByCombo: [ModifierCombo: ShortcutBinding] = [:]
    private var currentCombos: Set<ModifierCombo> = []

    /// Track last processed flagsChanged event to deduplicate
    private var lastEventTimestamp: TimeInterval = 0
    private var lastEventKeyCode: UInt16 = 0

    /// Reference to preferencesVM for permission watching
    private var preferencesVM: PreferencesVM

    /// Whether we've successfully set up the key event tap
    private var isKeyEventTapEnabled = false

    /// Pending bindings to register after permissions are granted
    private var pendingBindings: [ShortcutBinding] = []

    init(preferencesVM: PreferencesVM, doublePressInterval: TimeInterval = 0.35) {
        self.preferencesVM = preferencesVM
        self.doublePressInterval = doublePressInterval
        watchPermissions()
    }

    deinit {
        // deinit is nonisolated; schedule main-actor cleanup asynchronously
        Task { @MainActor in
            removeAllMonitors()
        }
    }

    private func watchPermissions() {
        // Watch for Accessibility + Input Monitoring changes to re-register pending bindings.

        let accessibilityPublisher = preferencesVM.permissionsVM.$isAccessibilityEnabled
            .removeDuplicates()

        let inputMonitoringPublisher = preferencesVM.permissionsVM.$isInputMonitoringEnabled
            .removeDuplicates()

        Publishers.CombineLatest(accessibilityPublisher, inputMonitoringPublisher)
            .sink { [weak self] isAccessibilityEnabled, isInputMonitoringEnabled in
                guard let self = self else { return }
                guard isAccessibilityEnabled, isInputMonitoringEnabled,
                    !self.pendingBindings.isEmpty
                else { return }
                self.registerSingleModifierShortcuts(self.pendingBindings)
            }
            .store(in: cancelBag)
    }

    func updateBindings(_ bindings: [ShortcutBinding]) {
        modifierTapTimestamps.removeAll()
        pressedModifiers.removeAll()
        comboInvalidated.removeAll()
        comboCompleted.removeAll()
        comboPressTimestamps.removeAll()
        lastKeyDownTimestamps.removeAll()
        removeAllMonitors()
        KeyboardShortcuts.removeAllHandlers()

        registerKeyboardShortcuts(bindings.filter { $0.mode == .keyboardShortcut })
        registerSingleModifierShortcuts(bindings.filter { $0.mode == .singleModifier })
    }

    private func removeAllMonitors() {
        if let monitor = globalFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            globalFlagsMonitor = nil
        }
        if let monitor = localFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            localFlagsMonitor = nil
        }
        removeKeyEventTap()
        currentBindingsByCombo.removeAll()
        currentCombos.removeAll()
        pendingBindings.removeAll()
    }

    private func removeKeyEventTap() {
        if let runLoopSource = keyEventRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            keyEventRunLoopSource = nil
        }
        if let eventTap = keyEventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            keyEventTap = nil
        }
        isKeyEventTapEnabled = false
    }

    private func registerKeyboardShortcuts(_ bindings: [ShortcutBinding]) {
        for binding in bindings {
            KeyboardShortcuts.onKeyUp(for: .init(binding.id)) {
                binding.onTrigger()
            }
        }
    }

    private func registerSingleModifierShortcuts(_ bindings: [ShortcutBinding]) {
        currentBindingsByCombo = Dictionary(
            bindings.compactMap { binding -> (ModifierCombo, ShortcutBinding)? in
                guard let combo = binding.modifierCombo, !combo.keys.isEmpty else { return nil }
                return (combo, binding)
            },
            uniquingKeysWith: { _, new in new }
        )
        currentCombos = Set(currentBindingsByCombo.keys)

        guard !currentBindingsByCombo.isEmpty else { return }

        // Store bindings for potential re-registration after permission grant
        pendingBindings = bindings

        // Check if we have both required permissions
        // If not, don't set up monitors - they won't work reliably anyway
        guard preferencesVM.permissionsVM.isAccessibilityEnabled, preferencesVM.permissionsVM.isInputMonitoringEnabled else {
            return
        }

        // Set up CGEvent tap for keyDown/keyUp monitoring
        setupKeyEventTapIfNeeded()

        // Monitor for modifier key changes using NSEvent (flagsChanged works without Input Monitoring)
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) {
            [weak self] event in
            self?.handleFlagsChanged(event)
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) {
            [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func setupKeyEventTapIfNeeded() {
        guard !isKeyEventTapEnabled else { return }
        guard !currentBindingsByCombo.isEmpty else { return }

        // Create event tap for keyDown, keyUp, mouse button, and scroll events
        // Mouse events: handle Shift+click for text selection
        // Scroll events: handle Shift+scroll for horizontal scrolling
        let eventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.scrollWheel.rawValue)

        guard
            let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,  // Only listen, don't modify events
                eventsOfInterest: CGEventMask(eventMask),
                callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                    guard let refcon = refcon else {
                        return Unmanaged.passUnretained(event)
                    }

                    let manager = Unmanaged<ShortcutTriggerManager>.fromOpaque(refcon)
                        .takeUnretainedValue()
                    manager.handleKeyEvent(type: type, event: event)

                    return Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            return
        }

        self.keyEventTap = eventTap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        self.keyEventRunLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)

        CGEvent.tapEnable(tap: eventTap, enable: true)
        isKeyEventTapEnabled = true
    }

    private func handleKeyEvent(type: CGEventType, event: CGEvent) {
        // Invalidate on keyDown, mouse button down, or scroll events
        // keyDown: when user starts typing a character
        // mouseDown: when user clicks (e.g., Shift+click for text selection)
        // scrollWheel: when user scrolls (e.g., Shift+scroll for horizontal scrolling)
        switch type {
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let eventTimestamp = ProcessInfo.processInfo.systemUptime
            // Invalidate all currently pressed modifiers
            // This is called from the CGEvent callback, which may be on a different thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lastKeyDownTimestamps[keyCode] = eventTimestamp
                self.invalidateCombosForPressedModifiers()
                self.modifierTapTimestamps.removeAll()
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            // Invalidate all currently pressed modifiers
            // This is called from the CGEvent callback, which may be on a different thread
            DispatchQueue.main.async { [weak self] in
                self?.invalidateCombosForPressedModifiers()
                self?.modifierTapTimestamps.removeAll()
            }
        default:
            break
        }
    }

    private func invalidateCombosForPressedModifiers() {
        let pressedKeys = Set(pressedModifiers.keys)
        guard !pressedKeys.isEmpty else { return }

        for combo in currentCombos {
            guard !pressedKeys.isDisjoint(with: combo.keys) else { continue }
            comboInvalidated.insert(combo)
            comboCompleted.remove(combo)
            comboPressTimestamps.removeValue(forKey: combo)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        // Deduplicate events (both global and local monitors may fire for same event)
        guard event.timestamp != lastEventTimestamp || event.keyCode != lastEventKeyCode else {
            return
        }
        lastEventTimestamp = event.timestamp
        lastEventKeyCode = event.keyCode

        guard let key = SingleModifierKey.from(keyCode: event.keyCode) else { return }

        var flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        flags.remove(.capsLock)

        let isKeyDown = flags.contains(key.modifierFlag)

        if isKeyDown {
            lastKeyDownTimestamps[event.keyCode] = event.timestamp
        }

        if isKeyDown {
            // Modifier key pressed down
            if pressedModifiers[key] == nil {
                pressedModifiers[key] = event.timestamp
            }
            updateComboState(pressedKeys: Set(pressedModifiers.keys), timestamp: event.timestamp)
        } else {
            // Modifier key released
            guard pressedModifiers.removeValue(forKey: key) != nil else { return }

            let pressedKeys = Set(pressedModifiers.keys)

            // Check if any other modifiers are still held
            if !pressedKeys.isEmpty {
                updateComboState(pressedKeys: pressedKeys, timestamp: event.timestamp)
                return
            }

            triggerCompletedCombos(at: event.timestamp)
            comboInvalidated.removeAll()
            comboCompleted.removeAll()
            comboPressTimestamps.removeAll()
        }
    }

    private func updateComboState(pressedKeys: Set<SingleModifierKey>, timestamp: TimeInterval) {
        var didInvalidate = false

        for combo in currentCombos {
            if pressedKeys.isDisjoint(with: combo.keys) {
                comboInvalidated.remove(combo)
                comboCompleted.remove(combo)
                comboPressTimestamps.removeValue(forKey: combo)
                continue
            }

            if comboInvalidated.contains(combo) {
                continue
            }

            if !pressedKeys.isSubset(of: combo.keys) {
                comboInvalidated.insert(combo)
                comboCompleted.remove(combo)
                comboPressTimestamps.removeValue(forKey: combo)
                didInvalidate = true
                continue
            }

            if comboPressTimestamps[combo] == nil {
                let earliestPress = combo.keys.compactMap { pressedModifiers[$0] }.min() ?? timestamp
                comboPressTimestamps[combo] = earliestPress
            }

            if pressedKeys.isSuperset(of: combo.keys) {
                comboCompleted.insert(combo)
            }
        }

        if didInvalidate {
            modifierTapTimestamps.removeAll()
        }
    }

    private func triggerCompletedCombos(at timestamp: TimeInterval) {
        for combo in comboCompleted {
            guard !comboInvalidated.contains(combo) else { continue }
            guard let binding = currentBindingsByCombo[combo] else { continue }

            let pressTimestamp = comboPressTimestamps[combo] ?? timestamp
            let holdDuration = timestamp - pressTimestamp
            if holdDuration > maxHoldDuration {
                continue
            }

            if didPressOtherKeyRecently(before: timestamp, excluding: combo.keys) {
                if let key = combo.singleKey {
                    modifierTapTimestamps.removeValue(forKey: key)
                }
                continue
            }

            let effectiveTrigger: SingleModifierTrigger = combo.keys.count > 1
                ? .singlePress
                : binding.singleModifierTrigger

            handleSingleModifierTrigger(
                combo: combo,
                timestamp: timestamp,
                trigger: effectiveTrigger,
                action: binding.onTrigger
            )
        }
    }

    private func didPressOtherKeyRecently(
        before timestamp: TimeInterval,
        excluding keys: Set<SingleModifierKey>
    ) -> Bool {
        let excludedKeyCodes = Set(keys.map(\.keyCode))
        let lastOtherKeyTimestamp = lastKeyDownTimestamps
            .filter { !excludedKeyCodes.contains($0.key) }
            .map(\.value)
            .max()

        guard let lastOtherKeyTimestamp else { return false }
        return timestamp - lastOtherKeyTimestamp <= otherKeyPressSuppressInterval
    }

    private func handleSingleModifierTrigger(
        combo: ModifierCombo,
        timestamp: TimeInterval,
        trigger: SingleModifierTrigger,
        action: () -> Void
    ) {
        guard let key = combo.singleKey else {
            action()
            return
        }

        switch trigger {
        case .singlePress:
            action()
        case .doublePress:
            if let lastTap = modifierTapTimestamps[key],
                timestamp - lastTap <= doublePressInterval
            {
                modifierTapTimestamps.removeValue(forKey: key)
                action()
            } else {
                modifierTapTimestamps[key] = timestamp
            }
        }
    }
}
