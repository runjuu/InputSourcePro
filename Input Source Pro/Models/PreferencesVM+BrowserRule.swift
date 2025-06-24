import AppKit
import AXSwift
import Foundation

extension PreferencesVM {
    func addBrowserRule(
        type: BrowserRuleType,
        value: String,
        sample: String,
        inputSourceId: String,
        hideIndicator: Bool,
        keyboardRestoreStrategy: KeyboardRestoreStrategy?
    ) {
        let rule = BrowserRule(context: container.viewContext)

        rule.createdAt = Date()
        rule.type = type
        rule.value = value
        rule.sample = sample
        rule.inputSourceId = inputSourceId
        rule.keyboardRestoreStrategyRaw = keyboardRestoreStrategy?.rawValue
        rule.hideIndicator = hideIndicator
        rule.disabled = false

        saveContext()
    }

    func deleteBrowserRule(_ rule: BrowserRule) {
        container.viewContext.delete(rule)
        saveContext()
    }

    func updateBrowserRule(
        _ rule: BrowserRule,
        type: BrowserRuleType,
        value: String,
        sample: String,
        inputSourceId: String,
        hideIndicator: Bool,
        keyboardRestoreStrategy: KeyboardRestoreStrategy?
    ) {
        saveContext {
            rule.type = type
            rule.value = value
            rule.sample = sample
            rule.inputSourceId = inputSourceId
            rule.hideIndicator = hideIndicator
            rule.keyboardRestoreStrategyRaw = keyboardRestoreStrategy?.rawValue
        }
    }

    func toggleBrowserRule(_ rule: BrowserRule) {
        saveContext {
            rule.disabled.toggle()
        }
    }

    private func getBrowserRules() -> [BrowserRule] {
        let request = NSFetchRequest<BrowserRule>(entityName: "BrowserRule")

        do {
            return try container.viewContext.fetch(request)
        } catch {
            print("getBrowserRules() error: \(error.localizedDescription)")
            return []
        }
    }

    func getBrowserRule(url: URL) -> BrowserRule? {
        return getBrowserRules().first { $0.validate(url: url) }
    }
}

extension PreferencesVM {
    var isNeedToDetectBrowserTabChanges: Bool {
        guard preferences.isEnhancedModeEnabled else { return false }

        return Browser.allCases.contains(where: isBrowserEnabled)
    }

    func isBrowserAndEnabled(_ app: NSRunningApplication) -> Bool {
        guard let browser = NSApplication.getBrowser(app)
        else { return false }

        return isBrowserEnabled(browser)
    }

    func isBrowserEnabled(_ browser: Browser) -> Bool {
        switch browser {
        case .Safari:
            return preferences.isEnableURLSwitchForSafari
        case .SafariTechnologyPreview:
            return preferences.isEnableURLSwitchForSafariTechnologyPreview
        case .Chrome:
            return preferences.isEnableURLSwitchForChrome
        case .Chromium:
            return preferences.isEnableURLSwitchForChromium
        case .Arc:
            return preferences.isEnableURLSwitchForArc
        case .Edge:
            return preferences.isEnableURLSwitchForEdge
        case .Brave:
            return preferences.isEnableURLSwitchForBrave
        case .BraveBeta:
            return preferences.isEnableURLSwitchForBraveBeta
        case .BraveNightly:
            return preferences.isEnableURLSwitchForBraveNightly
        case .Vivaldi:
            return preferences.isEnableURLSwitchForVivaldi
        case .Opera:
            return preferences.isEnableURLSwitchForOpera
        case .Thorium:
            return preferences.isEnableURLSwitchForThorium
        case .Firefox:
            return preferences.isEnableURLSwitchForFirefox
        case .FirefoxDeveloperEdition:
            return preferences.isEnableURLSwitchForFirefoxDeveloperEdition
        case .FirefoxNightly:
            return preferences.isEnableURLSwitchForFirefoxNightly
        case .Zen:
            return preferences.isEnableURLSwitchForZen
        case .Dia:
            return preferences.isEnableURLSwitchForDia
        }
    }

    func getBrowserInfo(app: NSRunningApplication) -> (url: URL, rule: BrowserRule?)? {
        guard let url = getBrowserURL(app.bundleIdentifier, application: Application(app)) else { return nil }

        return (url, getBrowserRule(url: url))
    }
}
