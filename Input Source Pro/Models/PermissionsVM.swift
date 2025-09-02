import AppKit
import Combine

@MainActor
final class PermissionsVM: ObservableObject {
    @discardableResult
    static func checkAccessibility(prompt: Bool) -> Bool {
        let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        return AXIsProcessTrustedWithOptions([checkOptPrompt: prompt] as CFDictionary?)
    }

    @discardableResult
    static func checkInputMonitoring(prompt: Bool) -> Bool {
        let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
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
