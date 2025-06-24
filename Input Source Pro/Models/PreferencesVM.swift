import AppKit
import AXSwift
import Combine
import CombineExt
import LaunchAtLogin
import Sparkle
import SwiftUI

private enum UpdateFeed {
    static let stable = URL(string: "https://inputsource.pro/stable/appcast.xml")!
    static let beta = URL(string: "https://inputsource.pro/beta/appcast.xml")!
}

@MainActor
final class PreferencesVM: NSObject, ObservableObject {
    @Published
    var preferences = Preferences()

    @Published
    var keyboardConfigs: [KeyboardConfig] = []

    var permissionsVM: PermissionsVM

    var updaterController: SPUStandardUpdaterController?

    var cancelBag = CancelBag()

    var appKeyboardCache = AppKeyboardCache()

    let container: NSPersistentContainer
    let mainStorage: MainStorage

    let versionStr = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")"

    let buildStr = "\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")"

    @Published
    var automaticallyChecksForUpdates = false

    @Published
    var canChecksForUpdates = false

    init(permissionsVM: PermissionsVM) {
        self.permissionsVM = permissionsVM
        container = NSPersistentContainer(name: "Main")
        mainStorage = MainStorage(container: container)
        
        super.init();
        
        setupAutoUpdate()

        // TODO: - Move to MainStorage
        container.loadPersistentStores { _, error in
            if let error = error {
                print("Core Data 'Main' failed to load: \(error.localizedDescription)")
            } else {
                self.mainStorage.refresh()
            }
        }

        if preferences.prevInstalledBuildVersion == 0 {
            for filterApp in filterApps(NSWorkspace.shared.runningApplications) {
                addAppCustomization(filterApp)
            }
        }

        cleanRemovedAppCustomizationIfNeed()
        migratePreferncesIfNeed()
        migrateBoutiqueIfNeed()
        watchKeyboardConfigsChange()
        watchPreferenceChanges()
    }

    func update(_ change: (inout Preferences) -> Void) {
        var draft = preferences

        change(&draft)

        preferences = draft
    }

    func saveContext(_ callback: (() -> Void)? = nil) {
        if let callback = callback {
            container.viewContext.performAndWait {
                callback()
                save()
            }
        } else {
            save()
        }

        func save() {
            do {
                try container.viewContext.save()
            } catch {
                print("saveAppCustomization error: \(error.localizedDescription)")
            }
        }
    }
}

extension PreferencesVM {
    private func watchPreferenceChanges() {
        $preferences
            .map(\.isLaunchAtLogin)
            .removeDuplicates()
            .sink { LaunchAtLogin.isEnabled = $0 }
            .store(in: cancelBag)
    }
    
    private func watchKeyboardConfigsChange() {
        mainStorage.keyboardConfigs
            .assign(to: &$keyboardConfigs)
    }
}

extension PreferencesVM: @preconcurrency SPUUpdaterDelegate {
    private func setupAutoUpdate() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        updaterController?.updater
            .publisher(for: \.automaticallyChecksForUpdates)
            .removeDuplicates()
            .assign(to: &$automaticallyChecksForUpdates)

        $automaticallyChecksForUpdates
            .dropFirst()
            .sink { [weak self] in self?.updaterController?.updater.automaticallyChecksForUpdates = $0 }
            .store(in: cancelBag)

        updaterController?.updater
            .publisher(for: \.canCheckForUpdates)
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .assign(to: &$canChecksForUpdates)
    }

    func checkUpdates() {
        updaterController?.updater.checkForUpdates()
    }
    
    func feedURLString(for updater: SPUUpdater) -> String? {
        let url = preferences.receiveBetaUpdates ? UpdateFeed.beta : UpdateFeed.stable
        return url.absoluteString
    }
}

