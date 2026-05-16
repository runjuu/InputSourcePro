import AppKit
import Foundation

extension PreferencesVM {
    @discardableResult
    func addAppCustomization(_ app: NSRunningApplication) -> AppRule? {
        guard let url = app.bundleURL ?? app.executableURL,
              let bundleId = app.bundleId()
        else { return nil }

        return addAppCustomization(url, bundleId: bundleId)
    }

    func addAppCustomization(_ url: URL, bundleId: String) -> AppRule {
        if let appCustomization = getAppCustomization(bundleId: bundleId) {
            return appCustomization
        }

        let appCustomization = AppRule(context: container.viewContext)

        appCustomization.createdAt = Date()
        appCustomization.url = url
        appCustomization.bundleId = url.bundleId()
        appCustomization.bundleName = FileManager.default.displayName(atPath: url.path)

        if saveContext() {
            notifyRuntimeRulesChanged()
        }

        return appCustomization
    }

    func removeAppCustomization(_ appCustomization: AppRule) {
        container.viewContext.delete(appCustomization)
        if saveContext() {
            notifyRuntimeRulesChanged()
        }
    }

    func setForceKeyboard(_ appCustomization: AppRule?, _ inputSourceId: String?) {
        guard let appCustomization = appCustomization else { return }

        if saveContext({
            appCustomization.inputSourceId = inputSourceId
        }) {
            notifyRuntimeRulesChanged()
        }
    }

    func setDoRestoreKeyboard(_ appCustomization: AppRule?, _ doRestoreKeyboard: Bool) {
        guard let appCustomization = appCustomization else { return }

        if saveContext({
            appCustomization.doRestoreKeyboard = doRestoreKeyboard
        }) {
            notifyRuntimeRulesChanged()
        }
    }

    func setDoNotRestoreKeyboard(_ appCustomization: AppRule?, _ doNotRestoreKeyboard: Bool) {
        guard let appCustomization = appCustomization else { return }

        if saveContext({
            appCustomization.doNotRestoreKeyboard = doNotRestoreKeyboard
        }) {
            notifyRuntimeRulesChanged()
        }
    }

    func setHideIndicator(_ appCustomization: AppRule?, _ hideIndicator: Bool) {
        guard let appCustomization = appCustomization else { return }

        if saveContext({
            appCustomization.hideIndicator = hideIndicator
        }) {
            notifyRuntimeRulesChanged()
        }
    }

    func setForceEnglishPunctuation(_ appCustomization: AppRule?, _ forceEnglishPunctuation: Bool) {
        guard let appCustomization = appCustomization else { return }

        if saveContext({
            appCustomization.forceEnglishPunctuation = forceEnglishPunctuation
        }) {
            notifyRuntimeRulesChanged()
        }
    }

    func setFunctionKeyMode(_ appCustomization: AppRule?, _ mode: FKeyMode?) {
        guard let appCustomization = appCustomization else { return }

        if saveContext({
            appCustomization.functionKeyMode = mode
        }) {
            notifyRuntimeRulesChanged()
        }
    }

    func getAppCustomization(app: NSRunningApplication) -> AppRule? {
        return getAppCustomization(bundleId: app.bundleId())
    }

    func getAppCustomization(bundleId: String?) -> AppRule? {
        guard let bundleId = bundleId else { return nil }

        let request = AppRule.fetchRequest()

        request.predicate = NSPredicate(format: "bundleId == %@", bundleId)

        do {
            return try container.viewContext.fetch(request).first
        } catch {
            print("getAppCustomization(bundleId) error: \(error.localizedDescription)")
            return nil
        }
    }

    func cleanRemovedAppCustomizationIfNeed() {
        guard preferences.prevInstalledBuildVersion < 308 else { return }

        let request = AppRule.fetchRequest()

        request.predicate = NSPredicate(format: "removed == %@", "1")

        do {
            let appRules = try container.viewContext.fetch(request)
            appRules.forEach { removeAppCustomization($0) }
        } catch {
            print("cleanRemovedAppCustomization error: \(error.localizedDescription)")
        }
    }
}
