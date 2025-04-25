import AppKit
import Combine
import Foundation

private func isValidWindow(windowAlpha: CGFloat, windowBounds: CGRect) -> Bool {
    // ----------------------------------------
    // Ignore windows.
    //
    // There are well known windows that we need ignore:
    //   * Google Chrome has some transparent windows.
    //   * Google Chrome's status bar which is shown when mouse cursor is on links.
    //   * Karabiner's status message windows.
    //
    // Do not forget to treat this situations:
    //   * Do not ignore menubar.
    //   * Do not ignore popup menu.
    //   * Do not ignore alert window on web browsers.
    //   * Do not ignore iTunes's preferences window which has some special behavior.

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
}

private func getWindowInfo(processIdentifier: pid_t) -> WindowInfo? {
    guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, kCGNullWindowID) as? [[String: Any]]
    else { return nil }

    for window in windows {
        // Target windows:
        //   * frontmostApplication
        //   * loginwindow (shutdown dialog)
        //   * Launchpad
        //
        // Limitations:
        //   * There is not reliable way to judge whether Dashboard is shown.

        guard
            let windowOwnerPID = window["kCGWindowOwnerPID"] as? pid_t,
            let windowLayer = window["kCGWindowLayer"] as? Int,
            let windowAlpha = window["kCGWindowAlpha"] as? CGFloat,
            let windowBounds = CGRect(dictionaryRepresentation: window["kCGWindowBounds"] as! CFDictionary)
        else { continue }

        guard windowOwnerPID == processIdentifier
        else { continue }

        if isValidWindow(windowAlpha: windowAlpha, windowBounds: windowBounds) {
            return .init(bounds: windowBounds, layer: windowLayer)
        }
    }

    return nil
}
