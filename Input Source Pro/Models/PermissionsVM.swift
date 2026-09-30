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
        if prompt {
            return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        } else {
            let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
            return access == kIOHIDAccessTypeGranted
        }
    }

    @Published var isAccessibilityEnabled: Bool
    @Published var isInputMonitoringEnabled: Bool

    private let accessibilityCheck: @MainActor () -> Bool
    private let inputMonitoringCheck: @MainActor () -> Bool
    private var activationSubscription: AnyCancellable?

    init(
        accessibilityCheck: @escaping @MainActor () -> Bool = { PermissionsVM.checkAccessibility(prompt: false) },
        inputMonitoringCheck: @escaping @MainActor () -> Bool = { PermissionsVM.checkInputMonitoring(prompt: false) },
        notificationCenter: NotificationCenter = .default
    ) {
        self.accessibilityCheck = accessibilityCheck
        self.inputMonitoringCheck = inputMonitoringCheck
        isAccessibilityEnabled = accessibilityCheck()
        isInputMonitoringEnabled = inputMonitoringCheck()
        watchAccessibilityChange()
        watchInputMonitoringChange()
        activationSubscription = notificationCenter.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let accessibilityEnabled = accessibilityCheck()
        let inputMonitoringEnabled = inputMonitoringCheck()
        if isAccessibilityEnabled != accessibilityEnabled {
            isAccessibilityEnabled = accessibilityEnabled
        }
        if isInputMonitoringEnabled != inputMonitoringEnabled {
            isInputMonitoringEnabled = inputMonitoringEnabled
        }
    }

    private func watchAccessibilityChange() {
        guard !isAccessibilityEnabled else { return }

        Timer
            .interval(seconds: 1)
            .map { [accessibilityCheck] _ in accessibilityCheck() }
            .filter { $0 }
            .first()
            .assign(to: &$isAccessibilityEnabled)
    }

    private func watchInputMonitoringChange() {
        guard !isInputMonitoringEnabled else { return }

        Timer
            .interval(seconds: 1)
            .map { [inputMonitoringCheck] _ in inputMonitoringCheck() }
            .filter { $0 }
            .first()
            .assign(to: &$isInputMonitoringEnabled)
    }
}