extension PreferencesVM {
    func getBrowserURL(_ bundleIdentifier: String?, application: Application?) -> URL? {
        guard
            permissionsVM.isAccessibilityEnabled,
            let bundleIdentifier = bundleIdentifier,
            let browser = Browser(rawValue: bundleIdentifier)
        else { return nil }

        switch browser {
        case .Safari:
            guard preferences.isEnableURLSwitchForSafari else { return nil }
        case .SafariTechnologyPreview:
            guard preferences.isEnableURLSwitchForSafariTechnologyPreview else { return nil }
        case .Chrome:
            guard preferences.isEnableURLSwitchForChrome else { return nil }
        case .Chromium:
            guard preferences.isEnableURLSwitchForChromium else { return nil }
        case .Arc:
            guard preferences.isEnableURLSwitchForArc else { return nil }
        case .Edge:
            guard preferences.isEnableURLSwitchForEdge else { return nil }
        case .Brave:
            guard preferences.isEnableURLSwitchForBrave else { return nil }
        case .BraveBeta:
            guard preferences.isEnableURLSwitchForBraveBeta else { return nil }
        case .BraveNightly:
            guard preferences.isEnableURLSwitchForBraveNightly else { return nil }
        case .Vivaldi:
            guard preferences.isEnableURLSwitchForVivaldi else { return nil }
        case .Opera:
            guard preferences.isEnableURLSwitchForOpera else { return nil }
        case .Thorium:
            guard preferences.isEnableURLSwitchForThorium else { return nil }
        case .Firefox:
            guard preferences.isEnableURLSwitchForFirefox else { return nil }
        case .FirefoxDeveloperEdition:
            guard preferences.isEnableURLSwitchForFirefoxDeveloperEdition else { return nil }
        case .FirefoxNightly:
            guard preferences.isEnableURLSwitchForFirefoxNightly else { return nil }
        case .Zen:
            guard preferences.isEnableURLSwitchForZen else { return nil }
        case .Dia:
            guard preferences.isEnableURLSwitchForDia else { return nil }
        }

        if let application = application,
           let focusedWindow: UIElement = try? application.attribute(.focusedWindow),
           let url = browser.getCurrentTabURL(focusedWindow: focusedWindow)
        {
            return url
        } else {
            if browser == .Safari || browser == .SafariTechnologyPreview {
                return .newtab
            } else {
                return nil
            }
        }
    }

    func filterApps(_ apps: [NSRunningApplication]) -> [NSRunningApplication] {
        let isDetectSpotlightLikeApp = preferences.isEnhancedModeEnabled

        return apps.filter { app in
            (isDetectSpotlightLikeApp && NSApplication.isFloatingApp(app.bundleIdentifier))
                || app.activationPolicy == .regular
        }
    }
}

struct Preferences {
    enum AppearanceMode: String, CaseIterable, Codable, Equatable {
        case dark = "Dark"
        case light = "Light"
    }

    private enum Key {
        static let prevInstalledBuildVersion = "prevInstalledBuildVersion"

        static let isLaunchAtLogin = "isLaunchAtLogin"
        static let isShowIconInMenuBar = "isShowIconInMenuBar"
        static let isEnhancedModeEnabled = "isDetectSpotlightLikeApp"
        static let isCJKVFixEnabled = "isCJKVFixEnabled"

        static let systemWideDefaultKeyboardId = "systemWideDefaultKeyboardId"

        static let browserAddressDefaultKeyboardId = "browserAddressDefaultKeyboardId"
        static let isActiveWhenLongpressLeftMouse = "isActiveWhenLongpressLeftMouse"
        static let isActiveWhenFocusedElementChanges = "isActiveWhenFocusedElementChanges"
        static let isActiveWhenSwitchApp = "isActiveWhenSwitchApp"
        static let isHideWhenSwitchAppWithForceKeyboard = "isHideWhenSwitchAppWithForceKeyboard"
        static let isActiveWhenSwitchInputSource = "isActiveWhenSwitchInputSource"

        static let isRestorePreviouslyUsedInputSource = "isRestorePreviouslyUsedInputSource"

