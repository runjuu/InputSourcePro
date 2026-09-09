import AppKit
import ApplicationServices

extension PreferencesVM {
    func appNeedCacheKeyboard(_ appKind: AppKind) -> Bool {
        if SystemChrome.shouldNeverCache(appKind.getApp().bundleIdentifier) {
            return false
        }

        if forcedKeyboard(for: appKind) != nil {
            return false
        }

        if let browserRule = appKind.getBrowserInfo()?.rule,
           let keyboardRestoreStrategy = browserRule.keyboardRestoreStrategy
        {
            switch keyboardRestoreStrategy {
            case .RestorePreviouslyUsedOne:
                return true
            case .UseDefaultKeyboardInstead:
                return false
            }
        }

        let appRule = getAppCustomization(app: appKind.getApp())

        if preferences.isRestorePreviouslyUsedInputSource,
           appRule?.doNotRestoreKeyboard != true
        {
            return true
        }

        if !preferences.isRestorePreviouslyUsedInputSource,
           appRule?.doRestoreKeyboard == true
        {
            return true
        }

        return false
    }

    func forcedKeyboard(for appKind: AppKind) -> InputSource? {
        if let inputSource = appKind.getBrowserInfo()?.rule?.forcedKeyboard {
            return inputSource
        }
        return getAppCustomization(app: appKind.getApp())?.forcedKeyboard
    }

    func cacheKeyboardFor(_ appKind: AppKind, keyboard: InputSource) {
        if SystemChrome.shouldNeverCache(appKind.getApp().bundleIdentifier) {
            ISPFileLog.event(
                "cache-skip",
                "chrome \(appKind.getApp().bundleIdentifier ?? "nil")",
                includeSnapshot: false
            )
            return
        }

        if forcedKeyboard(for: appKind) != nil {
            appKeyboardCache.remove(appKind)
            ISPFileLog.event(
                "cache-skip",
                "forced \(appKind.getApp().bundleIdentifier ?? "nil")",
                includeSnapshot: false
            )
            return
        }

        if appNeedCacheKeyboard(appKind) {
            appKeyboardCache.save(appKind, keyboard: keyboard)
            ISPFileLog.event(
                "cache-save",
                "\(appKind.getId() ?? appKind.getApp().bundleIdentifier ?? "?") → \(keyboard.persistentIdentifier)",
                includeSnapshot: false
            )
        }
    }

    func rememberKeyboardOnLeave(for appKind: AppKind, keyboard: InputSource) {
        if SystemChrome.shouldNeverCache(appKind.getApp().bundleIdentifier) {
            return
        }

        if forcedKeyboard(for: appKind) != nil {
            appKeyboardCache.remove(appKind)
            ISPFileLog.event(
                "cache-skip",
                "leave-forced \(appKind.getApp().bundleIdentifier ?? "?")",
                includeSnapshot: false
            )
            return
        }

        guard appNeedCacheKeyboard(appKind) else {
            ISPFileLog.event(
                "cache-skip",
                "leave \(appKind.getApp().bundleIdentifier ?? "?") restore-disabled",
                includeSnapshot: false
            )
            return
        }

        appKeyboardCache.save(appKind, keyboard: keyboard)
        ISPFileLog.event(
            "cache-leave",
            "\(appKind.getId() ?? appKind.getApp().bundleIdentifier ?? "?") → \(keyboard.persistentIdentifier)",
            includeSnapshot: false
        )
    }

    func removeKeyboardCacheFor(bundleId: String) {
        appKeyboardCache.remove(byBundleId: bundleId)
    }

    func clearKeyboardCache() {
        appKeyboardCache.clear()
    }

