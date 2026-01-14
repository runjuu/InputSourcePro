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
    
    // Performance optimization: Cache input source state to reduce system calls
    private var cachedInputSource: InputSource?
    private var inputSourceCacheTime: TimeInterval = 0
    private let inputSourceCacheTimeout: TimeInterval = 0.5 // Cache for 500ms
    
    private let cjkvToEnglishPunctuationMap: [UInt16: (normal: String, shifted: String)] = [
        43: (",", "<"),    // 0x2B - Comma key
        47: (".", ">"),    // 0x2F - Period key
        41: (";", ":"),    // 0x29 - Semicolon key
        39: ("'", "\""),   // 0x27 - Quote key
        42: ("\\", "|"),   // 0x2A - Backslash key
        33: ("[", "{"),    // 0x21 - Left Bracket key
        30: ("]", "}")     // 0x1E - Right Bracket key
    ]
    
    init(preferencesVM: PreferencesVM) {
        self.preferencesVM = preferencesVM
    }
    
    deinit {
        // Ensure cleanup happens regardless of disable() being called
        // Note: Direct cleanup since deinit is not on MainActor
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
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
            // Service will remain disabled until next enable() call or permission state change
        }
    }
    
    func disable() {
        guard isEnabled else { return }
        
        logger.debug { "Disabling English punctuation service" }
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
            guard let refcon = refcon,
                  let service = Unmanaged<PunctuationService>.fromOpaque(refcon).takeUnretainedValue() as? PunctuationService
            else { 
                return Unmanaged.passUnretained(event) 
            }
            
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
        #if DEBUG
        checkServiceStatus()
        #endif
        
        return false
    }
    
    private func stopMonitoring() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
            logger.debug { "Event tap disabled and invalidated" }
        }
        
        // Clear cached input source to ensure fresh state on next enable
        cachedInputSource = nil
        inputSourceCacheTime = 0
    }
    
    private func handleKeyEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent> {
        // Handle event tap being disabled (can happen if permissions are revoked)
        guard isEnabled else {
            return Unmanaged.passUnretained(event)
        }
        
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        
        // Check if this is a punctuation key we want to intercept
        guard let mapping = cjkvToEnglishPunctuationMap[UInt16(keyCode)] else {
            // Not a punctuation key we're interested in
            return Unmanaged.passUnretained(event)
        }
        
        let englishReplacement = event.flags.contains(.maskShift) ? mapping.shifted : mapping.normal
        
        // Check if we're in a Chinese/CJKV input method (with caching for performance)
        let currentInputSource = getCachedCurrentInputSource()
        guard currentInputSource.isCJKVR else {
            // Already in English/ASCII input method, no need to intercept
            return Unmanaged.passUnretained(event)
        }
        
        logger.debug { "🎯 Intercepting punctuation key: \(keyCode) ('\(englishReplacement)') in CJKV input method: \(currentInputSource.name)" }
        
        // Create a new event with English replacement
        if let newEvent = createEnglishPunctuationEvent(originalEvent: event, replacement: englishReplacement) {
            logger.debug { "✅ Successfully created replacement event, returning new event" }
            return Unmanaged.passRetained(newEvent)
        } else {
            logger.debug { "❌ Failed to create replacement event, passing through original" }
            return Unmanaged.passUnretained(event)
        }
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
        
        // Explicitly set flags to none to ensure clean character input
        newEvent.flags = []
        
        logger.debug { "Created ASCII replacement event for: '\(replacement)' using original keyCode: \(originalKeyCode)" }
        
        return newEvent
    }
    
    func shouldEnableForApp(_ app: NSRunningApplication) -> Bool {
        guard let preferencesVM = preferencesVM else { return false }
        
        let appRule = preferencesVM.getAppCustomization(app: app)
        return appRule?.shouldForceEnglishPunctuation == true
    }
    
    /// Get current input source with caching to improve performance during rapid typing
    private func getCachedCurrentInputSource() -> InputSource {
        let currentTime = CACurrentMediaTime()
        
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
            - Current Input Source: \(currentInputSource.name) (CJKV: \(currentInputSource.isCJKVR))
            - Monitored Keys: \(cjkvToEnglishPunctuationMap.map { "\($0.key)→'\($0.value.normal)'/'\($0.value.shifted)'" }.joined(separator: ", "))
            """ }
    }
}
