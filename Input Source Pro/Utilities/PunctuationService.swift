import AppKit
import Carbon
import Combine
import os

@MainActor
class PunctuationService: ObservableObject {
    private let logger = ISPLogger(category: String(describing: PunctuationService.self))
    
    private var isEnabled = false
    private var eventTap: CFMachPort?
    private weak var preferencesVM: PreferencesVM?
    
    private let chinesePunctuationMap: [UInt16: String] = [
        // Common punctuation keys that should be ASCII in English contexts
        0x2F: ",",    // Comma key -> ,
        0x2E: ".",    // Period key -> .
        0x29: ";",    // Semicolon key -> ;
        0x27: "'",    // Quote key -> '
        0x2A: "\"",   // Double quote -> "
        0x21: "[",    // Left bracket -> [
        0x1E: "]",    // Right bracket -> ]
        0x31: " ",    // Space key -> space (for full-width space handling)
    ]
    
    init(preferencesVM: PreferencesVM) {
        self.preferencesVM = preferencesVM
    }
    
    deinit {
        // Note: stopMonitoring() will be called by disable() before deallocation
        if let eventTap = eventTap {
            CFMachPortInvalidate(eventTap)
        }
    }
    
    func enable() {
        guard !isEnabled else { return }
        
        guard PermissionsVM.checkInputMonitoring(prompt: false) else {
            logger.debug { "Input Monitoring permission required for ASCII punctuation" }
            return
        }
        
        logger.debug { "Enabling ASCII punctuation service" }
        startMonitoring()
        isEnabled = true
    }
    
    func disable() {
        guard isEnabled else { return }
        
        logger.debug { "Disabling ASCII punctuation service" }
        stopMonitoring()
        isEnabled = false
    }
    
    private func startMonitoring() {
        stopMonitoring()
        
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let service = Unmanaged<PunctuationService>.fromOpaque(refcon!).takeUnretainedValue() as PunctuationService?
            else { return Unmanaged.passUnretained(event) }
            
            return service.handleKeyEvent(proxy: proxy, type: type, event: event)
        }
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        if let eventTap = eventTap {
            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            
            logger.debug { "Event tap created successfully" }
        } else {
            logger.debug { "ERROR: Failed to create event tap - accessibility permissions may be required" }
        }
    }
    
    private func stopMonitoring() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
            logger.debug { "Event tap disabled" }
        }
    }
    
    private func handleKeyEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent> {
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        
        // Check if this is a punctuation key we want to intercept
        guard let asciiReplacement = chinesePunctuationMap[UInt16(keyCode)] else {
            return Unmanaged.passUnretained(event)
        }
        
        // Check if we're in a Chinese/CJKV input method
        let currentInputSource = InputSource.getCurrentInputSource()
        guard currentInputSource.isCJKVR else {
            // Already in ASCII input method, no need to intercept
            return Unmanaged.passUnretained(event)
        }
        
        logger.debug { "Intercepting punctuation key: \(keyCode) in CJKV input method" }
        
        // Create a new event with ASCII replacement
        if let newEvent = createAsciiPunctuationEvent(originalEvent: event, replacement: asciiReplacement) {
            return Unmanaged.passRetained(newEvent)
        }
        
        return Unmanaged.passUnretained(event)
    }
    
    private func createAsciiPunctuationEvent(originalEvent: CGEvent, replacement: String) -> CGEvent? {
        // Create a new keyboard event for the ASCII character
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let newEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        else { return nil }
        
        // Set the Unicode string for the replacement
        let unicodeString = Array(replacement.utf16)
        newEvent.keyboardSetUnicodeString(stringLength: unicodeString.count, unicodeString: unicodeString)
        
        // Copy relevant properties from the original event
        newEvent.flags = originalEvent.flags
        newEvent.timestamp = originalEvent.timestamp
        
        logger.debug { "Created ASCII replacement event for: \(replacement)" }
        
        return newEvent
    }
    
    func shouldEnableForApp(_ app: NSRunningApplication) -> Bool {
        guard let preferencesVM = preferencesVM else { return false }
        
        let appRule = preferencesVM.getAppCustomization(app: app)
        return appRule?.shouldForceAsciiPunctuation == true
    }
}

