import AppKit
import Carbon
import Combine

@MainActor
final class PunctuationService: ObservableObject {
    enum Mode: Equatable {
        case appEnglish
        case markdown
    }

    enum Failure: Error, Equatable {
        case missingPermissions(inputMonitoring: Bool, accessibility: Bool)
        case anotherInstanceRunning
        case eventTapCreationFailed
        case eventTapDisabled
        case handlerTimedOut
    }

    struct SafetyShutdown: Equatable {
        let mode: Mode
        let failure: Failure
    }

    final class EventTap {
        private var invalidateHandler: (() -> Void)?

        init(invalidate: @escaping () -> Void) {
            invalidateHandler = invalidate
        }

        func invalidate() {
            let invalidate = invalidateHandler
            invalidateHandler = nil
            invalidate?()
        }

        deinit {
            invalidateHandler?()
        }
    }

    struct Dependencies {
        var hasInputMonitoring: @MainActor () -> Bool = { PermissionsVM.checkInputMonitoring(prompt: false) }
        var hasAccessibility: @MainActor () -> Bool = { PermissionsVM.checkAccessibility(prompt: false) }
        var hasAnotherInstance: () -> Bool = {
            ["com.runjuu.Input-Source-Pro", "com.runjuu.Input-Source-Pro.Markdown"]
                .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
        }
        var createEventTap: @MainActor (CGEventTapCallBack, UnsafeMutableRawPointer) -> EventTap? = PunctuationService.createEventTap
        var markdownInputContext: () -> MarkdownPunctuationMapping.InputContext? = MarkdownPunctuationMapping.currentInputContext
        var now: () -> TimeInterval = CACurrentMediaTime
    }

    private let logger = ISPLogger(category: String(describing: PunctuationService.self))
    private let generatedEventMarker: Int64 = 0x4953_504D_44
    private let maximumHandlerDuration: TimeInterval = 0.05
    private let dependencies: Dependencies
    private var eventTap: EventTap?
    private(set) var activeMode: Mode?
    var onSafetyShutdown: ((SafetyShutdown) -> Void)?

    private var cachedInputSource: InputSource?
    private var inputSourceCacheTime: TimeInterval = 0
    private let inputSourceCacheTimeout: TimeInterval = 0.5

