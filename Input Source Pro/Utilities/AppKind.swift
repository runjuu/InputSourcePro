import AppKit
import AXSwift
import Combine
import Foundation

@MainActor
enum AppKind {
    typealias BrowserInfo = (
        focusedElement: UIElement?,
        isFocusOnInputContainer: Bool,

        url: URL?,
        rule: BrowserRule?,
        isFocusedOnAddressBar: Bool
    )

    typealias NormalInfo = (
        focusedElement: UIElement?,
        isFocusOnInputContainer: Bool,
        windowId: String?
    )

    case normal(app: NSRunningApplication, info: NormalInfo)
    case browser(app: NSRunningApplication, info: BrowserInfo)

    func getId() -> String? {
        switch self {
        case let .normal(app, info):
            let processId = Self.instanceCacheId(
                bundleId: app.bundleId(),
                processIdentifier: app.processIdentifier
            )
            if let windowId = info.windowId, !windowId.isEmpty {
                return "\(processId)#\(windowId)"
            }
            return processId
        case let .browser(app, info):
            if !info.isFocusedOnAddressBar,
               let url = info.url,
               url != .newtab,
               let bundleId = app.bundleId(),
               let addressId = info.rule?.id() ?? url.host
            {
                return "\(bundleId)_\(addressId)"
            } else {
                return nil
            }
        }
    }

    func processInstanceCacheId() -> String? {
        switch self {
        case let .normal(app, _):
            return Self.instanceCacheId(
                bundleId: app.bundleId(),
                processIdentifier: app.processIdentifier
            )
        case .browser:
            return nil
        }
    }

    func windowCacheId() -> String? {
        switch self {
        case let .normal(_, info):
            return info.windowId
        case .browser:
            return nil
        }
    }

    static func instanceCacheId(bundleId: String?, processIdentifier: pid_t) -> String {
        if let bundleId, !bundleId.isEmpty {
            return "\(bundleId)#\(processIdentifier)"
        }
        return "pid:\(processIdentifier)"
    }

    func getApp() -> NSRunningApplication {
        switch self {
        case let .normal(app, _):
            return app
        case let .browser(app, _):
            return app
        }
    }

    func getBrowserInfo() -> BrowserInfo? {
        switch self {
        case .normal:
            return nil
        case let .browser(_, info):
            return info
        }
    }

    func isFocusOnInputContainer() -> Bool {
        switch self {
        case let .normal(_, info):
            return info.isFocusOnInputContainer
        case let .browser(_, info):
            return info.isFocusOnInputContainer
        }
    }

    func getFocusedElement() -> UIElement? {
        switch self {
        case let .normal(_, info):
            return info.focusedElement
        case let .browser(_, info):
            return info.focusedElement
        }
    }

    func isSameAppOrWebsite(with otherKind: AppKind?, detectAddressBar: Bool = false) -> Bool {
        guard let otherKind = otherKind else { return false }
        guard getApp() == otherKind.getApp() else { return false }

        switch (getBrowserInfo(), otherKind.getBrowserInfo()) {
        case (nil, nil):
            return windowCacheId() == otherKind.windowCacheId()
        case let (current?, previous?):
            if detectAddressBar,
               current.isFocusedOnAddressBar != previous.isFocusedOnAddressBar
            {
                return false
            }

            // While the address bar stays focused, URL changes reflect omnibox
            // edits or suggestions rather than navigation; treating them as
            // navigation switches input sources mid-composition (issue #99).
            if current.isFocusedOnAddressBar,
               previous.isFocusedOnAddressBar
            {
                return true
            }

            return current.url == previous.url
        default:
            return false
        }
    }
}

// MARK: - From

extension AppKind {
    static func makeBrowserInfo(
        focusedElement: UIElement?,
        isFocusOnInputContainer: Bool,
        url: URL?,
        rule: BrowserRule?,
        isFocusedOnAddressBar: Bool
    ) -> BrowserInfo? {
        // An empty omnibox can expose no web-area URL, so address-bar focus
        // alone constitutes a browser context (issue #99).
        guard url != nil || isFocusedOnAddressBar else { return nil }

        return (
            focusedElement: focusedElement,
            isFocusOnInputContainer: isFocusOnInputContainer,
            url: url,
            rule: rule,
            isFocusedOnAddressBar: isFocusedOnAddressBar
        )
    }

    static func from(_ app: NSRunningApplication?, preferencesVM: PreferencesVM) -> AppKind? {
        if let app = app {
            return .from(app, preferencesVM: preferencesVM)
        } else {
            return nil
        }
    }

    static func from(_ app: NSRunningApplication, preferencesVM: PreferencesVM) -> AppKind {
        let application = app.getApplication(preferencesVM: preferencesVM)
        let focusedElement = app.focuedUIElement(application: application)
        let isFocusOnInputContainer = UIElement.isInputContainer(focusedElement)
        let isBrowserEnabled = preferencesVM.isBrowserAndEnabled(app)

        if isBrowserEnabled {
            let isFocusOnBrowserAddress = preferencesVM.isFocusOnBrowserAddress(
                app: app,
                focusedElement: focusedElement
            )
            let browserURL = preferencesVM
                .getBrowserURL(app.bundleIdentifier, application: application)?
                .removeFragment()
            let rule = browserURL.flatMap { preferencesVM.getBrowserRule(url: $0) }

            if let browserInfo = makeBrowserInfo(
                focusedElement: focusedElement,
                isFocusOnInputContainer: isFocusOnInputContainer,
                url: browserURL,
                rule: rule,
                isFocusedOnAddressBar: isFocusOnBrowserAddress
            ) {
                return .browser(
                    app: app,
                    info: browserInfo
                )
            }
        }

        return .normal(
            app: app,
            info: (
                focusedElement,
                isFocusOnInputContainer,
                resolveWindowCacheToken(app: app, application: application)
            )
        )
    }

    static func resolveWindowCacheToken(app: NSRunningApplication, application: Application?) -> String? {
        if let cg = CGWindowIdentity.cacheToken(forPid: app.processIdentifier) {
            return cg
        }
        return focusedWindowCacheToken(application: application)
    }

    static func focusedWindowCacheToken(application: Application?) -> String? {
        guard AXIsProcessTrusted(),
              let application,
              let window: UIElement = try? application.attribute(.focusedWindow)
        else { return nil }

        if let number = axWindowNumber(window) {
            return "w\(number)"
        }

        if let title: String = try? window.attribute(.title) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let slug = trimmed
                    .replacingOccurrences(of: "#", with: "_")
                    .prefix(96)
                return "t\(slug)"
            }
        }

        return nil
    }

    private static func axWindowNumber(_ window: UIElement) -> Int? {
        if let number: Int = try? window.attribute("AXWindowNumber") {
            return number
        }
        if let number: NSNumber = try? window.attribute("AXWindowNumber") {
            return number.intValue
        }
        return nil
    }
}
