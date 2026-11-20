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
        isFocusOnInputContainer: Bool
    )

    typealias TerminalInfo = (
        focusedElement: UIElement?,
        isFocusOnInputContainer: Bool,

        program: TerminalProgram,
        rule: TerminalRule?
    )

    case normal(app: NSRunningApplication, info: NormalInfo)
    case browser(app: NSRunningApplication, info: BrowserInfo)
    case terminal(app: NSRunningApplication, info: TerminalInfo)
    case controlledShell(app: NSRunningApplication, tty: String, info: NormalInfo)

    func getId() -> String? {
        switch self {
        case let .normal(app, _):
            return app.bundleId()
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
        case let .terminal(app, info):
            guard let bundleId = app.bundleId() else { return nil }
            return "\(bundleId)_\(info.rule?.id.uuidString ?? info.program.id)"
        case let .controlledShell(app, tty, _):
            return app.bundleId().map { "\($0)_shell:\(tty)" }
        }
    }

    func getApp() -> NSRunningApplication {
        switch self {
        case let .normal(app, _), let .controlledShell(app, _, _):
            return app
        case let .browser(app, _):
            return app
        case let .terminal(app, _):
            return app
        }
    }

    func getBrowserInfo() -> BrowserInfo? {
        switch self {
        case .normal, .terminal, .controlledShell:
            return nil
        case let .browser(_, info):
            return info
        }
    }

    func getTerminalInfo() -> TerminalInfo? {
        switch self {
        case .normal, .browser, .controlledShell:
            return nil
        case let .terminal(_, info):
            return info
        }
    }

    var controlledShellTTY: String? {
        guard case let .controlledShell(_, tty, _) = self else { return nil }
        return tty
    }

    func isFocusOnInputContainer() -> Bool {
        switch self {
        case let .normal(_, info), let .controlledShell(_, _, info):
            return info.isFocusOnInputContainer
        case let .browser(_, info):
            return info.isFocusOnInputContainer
        case let .terminal(_, info):
            return info.isFocusOnInputContainer
        }
    }

    func getFocusedElement() -> UIElement? {
        switch self {
        case let .normal(_, info), let .controlledShell(_, _, info):
            return info.focusedElement
        case let .browser(_, info):
            return info.focusedElement
        case let .terminal(_, info):
            return info.focusedElement
        }
    }

    func isSameAppOrWebsite(with otherKind: AppKind?, detectAddressBar: Bool = false) -> Bool {
        guard let otherKind = otherKind else { return false }
        guard getApp() == otherKind.getApp() else { return false }
        guard getTerminalInfo()?.program == otherKind.getTerminalInfo()?.program else { return false }
        guard controlledShellTTY == otherKind.controlledShellTTY else { return false }

        switch (getBrowserInfo(), otherKind.getBrowserInfo()) {
        case (nil, nil):
            return true
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

        // Programs with a rule and panes controlled through `isp:` have their own context.
        // Other programs and shell prompts share the terminal's App Rule.
        if let terminal = Terminal(app), preferencesVM.isTerminalEnabled(terminal) {
            if let program = preferencesVM.terminalPrograms[terminal] {
                let rule = preferencesVM.getTerminalRule(program: program)
                if rule != nil || program.tty.map { preferencesVM.terminalControl.isControlled($0) } == true {
                    return .terminal(
                        app: app,
                        info: (
                            focusedElement: focusedElement,
                            isFocusOnInputContainer: isFocusOnInputContainer,
                            program: program,
                            rule: rule
                        )
                    )
                }
            } else if let tty = preferencesVM.terminalTTYs[terminal], preferencesVM.terminalControl.isControlled(tty) {
                return .controlledShell(app: app, tty: tty, info: (focusedElement, isFocusOnInputContainer))
            }
        }

        return .normal(
            app: app,
            info: (
                focusedElement,
                isFocusOnInputContainer
            )
        )
    }
}