        static let isEnableURLSwitchForSafari = "isEnableURLSwitchForSafari"
        static let isEnableURLSwitchForSafariTechnologyPreview = "isEnableURLSwitchForSafariTechnologyPreview"
        static let isEnableURLSwitchForChrome = "isEnableURLSwitchForChrome"
        static let isEnableURLSwitchForChromium = "isEnableURLSwitchForChromium"
        static let isEnableURLSwitchForArc = "isEnableURLSwitchForArc"
        static let isEnableURLSwitchForEdge = "isEnableURLSwitchForEdge"
        static let isEnableURLSwitchForBrave = "isEnableURLSwitchForBrave"
        static let isEnableURLSwitchForBraveBeta = "isEnableURLSwitchForBraveBeta"
        static let isEnableURLSwitchForBraveNightly = "isEnableURLSwitchForBraveNightly"
        static let isEnableURLSwitchForVivaldi = "isEnableURLSwitchForVivaldi"
        static let isEnableURLSwitchForOpera = "isEnableURLSwitchForOpera"
        static let isEnableURLSwitchForThorium = "isEnableURLSwitchForThorium"
        static let isEnableURLSwitchForFirefox = "isEnableURLSwitchForFirefox"
        static let isEnableURLSwitchForFirefoxDeveloperEdition = "isEnableURLSwitchForFirefoxDeveloperEdition"
        static let isEnableURLSwitchForFirefoxNightly = "isEnableURLSwitchForFirefoxNightly"
        static let isEnableURLSwitchForZen = "isEnableURLSwitchForZen"
        static let isEnableURLSwitchForDia = "isEnableURLSwitchForDia"

        static let isAutoAppearanceMode = "isAutoAppearanceMode"
        static let appearanceMode = "appearanceMode"
        static let isShowInputSourcesLabel = "isShowInputSourcesLabel"
        static let indicatorBackground = "indicatorBackground"
        static let indicatorForgeground = "indicatorForgeground"

        static let tryToDisplayIndicatorNearCursor = "tryToDisplayIndicatorNearCursor"
        static let isEnableAlwaysOnIndicator = "isEnableAlwaysOnIndicator"

        static let indicatorPosition = "indicatorPosition"
        static let indicatorPositionAlignment = "indicatorPositionAlignment"
        static let indicatorPositionSpacing = "indicatorPositionSpacing"

        static let indicatorSize = "indicatorSize"
        static let indicatorInfo = "indicatorInfo"
        
        static let receiveBetaUpdates = "receiveBetaUpdates"
    }

    fileprivate init() {}

    @UserDefault(Preferences.Key.prevInstalledBuildVersion)
    var prevInstalledBuildVersion = 0

    // MARK: - General

    @UserDefault(Preferences.Key.isLaunchAtLogin)
    var isLaunchAtLogin = LaunchAtLogin.isEnabled

    @UserDefault(Preferences.Key.isShowIconInMenuBar)
    var isShowIconInMenuBar = true

    @UserDefault(Preferences.Key.isEnhancedModeEnabled)
    var isEnhancedModeEnabled = false

    @UserDefault(Preferences.Key.isCJKVFixEnabled)
    var isCJKVFixEnabled = false
    
    @UserDefault(Preferences.Key.receiveBetaUpdates)
    var receiveBetaUpdates = false

    // MARK: - Triggers

    @UserDefault(Preferences.Key.isActiveWhenLongpressLeftMouse)
    var isActiveWhenLongpressLeftMouse = true

    @UserDefault(Preferences.Key.isActiveWhenSwitchApp)
    var isActiveWhenSwitchApp = true

    @UserDefault(Preferences.Key.isHideWhenSwitchAppWithForceKeyboard)
    var isHideWhenSwitchAppWithForceKeyboard = false

    @UserDefault(Preferences.Key.isActiveWhenSwitchInputSource)
    var isActiveWhenSwitchInputSource = true

    @UserDefault(Preferences.Key.isActiveWhenFocusedElementChanges)
    var isActiveWhenFocusedElementChanges = true

    // MARK: - Input Source

    @UserDefault(Preferences.Key.isRestorePreviouslyUsedInputSource)
    var isRestorePreviouslyUsedInputSource = false

    // MARK: - App Rules