    private let appEnglishPunctuationMap: [UInt16: (normal: String?, shifted: String?)] = [
        UInt16(kVK_ANSI_Grave): ("`", "~"),
        UInt16(kVK_ANSI_4): (nil, "$"),
        UInt16(kVK_ANSI_6): (nil, "^"),
        UInt16(kVK_ANSI_Minus): ("-", "_"),
        UInt16(kVK_ANSI_Comma): (",", "<"),
        UInt16(kVK_ANSI_Period): (".", ">"),
        UInt16(kVK_ANSI_Semicolon): (";", ":"),
        UInt16(kVK_ANSI_Quote): ("'", "\""),
        UInt16(kVK_ANSI_Backslash): ("\\", "|"),
        UInt16(kVK_ANSI_LeftBracket): ("[", "{"),
        UInt16(kVK_ANSI_RightBracket): ("]", "}")
    ]

    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
    }

    @discardableResult
    func enable(mode: Mode) -> Result<Void, Failure> {
        if mode == .markdown, let failure = markdownActivationFailure() {
            if activeMode == .markdown {
                disable()
            }
            return .failure(failure)
        }

        if eventTap != nil {
            activeMode = mode
            return .success(())
        }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else {
                return Unmanaged.passUnretained(event)
            }
            let service = Unmanaged<PunctuationService>.fromOpaque(refcon).takeUnretainedValue()
            return service.handleKeyEvent(type: type, event: event)
        }
        guard let eventTap = dependencies.createEventTap(callback, Unmanaged.passUnretained(self).toOpaque()) else {
            disable()
            return .failure(.eventTapCreationFailed)
        }

        self.eventTap = eventTap
        activeMode = mode
        return .success(())
    }

    func disable() {
        activeMode = nil
        let eventTap = eventTap
        self.eventTap = nil
        eventTap?.invalidate()
        cachedInputSource = nil
        inputSourceCacheTime = 0
    }

    private func markdownActivationFailure() -> Failure? {
        let inputMonitoring = dependencies.hasInputMonitoring()
        let accessibility = dependencies.hasAccessibility()
        guard inputMonitoring && accessibility else {
            return .missingPermissions(inputMonitoring: !inputMonitoring, accessibility: !accessibility)
        }
        return dependencies.hasAnotherInstance() ? .anotherInstanceRunning : nil
    }

    private static func createEventTap(callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer) -> EventTap? {
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        for placement in [CGEventTapPlacement.headInsertEventTap, .tailAppendEventTap] {
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: placement,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: callback,
                userInfo: userInfo
            ) else { continue }

            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                CFMachPortInvalidate(tap)
                continue
            }
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            return EventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
                CFMachPortInvalidate(tap)
            }
        }
        return nil
    }

    func handleKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent> {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            shutdownForSafety(.eventTapDisabled)
            return Unmanaged.passUnretained(event)
        }

        guard let mode = activeMode, type == .keyDown,
              event.getIntegerValueField(.eventSourceUserData) != generatedEventMarker,
              let keyCode = CGKeyCode(exactly: event.getIntegerValueField(.keyboardEventKeycode))
        else { return Unmanaged.passUnretained(event) }

        let handlerStartTime = dependencies.now()
        defer {
            if mode == .markdown, dependencies.now() - handlerStartTime > maximumHandlerDuration {
                shutdownForSafety(.handlerTimedOut)
            }
        }

        let replacement: String?
        switch mode {
        case .markdown:
            replacement = MarkdownPunctuationMapping.replacement(
                for: keyCode,
                flags: event.flags,
                keyboardType: event.getIntegerValueField(.keyboardEventKeyboardType),
                contextProvider: dependencies.markdownInputContext
            )
        case .appEnglish:
            if let mapping = appEnglishPunctuationMap[keyCode], shouldReplacePunctuation(for: event.flags),
               let punctuation = event.flags.contains(.maskShift) ? mapping.shifted : mapping.normal,
               getCachedCurrentInputSource().isCJKVR {
                replacement = punctuation
            } else {
                replacement = nil
            }
        }

        guard let replacement = replacement,
              let newEvent = createEnglishPunctuationEvent(originalEvent: event, replacement: replacement)
        else { return Unmanaged.passUnretained(event) }
        return Unmanaged.passRetained(newEvent)
    }

    private func shutdownForSafety(_ failure: Failure) {
        guard let mode = activeMode else { return }
        disable()
        onSafetyShutdown?(SafetyShutdown(mode: mode, failure: failure))
    }

    private func createEnglishPunctuationEvent(originalEvent: CGEvent, replacement: String) -> CGEvent? {
        // Use the original keyCode but with English character replacement
        let originalKeyCode = CGKeyCode(originalEvent.getIntegerValueField(.keyboardEventKeycode))
        
        // Create a new keyboard event using the original key code with privateState to avoid modifier pollution
        guard let source = CGEventSource(stateID: .privateState),
              let newEvent = CGEvent(keyboardEventSource: source, virtualKey: originalKeyCode, keyDown: true)
        else { 
            logger.debug { "Failed to create CGEventSource or CGEvent with keyCode: \(originalKeyCode)" }
            return nil 
        }
        
        // Set the Unicode string for the replacement character
        let unicodeString = Array(replacement.utf16)
        newEvent.keyboardSetUnicodeString(stringLength: unicodeString.count, unicodeString: unicodeString)
        
        // Copy relevant properties from the original event (but not flags to avoid modifier conflicts)
        newEvent.timestamp = originalEvent.timestamp
        newEvent.setIntegerValueField(.eventSourceUserData, value: generatedEventMarker)
        
        // Explicitly set flags to none to ensure clean character input
        newEvent.flags = []
        
        logger.debug { "Created ASCII replacement event for: '\(replacement)' using original keyCode: \(originalKeyCode)" }
        
        return newEvent
    }
    
    private func shouldReplacePunctuation(for flags: CGEventFlags) -> Bool {
        let shortcutModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]
        return flags.intersection(shortcutModifiers).isEmpty
    }

    /// Get current input source with caching to improve performance during rapid typing
    private func getCachedCurrentInputSource() -> InputSource {
        let currentTime = dependencies.now()
        
        // Return cached value if it's still valid
        if let cached = cachedInputSource, 
           currentTime - inputSourceCacheTime < inputSourceCacheTimeout {
            return cached
        }
        
        // Cache has expired or doesn't exist, fetch new value
        let currentInputSource = InputSource.getCurrentInputSource()
        cachedInputSource = currentInputSource
        inputSourceCacheTime = currentTime
        
        return currentInputSource
    }
    
}
