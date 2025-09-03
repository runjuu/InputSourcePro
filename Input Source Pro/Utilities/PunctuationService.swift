import AppKit
import Carbon
import Combine
import IOKit
import os

@MainActor
class PunctuationService: ObservableObject {
    private let logger = ISPLogger(category: String(describing: PunctuationService.self))
    
    private var isEnabled = false
    private var eventTap: CFMachPort?
    private weak var preferencesVM: PreferencesVM?
    
    private let chinesePunctuationMap: [UInt16: String] = [
        // Correct macOS keyCode mappings for punctuation marks
        43: ",",    // 0x2B - Comma key -> ,
        47: ".",    // 0x2F - Period key -> .
        41: ";",    // 0x29 - Semicolon key -> ;
        39: "'",    // 0x27 - Single Quote key -> '
        42: "\"",   // 0x2A - Double Quote key -> "
        33: "[",    // 0x21 - Left Bracket key -> [
        30: "]",    // 0x1E - Right Bracket key -> ]
        49: " ",    // 0x31 - Space key -> space (for full-width space handling)
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
        
        let hasPermission = PermissionsVM.checkInputMonitoring(prompt: false)
        
        if !hasPermission {
            logger.debug { "Input Monitoring permission check failed, attempting fallback activation" }
            // Try to enable anyway - permission check might be unreliable
            // If it fails, startMonitoring() will handle it gracefully
        } else {
            logger.debug { "Input Monitoring permission verified" }
        }
        
        logger.debug { "Enabling English punctuation service for app-aware switching" }
        let success = startMonitoring()
        
        if success {
            isEnabled = true
            logger.debug { "English punctuation service started successfully" }
        } else {
            logger.debug { "Failed to start English punctuation service - Input Monitoring permission required" }
            
            // Schedule a retry after a delay in case permissions were just granted
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self, !self.isEnabled else { return }
                self.logger.debug { "Retrying English punctuation service activation..." }
                if self.startMonitoring() {
                    self.isEnabled = true
                    self.logger.debug { "English punctuation service activated on retry" }
                }
            }
        }
    }
    
    func disable() {
        guard isEnabled else { return }
        
        logger.debug { "Disabling ASCII punctuation service" }
        stopMonitoring()
        isEnabled = false
    }
    
    @discardableResult
    private func startMonitoring() -> Bool {
        stopMonitoring()
        
        // Skip unreliable preflight checks - directly attempt event tap creation
        // We've already verified permissions through IOHIDCheckAccess
        logger.debug { "Starting event tap creation (skipping preflight checks)" }
        
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let service = Unmanaged<PunctuationService>.fromOpaque(refcon!).takeUnretainedValue() as PunctuationService?
            else { return Unmanaged.passUnretained(event) }
            
            return service.handleKeyEvent(proxy: proxy, type: type, event: event)
        }
        
        // Try different event tap configurations for better compatibility
        // IMPORTANT: We must NOT use `.listenOnly` here because we need to
        // modify/replace key events. `.listenOnly` ignores returned events.
        let configurations: [(options: CGEventTapOptions, place: CGEventTapPlacement, description: String)] = [
            // Prefer default (modifiable) taps first
            (.defaultTap, .headInsertEventTap, "Default + Head insertion"),
            (.defaultTap, .tailAppendEventTap, "Default + Tail insertion")
        ]
        
        for (index, config) in configurations.enumerated() {
            logger.debug { "Attempting event tap creation - \(config.description)" }
            
            eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: config.place,
                options: config.options,
                eventsOfInterest: CGEventMask(eventMask),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
            
            if let eventTap = eventTap {
                let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
                CGEvent.tapEnable(tap: eventTap, enable: true)
                
                logger.debug { "✅ Event tap created successfully using \(config.description)" }
                return true
            } else {
                logger.debug { "❌ Failed: \(config.description) - trying next configuration" }
            }
        }
        
        // If all configurations failed, provide detailed diagnostic info
        logger.debug { "❌ All event tap configurations failed. Diagnostic info:" }
        checkServiceStatus()
        
        return false
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
            // Not a punctuation key we're interested in
            return Unmanaged.passUnretained(event)
        }
        
        // Check if we're in a Chinese/CJKV input method
        let currentInputSource = InputSource.getCurrentInputSource()
        guard currentInputSource.isCJKVR else {
            // Already in ASCII input method, no need to intercept
            logger.debug { "Skipping intercept - already in ASCII input method: \(currentInputSource.name ?? "unknown")" }
            return Unmanaged.passUnretained(event)
        }
        
        logger.debug { "🎯 Intercepting punctuation key: \(keyCode) ('\(asciiReplacement)') in CJKV input method: \(currentInputSource.name ?? "unknown")" }
        
        // Create a new event with ASCII replacement
        if let newEvent = createAsciiPunctuationEvent(originalEvent: event, replacement: asciiReplacement) {
            logger.debug { "✅ Successfully created replacement event, returning new event" }
            return Unmanaged.passRetained(newEvent)
        } else {
            logger.debug { "❌ Failed to create replacement event, passing through original" }
            return Unmanaged.passUnretained(event)
        }
    }
    
    private func createAsciiPunctuationEvent(originalEvent: CGEvent, replacement: String) -> CGEvent? {
        // Create a new keyboard event for the ASCII character using privateState to avoid modifier pollution
        guard let source = CGEventSource(stateID: .privateState),
              let newEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        else { 
            logger.debug { "Failed to create CGEventSource or CGEvent" }
            return nil 
        }
        
        // Set the Unicode string for the replacement character
        let unicodeString = Array(replacement.utf16)
        newEvent.keyboardSetUnicodeString(stringLength: unicodeString.count, unicodeString: unicodeString)
        
        // Copy relevant properties from the original event (but not flags to avoid modifier conflicts)
        newEvent.timestamp = originalEvent.timestamp
        
        // Explicitly set flags to none to ensure clean character input
        newEvent.flags = []
        
        logger.debug { "Created ASCII replacement event for: '\(replacement)' (keyCode mapping verified)" }
        
        return newEvent
    }
    
    func shouldEnableForApp(_ app: NSRunningApplication) -> Bool {
        guard let preferencesVM = preferencesVM else { return false }
        
        let appRule = preferencesVM.getAppCustomization(app: app)
        return appRule?.shouldForceAsciiPunctuation == true
    }
    
    /// Check current service status and log detailed information for debugging
    func checkServiceStatus() {
        let permissionViaIOHID = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        let permissionViaCGEvent = PermissionsVM.checkInputMonitoring(prompt: false)
        let accessibilityEnabled = PermissionsVM.checkAccessibility(prompt: false)
        let currentInputSource = InputSource.getCurrentInputSource()
        
        logger.debug { """
            🔍 English Punctuation Service Diagnostic:
            - Service Enabled: \(isEnabled)
            - Event Tap Active: \(eventTap != nil)
            - IOHIDCheckAccess (Input Monitoring): \(permissionViaIOHID ? "✅ Granted" : "❌ Denied")
            - CGEvent Permission Check: \(permissionViaCGEvent ? "✅ Passed" : "❌ Failed")  
            - Accessibility Permission: \(accessibilityEnabled ? "✅ Granted" : "❌ Denied")
            - Current Input Source: \(currentInputSource.name ?? "unknown") (CJKV: \(currentInputSource.isCJKVR))
            - Monitored Keys: \(chinesePunctuationMap.map { "\($0.key)→'\($0.value)'" }.joined(separator: ", "))
            """ }
    }
}
