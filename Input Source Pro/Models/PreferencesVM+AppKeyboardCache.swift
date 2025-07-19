import AppKit

extension PreferencesVM {
    func appNeedCacheKeyboard(_ appKind: AppKind) -> Bool {
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

    func cacheKeyboardFor(_ appKind: AppKind, keyboard: InputSource) {
        let defaultKeyboard = getAppDefaultKeyboard(appKind)

        if appNeedCacheKeyboard(appKind),
           defaultKeyboard?.id != keyboard.id
        {
            appKeyboardCache.save(appKind, keyboard: keyboard)
        } else {
            appKeyboardCache.remove(appKind)
        }
    }

    func removeKeyboardCacheFor(bundleId: String) {
        appKeyboardCache.remove(byBundleId: bundleId)
    }

    func clearKeyboardCache() {
        appKeyboardCache.clear()
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
        if let cachedKeyboard = getAppCachedKeyboard(appKind) {
            return .cached(cachedKeyboard)
        }

        if let defaultKeyboard = getAppDefaultKeyboard(appKind) {
            return .specified(defaultKeyboard)
        }

        // Fallback to system-wide default keyboard to prevent input method getting stuck
        // This ensures that apps without specific keyboard configuration will always
        // switch to the system default, resolving issues like ChatGPT → Terminal switching
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

        if let inputSource = appKind.getBrowserInfo()?.rule?.forcedKeyboard {
            return inputSource
        }

        return getAppCustomization(app: appKind.getApp())?.forcedKeyboard ?? systemWideDefaultKeyboard
    }
}
