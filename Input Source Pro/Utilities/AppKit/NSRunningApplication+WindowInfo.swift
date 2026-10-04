import AppKit
import AXSwift
import Combine
import Foundation

private func isValidWindow(windowAlpha: CGFloat, windowBounds: CGRect) -> Bool {
    // Ignore transparent windows.
    let transparentThreshold: CGFloat = 0.001

    if windowAlpha < transparentThreshold {
        return false
    }

    // Ignore small windows. (For example, a status bar of Google Chrome.)
    let windowSizeThreshold: CGFloat = 40
    if windowBounds.size.width < windowSizeThreshold ||
        windowBounds.size.height < windowSizeThreshold
    {
        return false
    }

    // Xcode and some app have some invisable window at fullscreen mode
    if let screen = NSScreen.getScreenInclude(rect: windowBounds),
       windowBounds.width == screen.frame.width,
       windowBounds.height < 70
    {
        return false
    }

    return true
}

extension NSRunningApplication {
    static func getWindowInfoPublisher(processIdentifier: pid_t) -> AnyPublisher<WindowInfo?, Never> {
        AnyPublisher.create { observer in
            let thread = Thread(block: {
                observer.send(getWindowInfo(processIdentifier: processIdentifier))
                observer.send(completion: .finished)
            })

            thread.start()

            return AnyCancellable { thread.cancel() }
        }
        .receive(on: DispatchQueue.main)
        .eraseToAnyPublisher()
    }

    func getWindowInfoPublisher() -> AnyPublisher<WindowInfo?, Never> {
        return NSRunningApplication.getWindowInfoPublisher(processIdentifier: processIdentifier)
    }
}

struct WindowInfo {
    let bounds: CGRect
    let layer: Int
    var number: CGWindowID = 0

    static func preferred(in windows: [WindowInfo], focusedBounds: CGRect?) -> WindowInfo? {
        if let focusedBounds,
           let focused = windows.first(where: { window in
               abs(window.bounds.minX - focusedBounds.minX) <= 1 &&
                   abs(window.bounds.minY - focusedBounds.minY) <= 1 &&
                   abs(window.bounds.width - focusedBounds.width) <= 1 &&
                   abs(window.bounds.height - focusedBounds.height) <= 1
           }) {
            return focused
        }

        // Input-method overlays can belong to the editor's PID. Prefer a normal
        // app window; keep the floating-only fallback for launchers such as Raycast.
        return windows.first(where: { $0.layer == 0 }) ?? windows.first
    }
}

private func focusedWindowBounds(processIdentifier: pid_t) -> CGRect? {
    guard AXIsProcessTrusted(), let application = Application(forProcessID: processIdentifier) else { return nil }
    AXUIElementSetMessagingTimeout(application.element, 0.15)

    for attribute in [AXSwift.Attribute.focusedWindow, .mainWindow] {
        do {
            guard let window: UIElement = try application.attribute(attribute) else { continue }
            AXUIElementSetMessagingTimeout(window.element, 0.15)
            guard let subrole = try window.subrole(),
                  [.standardWindow, .dialog, .systemDialog].contains(subrole),
                  let origin: CGPoint = try window.attribute(.position),
                  let size: CGSize = try window.attribute(.size)
            else { continue }

            return NSScreen.convertFromQuartz(CGRect(origin: origin, size: size))
        } catch {
            IndicatorDiagnostics.record("window.AXUnavailable pid=\(processIdentifier) attribute=\(attribute) error=\(error)")
            // A hung application should not incur a second messaging timeout.
            if error as? AXError == .cannotComplete { return nil }
        }
    }
    return nil
}

private func getWindowInfo(processIdentifier: pid_t) -> WindowInfo? {
    guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, kCGNullWindowID) as? [[String: Any]]
    else { return nil }

    let focusedBounds = focusedWindowBounds(processIdentifier: processIdentifier)
    let candidates: [WindowInfo] = windows.compactMap { window in
        guard let windowOwnerPID = window[kCGWindowOwnerPID as String] as? pid_t,
              windowOwnerPID == processIdentifier,
              let layer = window[kCGWindowLayer as String] as? Int,
              let alpha = window[kCGWindowAlpha as String] as? CGFloat,
              let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
              let cocoaBounds = NSScreen.convertFromQuartz(bounds),
              isValidWindow(windowAlpha: alpha, windowBounds: cocoaBounds)
        else { return nil }

        return WindowInfo(bounds: cocoaBounds, layer: layer,
                          number: window[kCGWindowNumber as String] as? CGWindowID ?? 0)
    }

    let selected = WindowInfo.preferred(in: candidates, focusedBounds: focusedBounds)
    IndicatorDiagnostics.record("window.selected pid=\(processIdentifier) focusedBounds=\(String(describing: focusedBounds)) candidates=\(candidates) selected=\(String(describing: selected))")
    return selected
}
