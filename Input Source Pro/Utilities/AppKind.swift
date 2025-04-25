import AppKit
import AXSwift
import Combine
import Foundation

@MainActor
enum AppKind {
    typealias BrowserInfo = (
        focusedElement: UIElement?,
        isFocusOnInputContainer: Bool,

        url: URL,
        rule: BrowserRule?,
        isFocusedOnAddressBar: Bool
    )

    typealias NormalInfo = (
        focusedElement: UIElement?,
        isFocusOnInputContainer: Bool
    )

    case normal(app: NSRunningApplication, info: NormalInfo)
    case browser(app: NSRunningApplication, info: BrowserInfo)

    func getId() -> String? {
        switch self {
        case let .normal(app, _):
            return app.bundleId()
        case let .browser(app, info):
            if !info.isFocusedOnAddressBar,
               info.url != .newtab,
               let bundleId = app.bundleId(),
               let addressId = info.rule?.id() ?? info.url.host
            {
                return "\(bundleId)_\(addressId)"
            } else {
                return nil
            }
        }
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

        let isSameAddress = getBrowserInfo()?.url == otherKind.getBrowserInfo()?.url
        let isSameAddressBar = getBrowserInfo()?.isFocusedOnAddressBar == otherKind.getBrowserInfo()?.isFocusedOnAddressBar

        return detectAddressBar ? (isSameAddressBar && isSameAddress) : isSameAddress
    }
}

// MARK: - From

extension AppKind {
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

        if let url = preferencesVM.getBrowserURL(app.bundleIdentifier, application: application)?.removeFragment() {
            let rule = preferencesVM.getBrowserRule(url: url)
            let isFocusOnBrowserAddress = preferencesVM.isFocusOnBrowserAddress(app: app, focusedElement: focusedElement)

            return .browser(
                app: app,
                info: (
                    focusedElement,
                    isFocusOnInputContainer,
                    url,
                    rule,
                    isFocusOnBrowserAddress
                )
            )
        } else {
            return .normal(
                app: app,
                info: (
                    focusedElement,
                    isFocusOnInputContainer
                )
            )
        }
    }
}
