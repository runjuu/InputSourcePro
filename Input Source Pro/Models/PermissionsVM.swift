import AppKit
import Combine
import IOKit

@MainActor
final class PermissionsVM: ObservableObject {
    @discardableResult
    static func checkAccessibility(prompt: Bool) -> Bool {
        let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        return AXIsProcessTrustedWithOptions([checkOptPrompt: prompt] as CFDictionary?)
    }

    @discardableResult
    static func checkInputMonitoring(prompt: Bool) -> Bool {
        // Multi-strategy permission checking for better reliability
        
        // Strategy 1: IOHIDCheckAccess (most reliable)
        if checkInputMonitoringViaIOHID() {
            return true
        }
        
        // Strategy 2: CGEvent.tapCreate (traditional method)
        if checkInputMonitoringViaCGEvent(prompt: prompt) {
            return true
        }
        
        // Strategy 3: Delayed retry for timing-sensitive cases
        if !prompt {
            // For non-prompt calls, try a brief delay and retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Retry the check after a brief delay
                _ = checkInputMonitoringViaCGEvent(prompt: false)
            }
        }
        
        return false
    }
    
    private static func checkInputMonitoringViaIOHID() -> Bool {
        // Use IOHIDCheckAccess for reliable permission checking
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        return access == kIOHIDAccessTypeGranted
    }
    
    private static func checkInputMonitoringViaCGEvent(prompt: Bool) -> Bool {
        let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: prompt ? .defaultTap : .listenOnly,
            eventsOfInterest: 1,
            callback: { _, _, event, _ in
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )
        
        let hasPermission = (eventTap != nil)
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        return hasPermission
    }

    @Published var isAccessibilityEnabled = PermissionsVM.checkAccessibility(prompt: false)
    @Published var isInputMonitoringEnabled = PermissionsVM.checkInputMonitoring(prompt: false)

    init() {
        watchAccessibilityChange()
        watchInputMonitoringChange()
    }

    private func watchAccessibilityChange() {
        guard !isAccessibilityEnabled else { return }

        Timer
            .interval(seconds: 1)
            .map { _ in Self.checkAccessibility(prompt: false) }
            .filter { $0 }
            .first()
            .assign(to: &$isAccessibilityEnabled)
    }

    private func watchInputMonitoringChange() {
        guard !isInputMonitoringEnabled else { return }

        Timer
            .interval(seconds: 1)
            .map { _ in Self.checkInputMonitoring(prompt: false) }
            .filter { $0 }
            .first()
            .assign(to: &$isInputMonitoringEnabled)
    }
}
