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
            return "Single Modifier".i18n()
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

struct ShortcutBinding {
    let id: String
    let mode: ShortcutTriggerMode
    let singleModifierKey: SingleModifierKey?
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
    /// Tracks whether a non-modifier key was pressed while a modifier was held
    private var modifierInvalidated: Set<SingleModifierKey> = []
    /// Timestamp of the most recent key-down per keyCode (includes modifier keys).
    private var lastKeyDownTimestamps: [UInt16: TimeInterval] = [:]

    /// Event monitors for flagsChanged
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?

    /// CGEvent tap for keyDown/keyUp monitoring (requires Input Monitoring permission)
    private var keyEventTap: CFMachPort?
    private var keyEventRunLoopSource: CFRunLoopSource?

    /// Current bindings
    private var currentBindingsByKey: [SingleModifierKey: ShortcutBinding] = [:]

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
        modifierInvalidated.removeAll()
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
        currentBindingsByKey.removeAll()
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
        currentBindingsByKey = Dictionary(
            bindings.compactMap { binding -> (SingleModifierKey, ShortcutBinding)? in
                guard let key = binding.singleModifierKey else { return nil }
                return (key, binding)
            },
            uniquingKeysWith: { _, new in new }
        )

        guard !currentBindingsByKey.isEmpty else { return }

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
        guard !currentBindingsByKey.isEmpty else { return }

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
                self.invalidateAllPressedModifiers()
                self.modifierTapTimestamps.removeAll()
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            // Invalidate all currently pressed modifiers
            // This is called from the CGEvent callback, which may be on a different thread
            DispatchQueue.main.async { [weak self] in
                self?.invalidateAllPressedModifiers()
                self?.modifierTapTimestamps.removeAll()
            }
        default:
            break
        }
    }

    private func invalidateAllPressedModifiers() {
        for key in pressedModifiers.keys {
            modifierInvalidated.insert(key)
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

        guard let binding = currentBindingsByKey[key] else { return }

        if isKeyDown {
            // Modifier key pressed down
            // Only track if this is the ONLY modifier pressed
            if flags == key.modifierFlag {
                pressedModifiers[key] = event.timestamp
                modifierInvalidated.remove(key)
            } else {
                // Multiple modifiers pressed - invalidate
                invalidateAllPressedModifiers()
                modifierTapTimestamps.removeAll()
                modifierInvalidated.insert(key)
            }
        } else {
            // Modifier key released
            guard let pressTimestamp = pressedModifiers.removeValue(forKey: key) else {
                return
            }

            // Check if this modifier was invalidated (another key was pressed while held)
            if modifierInvalidated.contains(key) {
                modifierInvalidated.remove(key)
                modifierTapTimestamps.removeValue(forKey: key)
                return
            }

            // Check if any other modifiers are still held
            if !flags.isEmpty {
                return
            }

            // Check if modifier was held for too long (user may have forgotten or changed mind)
            let holdDuration = event.timestamp - pressTimestamp
            if holdDuration > maxHoldDuration {
                return
            }

            if didPressOtherKeyRecently(before: event.timestamp, excluding: key) {
                modifierTapTimestamps.removeValue(forKey: key)
                return
            }

            handleSingleModifierTrigger(
                key: key,
                timestamp: event.timestamp,
                trigger: binding.singleModifierTrigger,
                action: binding.onTrigger
            )
        }
    }

    private func didPressOtherKeyRecently(
        before timestamp: TimeInterval,
        excluding key: SingleModifierKey
    ) -> Bool {
        let lastOtherKeyTimestamp = lastKeyDownTimestamps
            .filter { $0.key != key.keyCode }
            .map(\.value)
            .max()

        guard let lastOtherKeyTimestamp else { return false }
        return timestamp - lastOtherKeyTimestamp <= otherKeyPressSuppressInterval
    }

    private func handleSingleModifierTrigger(
        key: SingleModifierKey,
        timestamp: TimeInterval,
        trigger: SingleModifierTrigger,
        action: () -> Void
    ) {
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