    @UserDefault(Preferences.Key.systemWideDefaultKeyboardId)
    var systemWideDefaultKeyboardId = ""

    // MARK: - Browser Rules

    @UserDefault(Preferences.Key.browserAddressDefaultKeyboardId)
    var browserAddressDefaultKeyboardId = ""

    @UserDefault(Preferences.Key.isEnableURLSwitchForSafari)
    var isEnableURLSwitchForSafari = false

    @UserDefault(Preferences.Key.isEnableURLSwitchForSafariTechnologyPreview)
    var isEnableURLSwitchForSafariTechnologyPreview = false

    @UserDefault(Preferences.Key.isEnableURLSwitchForChrome)
    var isEnableURLSwitchForChrome = false

    @UserDefault(Preferences.Key.isEnableURLSwitchForChromium)
    var isEnableURLSwitchForChromium = false

    @UserDefault(Preferences.Key.isEnableURLSwitchForArc)
    var isEnableURLSwitchForArc = false

    @UserDefault(Preferences.Key.isEnableURLSwitchForEdge)
    var isEnableURLSwitchForEdge = false

    @UserDefault(Preferences.Key.isEnableURLSwitchForBrave)
    var isEnableURLSwitchForBrave = false

    @UserDefault(Preferences.Key.isEnableURLSwitchForBraveBeta)
    var isEnableURLSwitchForBraveBeta = false

    @UserDefault(Preferences.Key.isEnableURLSwitchForBraveNightly)
    var isEnableURLSwitchForBraveNightly = false

    @UserDefault(Preferences.Key.isEnableURLSwitchForVivaldi)
    var isEnableURLSwitchForVivaldi = false

    @UserDefault(Preferences.Key.isEnableURLSwitchForOpera)
    var isEnableURLSwitchForOpera = false

    @UserDefault(Preferences.Key.isEnableURLSwitchForThorium)
    var isEnableURLSwitchForThorium = false

    @UserDefault(Preferences.Key.isEnableURLSwitchForFirefox)
    var isEnableURLSwitchForFirefox = false

    @UserDefault(Preferences.Key.isEnableURLSwitchForFirefoxDeveloperEdition)
    var isEnableURLSwitchForFirefoxDeveloperEdition = false

    @UserDefault(Preferences.Key.isEnableURLSwitchForFirefoxNightly)
    var isEnableURLSwitchForFirefoxNightly = false

    @UserDefault(Preferences.Key.isEnableURLSwitchForZen)
    var isEnableURLSwitchForZen = false
    
    @UserDefault(Preferences.Key.isEnableURLSwitchForDia)
    var isEnableURLSwitchForDia = false

    // MARK: - Appearance

    @available(*, deprecated, message: "Use indicatorInfo instead")
    @UserDefault(Preferences.Key.isShowInputSourcesLabel)
    var isShowInputSourcesLabel = true

    @CodableUserDefault(Preferences.Key.indicatorInfo)
    var indicatorInfo = IndicatorInfo.iconAndTitle

    @CodableUserDefault(Preferences.Key.indicatorSize)
    var indicatorSize = IndicatorSize.medium

    @UserDefault(Preferences.Key.isAutoAppearanceMode)
    var isAutoAppearanceMode = true

    @CodableUserDefault(Preferences.Key.appearanceMode)
    var appearanceMode = AppearanceMode.dark

    @CodableUserDefault(Preferences.Key.indicatorBackground)
    var indicatorBackground = IndicatorColor.background

    @CodableUserDefault(Preferences.Key.indicatorForgeground)
    var indicatorForgeground = IndicatorColor.forgeground

    @UserDefault(Preferences.Key.tryToDisplayIndicatorNearCursor)
    var tryToDisplayIndicatorNearCursor = true

    @UserDefault(Preferences.Key.isEnableAlwaysOnIndicator)
    var isEnableAlwaysOnIndicator = false

    @CodableUserDefault(Preferences.Key.indicatorPosition)
    var indicatorPosition = IndicatorPosition.nearMouse

    @CodableUserDefault(Preferences.Key.indicatorPositionAlignment)
    var indicatorPositionAlignment = IndicatorPosition.Alignment.bottomRight