    func logStartupSettings() {
        let p = preferences
        let sysId = p.systemWideDefaultKeyboardId.isEmpty ? "(empty)" : p.systemWideDefaultKeyboardId
        let sysResolved = systemWideDefaultKeyboard?.persistentIdentifier ?? "(unresolved)"
        let addrId = p.browserAddressDefaultKeyboardId.isEmpty ? "(empty)" : p.browserAddressDefaultKeyboardId
        let addrResolved = browserAddressDefaultKeyboard?.persistentIdentifier ?? "(unresolved)"

        let restoreKey = "isRestorePreviouslyUsedInputSource"
        let restoreRaw: String = {
            if let domain = Bundle.main.bundleIdentifier.flatMap({
                UserDefaults.standard.persistentDomain(forName: $0)
            }), let value = domain[restoreKey] {
                return "\(value)"
            }
            return "(not in persistentDomain — using registered default)"
        }()

        let migrateFlag = UserDefaults.standard.bool(forKey: "ISPEnableRestorePreviouslyUsed.v1")
        let axTrusted = PermissionsVM.checkAccessibility(prompt: false)

        let appRules = (try? container.viewContext.fetch(AppRule.fetchRequest())) ?? []
        let forcedRules = appRules.compactMap { rule -> String? in
            guard let bid = rule.bundleId, let kb = rule.forcedKeyboard else { return nil }
            return "\(bid)→\(kb.persistentIdentifier)"
        }
        let restoreOverrides = appRules.compactMap { rule -> String? in
            guard let bid = rule.bundleId else { return nil }
            if rule.doRestoreKeyboard { return "\(bid):forceRestore" }
            if rule.doNotRestoreKeyboard { return "\(bid):neverRestore" }
            return nil
        }

        ISPFileLog.event("settings", "restorePreviouslyUsed=\(p.isRestorePreviouslyUsedInputSource) raw=\(restoreRaw) migrateV1=\(migrateFlag)", includeSnapshot: false)
        ISPFileLog.event("settings", "systemDefault id=\(sysId) resolved=\(sysResolved)", includeSnapshot: false)
        ISPFileLog.event("settings", "browserAddressDefault id=\(addrId) resolved=\(addrResolved)", includeSnapshot: false)
        ISPFileLog.event("settings", "enhancedMode=\(p.isEnhancedModeEnabled) axTrusted=\(axTrusted) CJKVFix=\(p.isCJKVFixEnabled)", includeSnapshot: false)
        ISPFileLog.event(
            "settings",
            "triggers switchApp=\(p.isActiveWhenSwitchApp) focusChange=\(p.isActiveWhenFocusedElementChanges) inputSource=\(p.isActiveWhenSwitchInputSource) longPress=\(p.isActiveWhenLongpressLeftMouse)",
            includeSnapshot: false
        )
        ISPFileLog.event(
            "settings",
            "cacheEntries=\(appKeyboardCache.entryCount) appRules=\(appRules.count) forced=[\(forcedRules.joined(separator: ", "))] overrides=[\(restoreOverrides.joined(separator: ", "))]",
            includeSnapshot: false
        )
        ISPFileLog.event(
            "settings",
            "perWindowMemory=cg+poll axTrusted=\(axTrusted) (CGWindowList; AX optional)",
            includeSnapshot: false
        )
    }

    enum AppAutoSwitchKeyboardStatus {
        case cached(InputSource), specified(InputSource)

        var inputSource: InputSource {
            switch self {
            case let .cached(i): return i
            case let .specified(i): return i
            }
        }
    }

    func getAppAutoSwitchKeyboard(
        _ appKind: AppKind
    ) -> AppAutoSwitchKeyboardStatus? {
        if appKind.getBrowserInfo()?.isFocusedOnAddressBar == true,
           let browserAddressKeyboard = browserAddressDefaultKeyboard
        {
            return .specified(browserAddressKeyboard)
        }

        if let forced = forcedKeyboard(for: appKind) {
            if appKeyboardCache.retrieve(appKind) != nil {
                appKeyboardCache.remove(appKind)
                ISPFileLog.event(
                    "cache-purge",
                    "forced wins \(appKind.getApp().bundleIdentifier ?? "?") → \(forced.persistentIdentifier)",
                    includeSnapshot: false
                )
            }
            return .specified(forced)
        }

        if let cachedKeyboard = getAppCachedKeyboard(appKind) {
            return .cached(cachedKeyboard)
        }

        if let defaultKeyboard = getAppDefaultKeyboard(appKind) {
            return .specified(defaultKeyboard)
        }

        if let systemDefaultKeyboard = systemWideDefaultKeyboard {
            return .specified(systemDefaultKeyboard)
        }

        return nil
    }

    func getAppCachedKeyboard(_ appKind: AppKind) -> InputSource? {
        guard appNeedCacheKeyboard(appKind) else { return nil }
        return appKeyboardCache.retrieve(appKind)
    }

    func getAppDefaultKeyboard(_ appKind: AppKind) -> InputSource? {
        if appKind.getBrowserInfo()?.isFocusedOnAddressBar == true,
           let browserAddressKeyboard = browserAddressDefaultKeyboard
        {
            return browserAddressKeyboard
        }

        if let forced = forcedKeyboard(for: appKind) {
            return forced
        }

        return systemWideDefaultKeyboard
    }
}