    @CodableUserDefault(Preferences.Key.indicatorPositionSpacing)
    var indicatorPositionSpacing = IndicatorPosition.Spacing.s
}

extension Preferences {
    var shortVersion: String {
        Bundle.main.shortVersion
    }

    var buildVersion: Int {
        Bundle.main.buildVersion
    }

    var isActiveWhenFocusedElementChangesEnabled: Bool {
        return isEnhancedModeEnabled && isActiveWhenFocusedElementChanges
    }

    var indicatorKind: IndicatorKind {
        guard let indicatorInfo = indicatorInfo else { return .iconAndTitle }

        switch indicatorInfo {
        case .iconAndTitle:
            return .iconAndTitle
        case .iconOnly:
            return .icon
        case .titleOnly:
            return .title
        }
    }

    var indicatorBackgroundColor: Color {
        get {
            switch appearanceMode {
            case .dark?:
                return indicatorBackground?.dark ?? IndicatorColor.background.dark
            default:
                return indicatorBackground?.light ?? IndicatorColor.background.light
            }
        }

        set {
            guard let appearanceMode = appearanceMode,
                  let indicatorBackground = indicatorBackground
            else { return }

            switch appearanceMode {
            case .dark:
                self.indicatorBackground = IndicatorColor(
                    light: indicatorBackground.light,
                    dark: newValue
                )
            case .light:
                self.indicatorBackground = IndicatorColor(
                    light: newValue,
                    dark: indicatorBackground.dark
                )
            }
        }
    }

    var indicatorForgegroundColor: Color {
        get {
            switch appearanceMode {
            case .dark?:
                return indicatorForgeground?.dark ?? IndicatorColor.forgeground.dark
            default:
                return indicatorForgeground?.light ?? IndicatorColor.forgeground.light
            }
        }

        set {
            guard let appearanceMode = appearanceMode,
                  let indicatorForgeground = indicatorForgeground
            else { return }

            switch appearanceMode {
            case .dark:
                self.indicatorForgeground = IndicatorColor(
                    light: indicatorForgeground.light,
                    dark: newValue
                )
            case .light:
                self.indicatorForgeground = IndicatorColor(
                    light: newValue,
                    dark: indicatorForgeground.dark
                )
            }
        }
    }
}

extension PreferencesVM {
    var systemWideDefaultKeyboard: InputSource? {
        return InputSource.sources.first { $0.id == preferences.systemWideDefaultKeyboardId }
    }

    var browserAddressDefaultKeyboard: InputSource? {
        return InputSource.sources.first { $0.id == preferences.browserAddressDefaultKeyboardId }
    }
}

extension PreferencesVM {
    func isUseCJKVFix() -> Bool {
        return preferences.isEnhancedModeEnabled && preferences.isCJKVFixEnabled
    }

    func isAbleToQueryLocation(_ app: NSRunningApplication) -> Bool {
        if app.bundleIdentifier == "com.tencent.WeWorkMac" {
            return false
        } else {
            return true
        }
    }

    func isShowAlwaysOnIndicator(app: NSRunningApplication) -> Bool {
        if preferences.isEnableAlwaysOnIndicator,
           isAbleToQueryLocation(app)
        {
            return true
        } else {
            return false
        }
    }

    func needDetectFocusedFieldChanges(app: NSRunningApplication) -> Bool {
        if preferences.isActiveWhenFocusedElementChangesEnabled,
           isAbleToQueryLocation(app)
        {
            return true
        } else {
            return false
        }
    }

    func isHideIndicator(_ appKind: AppKind) -> Bool {
        if let browserRule = appKind.getBrowserInfo()?.rule,
           browserRule.hideIndicator
        {
            return true
        }

        return getAppCustomization(app: appKind.getApp())?.hideIndicator == true
    }

    func needDisplayEnhancedModePrompt(bundleIdentifier: String?) -> Bool {
        NSApplication.isFloatingApp(bundleIdentifier) && !preferences.isEnhancedModeEnabled
    }
}
