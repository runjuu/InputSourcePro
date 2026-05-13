import CoreData
import Foundation
import KeyboardShortcuts

enum SettingsBackupError: LocalizedError {
    case unsupportedSchemaVersion(Int)
    case saveFailed

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return String(format: "Unsupported settings backup version %@".i18n(), "\(version)")
        case .saveFailed:
            return "Unable to save imported settings.".i18n()
        }
    }
}

struct SettingsBackup: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let app: SettingsBackupApp
    let exportedAt: Date
    let preferences: SettingsBackupPreferences
    let appRules: [SettingsBackupAppRule]
    let browserRules: [SettingsBackupBrowserRule]
    let keyboardConfigs: [SettingsBackupKeyboardConfig]
    let hotKeyGroups: [SettingsBackupHotKeyGroup]
    let keyboardShortcuts: [String: KeyboardShortcuts.Shortcut]

    init(
        app: SettingsBackupApp,
        preferences: SettingsBackupPreferences,
        appRules: [SettingsBackupAppRule],
        browserRules: [SettingsBackupBrowserRule],
        keyboardConfigs: [SettingsBackupKeyboardConfig],
        hotKeyGroups: [SettingsBackupHotKeyGroup],
        keyboardShortcuts: [String: KeyboardShortcuts.Shortcut]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.app = app
        exportedAt = Date()
        self.preferences = preferences
        self.appRules = appRules
        self.browserRules = browserRules
        self.keyboardConfigs = keyboardConfigs
        self.hotKeyGroups = hotKeyGroups
        self.keyboardShortcuts = keyboardShortcuts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        app = try container.decodeIfPresent(SettingsBackupApp.self, forKey: .app) ?? .unknown
        exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date(timeIntervalSince1970: 0)
        preferences = try container.decodeIfPresent(SettingsBackupPreferences.self, forKey: .preferences) ?? SettingsBackupPreferences()
        appRules = try container.decodeIfPresent([SettingsBackupAppRule].self, forKey: .appRules) ?? []
        browserRules = try container.decodeIfPresent([SettingsBackupBrowserRule].self, forKey: .browserRules) ?? []
        keyboardConfigs = try container.decodeIfPresent([SettingsBackupKeyboardConfig].self, forKey: .keyboardConfigs) ?? []
        hotKeyGroups = try container.decodeIfPresent([SettingsBackupHotKeyGroup].self, forKey: .hotKeyGroups) ?? []
        keyboardShortcuts = try container.decodeIfPresent(
            [String: KeyboardShortcuts.Shortcut].self,
            forKey: .keyboardShortcuts
        ) ?? [:]
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SettingsBackupError.unsupportedSchemaVersion(schemaVersion)
        }
    }
}

struct SettingsBackupApp: Codable {
    let bundleIdentifier: String?
    let shortVersion: String
    let buildVersion: Int

    static var current: Self {
        Self(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            shortVersion: Bundle.main.shortVersion,
            buildVersion: Bundle.main.buildVersion
        )
    }

    static let unknown = Self(
        bundleIdentifier: nil,
        shortVersion: "unknown",
        buildVersion: 0
    )
}

struct SettingsBackupPreferences: Codable {
    var isLaunchAtLogin: Bool?
    var isShowIconInMenuBar: Bool?
    var isEnhancedModeEnabled: Bool?
    var isCJKVFixEnabled: Bool?
    var cJKVFixStrategy: CJKVFixStrategy?
    var isActiveWhenLongpressLeftMouse: Bool?
    var isActiveWhenSwitchApp: Bool?
    var isHideWhenSwitchAppWithForceKeyboard: Bool?
    var isActiveWhenSwitchInputSource: Bool?
    var isActiveWhenFocusedElementChanges: Bool?
    var isRestorePreviouslyUsedInputSource: Bool?
    var isFunctionKeysEnabled: Bool?
    var shortcutTriggerMode: ShortcutTriggerMode?
    var singleModifierTrigger: SingleModifierTrigger?
    var shortcutModeInputSourceMapping: [String: ShortcutTriggerMode]?
    var shortcutModeGroupMapping: [String: ShortcutTriggerMode]?
    var singleModifierTriggerInputSourceMapping: [String: SingleModifierTrigger]?
    var singleModifierTriggerGroupMapping: [String: SingleModifierTrigger]?
    var singleModifierInputSourceMapping: [String: ModifierCombo]?
    var singleModifierGroupMapping: [String: ModifierCombo]?
    var systemWideDefaultKeyboardId: String?
    var browserAddressDefaultKeyboardId: String?
    var isEnableURLSwitchForSafari: Bool?
    var isEnableURLSwitchForSafariTechnologyPreview: Bool?
    var isEnableURLSwitchForChrome: Bool?
    var isEnableURLSwitchForChromium: Bool?
    var isEnableURLSwitchForArc: Bool?
    var isEnableURLSwitchForEdge: Bool?
    var isEnableURLSwitchForBrave: Bool?
    var isEnableURLSwitchForBraveBeta: Bool?
    var isEnableURLSwitchForBraveNightly: Bool?
    var isEnableURLSwitchForVivaldi: Bool?
    var isEnableURLSwitchForOpera: Bool?
    var isEnableURLSwitchForThorium: Bool?
    var isEnableURLSwitchForFirefox: Bool?
    var isEnableURLSwitchForFirefoxDeveloperEdition: Bool?
    var isEnableURLSwitchForFirefoxNightly: Bool?
    var isEnableURLSwitchForZen: Bool?
    var isEnableURLSwitchForDia: Bool?
    var indicatorInfo: IndicatorInfo?
    var indicatorSize: IndicatorSize?
    var isAutoAppearanceMode: Bool?
    var appearanceMode: Preferences.AppearanceMode?
    var indicatorBackground: IndicatorColor?
    var indicatorForgeground: IndicatorColor?
    var tryToDisplayIndicatorNearCursor: Bool?
    var isEnableAlwaysOnIndicator: Bool?
    var indicatorPosition: IndicatorPosition?
    var indicatorPositionAlignment: IndicatorPosition.Alignment?
    var indicatorPositionSpacing: IndicatorPosition.Spacing?

    init() {}

    init(_ preferences: Preferences) {
        isLaunchAtLogin = preferences.isLaunchAtLogin
        isShowIconInMenuBar = preferences.isShowIconInMenuBar
        isEnhancedModeEnabled = preferences.isEnhancedModeEnabled
        isCJKVFixEnabled = preferences.isCJKVFixEnabled
        cJKVFixStrategy = preferences.cJKVFixStrategy
        isActiveWhenLongpressLeftMouse = preferences.isActiveWhenLongpressLeftMouse
        isActiveWhenSwitchApp = preferences.isActiveWhenSwitchApp
        isHideWhenSwitchAppWithForceKeyboard = preferences.isHideWhenSwitchAppWithForceKeyboard
        isActiveWhenSwitchInputSource = preferences.isActiveWhenSwitchInputSource
        isActiveWhenFocusedElementChanges = preferences.isActiveWhenFocusedElementChanges
        isRestorePreviouslyUsedInputSource = preferences.isRestorePreviouslyUsedInputSource
        isFunctionKeysEnabled = preferences.isFunctionKeysEnabled
        shortcutTriggerMode = preferences.shortcutTriggerMode
        singleModifierTrigger = preferences.singleModifierTrigger
        shortcutModeInputSourceMapping = preferences.shortcutModeInputSourceMapping
        shortcutModeGroupMapping = preferences.shortcutModeGroupMapping
        singleModifierTriggerInputSourceMapping = preferences.singleModifierTriggerInputSourceMapping
        singleModifierTriggerGroupMapping = preferences.singleModifierTriggerGroupMapping
        singleModifierInputSourceMapping = preferences.singleModifierInputSourceMapping
        singleModifierGroupMapping = preferences.singleModifierGroupMapping
        systemWideDefaultKeyboardId = preferences.systemWideDefaultKeyboardId
        browserAddressDefaultKeyboardId = preferences.browserAddressDefaultKeyboardId
        isEnableURLSwitchForSafari = preferences.isEnableURLSwitchForSafari
        isEnableURLSwitchForSafariTechnologyPreview = preferences.isEnableURLSwitchForSafariTechnologyPreview
        isEnableURLSwitchForChrome = preferences.isEnableURLSwitchForChrome
        isEnableURLSwitchForChromium = preferences.isEnableURLSwitchForChromium
        isEnableURLSwitchForArc = preferences.isEnableURLSwitchForArc
        isEnableURLSwitchForEdge = preferences.isEnableURLSwitchForEdge
        isEnableURLSwitchForBrave = preferences.isEnableURLSwitchForBrave
        isEnableURLSwitchForBraveBeta = preferences.isEnableURLSwitchForBraveBeta
        isEnableURLSwitchForBraveNightly = preferences.isEnableURLSwitchForBraveNightly
        isEnableURLSwitchForVivaldi = preferences.isEnableURLSwitchForVivaldi
        isEnableURLSwitchForOpera = preferences.isEnableURLSwitchForOpera
        isEnableURLSwitchForThorium = preferences.isEnableURLSwitchForThorium
        isEnableURLSwitchForFirefox = preferences.isEnableURLSwitchForFirefox
        isEnableURLSwitchForFirefoxDeveloperEdition = preferences.isEnableURLSwitchForFirefoxDeveloperEdition
        isEnableURLSwitchForFirefoxNightly = preferences.isEnableURLSwitchForFirefoxNightly
        isEnableURLSwitchForZen = preferences.isEnableURLSwitchForZen
        isEnableURLSwitchForDia = preferences.isEnableURLSwitchForDia
        indicatorInfo = preferences.indicatorInfo
        indicatorSize = preferences.indicatorSize
        isAutoAppearanceMode = preferences.isAutoAppearanceMode
        appearanceMode = preferences.appearanceMode
        indicatorBackground = preferences.indicatorBackground
        indicatorForgeground = preferences.indicatorForgeground
        tryToDisplayIndicatorNearCursor = preferences.tryToDisplayIndicatorNearCursor
        isEnableAlwaysOnIndicator = preferences.isEnableAlwaysOnIndicator
        indicatorPosition = preferences.indicatorPosition
        indicatorPositionAlignment = preferences.indicatorPositionAlignment
        indicatorPositionSpacing = preferences.indicatorPositionSpacing
    }

    func apply(to preferences: inout Preferences) {
        if let isLaunchAtLogin { preferences.isLaunchAtLogin = isLaunchAtLogin }
        if let isShowIconInMenuBar { preferences.isShowIconInMenuBar = isShowIconInMenuBar }
        if let isEnhancedModeEnabled { preferences.isEnhancedModeEnabled = isEnhancedModeEnabled }
        if let isCJKVFixEnabled { preferences.isCJKVFixEnabled = isCJKVFixEnabled }
        if let cJKVFixStrategy { preferences.cJKVFixStrategy = cJKVFixStrategy }
        if let isActiveWhenLongpressLeftMouse { preferences.isActiveWhenLongpressLeftMouse = isActiveWhenLongpressLeftMouse }
        if let isActiveWhenSwitchApp { preferences.isActiveWhenSwitchApp = isActiveWhenSwitchApp }
        if let isHideWhenSwitchAppWithForceKeyboard {
            preferences.isHideWhenSwitchAppWithForceKeyboard = isHideWhenSwitchAppWithForceKeyboard
        }
        if let isActiveWhenSwitchInputSource { preferences.isActiveWhenSwitchInputSource = isActiveWhenSwitchInputSource }
        if let isActiveWhenFocusedElementChanges {
            preferences.isActiveWhenFocusedElementChanges = isActiveWhenFocusedElementChanges
        }
        if let isRestorePreviouslyUsedInputSource {
            preferences.isRestorePreviouslyUsedInputSource = isRestorePreviouslyUsedInputSource
        }
        if let isFunctionKeysEnabled { preferences.isFunctionKeysEnabled = isFunctionKeysEnabled }
        if let shortcutTriggerMode { preferences.shortcutTriggerMode = shortcutTriggerMode }
        if let singleModifierTrigger { preferences.singleModifierTrigger = singleModifierTrigger }
        if let shortcutModeInputSourceMapping {
            preferences.shortcutModeInputSourceMapping = shortcutModeInputSourceMapping
        }
        if let shortcutModeGroupMapping { preferences.shortcutModeGroupMapping = shortcutModeGroupMapping }
        if let singleModifierTriggerInputSourceMapping {
            preferences.singleModifierTriggerInputSourceMapping = singleModifierTriggerInputSourceMapping
        }
        if let singleModifierTriggerGroupMapping {
            preferences.singleModifierTriggerGroupMapping = singleModifierTriggerGroupMapping
        }
        if let singleModifierInputSourceMapping {
            preferences.singleModifierInputSourceMapping = singleModifierInputSourceMapping
        }
        if let singleModifierGroupMapping { preferences.singleModifierGroupMapping = singleModifierGroupMapping }
        if let systemWideDefaultKeyboardId { preferences.systemWideDefaultKeyboardId = systemWideDefaultKeyboardId }
        if let browserAddressDefaultKeyboardId {
            preferences.browserAddressDefaultKeyboardId = browserAddressDefaultKeyboardId
        }
        if let isEnableURLSwitchForSafari { preferences.isEnableURLSwitchForSafari = isEnableURLSwitchForSafari }
        if let isEnableURLSwitchForSafariTechnologyPreview {
            preferences.isEnableURLSwitchForSafariTechnologyPreview = isEnableURLSwitchForSafariTechnologyPreview
        }
        if let isEnableURLSwitchForChrome { preferences.isEnableURLSwitchForChrome = isEnableURLSwitchForChrome }
        if let isEnableURLSwitchForChromium { preferences.isEnableURLSwitchForChromium = isEnableURLSwitchForChromium }
        if let isEnableURLSwitchForArc { preferences.isEnableURLSwitchForArc = isEnableURLSwitchForArc }
        if let isEnableURLSwitchForEdge { preferences.isEnableURLSwitchForEdge = isEnableURLSwitchForEdge }
        if let isEnableURLSwitchForBrave { preferences.isEnableURLSwitchForBrave = isEnableURLSwitchForBrave }
        if let isEnableURLSwitchForBraveBeta { preferences.isEnableURLSwitchForBraveBeta = isEnableURLSwitchForBraveBeta }
        if let isEnableURLSwitchForBraveNightly {
            preferences.isEnableURLSwitchForBraveNightly = isEnableURLSwitchForBraveNightly
        }
        if let isEnableURLSwitchForVivaldi { preferences.isEnableURLSwitchForVivaldi = isEnableURLSwitchForVivaldi }
        if let isEnableURLSwitchForOpera { preferences.isEnableURLSwitchForOpera = isEnableURLSwitchForOpera }
        if let isEnableURLSwitchForThorium { preferences.isEnableURLSwitchForThorium = isEnableURLSwitchForThorium }
        if let isEnableURLSwitchForFirefox { preferences.isEnableURLSwitchForFirefox = isEnableURLSwitchForFirefox }
        if let isEnableURLSwitchForFirefoxDeveloperEdition {
            preferences.isEnableURLSwitchForFirefoxDeveloperEdition = isEnableURLSwitchForFirefoxDeveloperEdition
        }
        if let isEnableURLSwitchForFirefoxNightly {
            preferences.isEnableURLSwitchForFirefoxNightly = isEnableURLSwitchForFirefoxNightly
        }
        if let isEnableURLSwitchForZen { preferences.isEnableURLSwitchForZen = isEnableURLSwitchForZen }
        if let isEnableURLSwitchForDia { preferences.isEnableURLSwitchForDia = isEnableURLSwitchForDia }
        if let indicatorInfo { preferences.indicatorInfo = indicatorInfo }
        if let indicatorSize { preferences.indicatorSize = indicatorSize }
        if let isAutoAppearanceMode { preferences.isAutoAppearanceMode = isAutoAppearanceMode }
        if let appearanceMode { preferences.appearanceMode = appearanceMode }
        if let indicatorBackground { preferences.indicatorBackground = indicatorBackground }
        if let indicatorForgeground { preferences.indicatorForgeground = indicatorForgeground }
        if let tryToDisplayIndicatorNearCursor {
            preferences.tryToDisplayIndicatorNearCursor = tryToDisplayIndicatorNearCursor
        }
        if let isEnableAlwaysOnIndicator { preferences.isEnableAlwaysOnIndicator = isEnableAlwaysOnIndicator }
        if let indicatorPosition { preferences.indicatorPosition = indicatorPosition }
        if let indicatorPositionAlignment { preferences.indicatorPositionAlignment = indicatorPositionAlignment }
        if let indicatorPositionSpacing { preferences.indicatorPositionSpacing = indicatorPositionSpacing }
    }
}

struct SettingsBackupAppRule: Codable {
    let bundleId: String?
    let bundleName: String?
    let createdAt: Date?
    let forceEnglishPunctuation: Bool?
    let functionKeyModeRaw: String?
    let hideIndicator: Bool?
    let inputSourceId: String?
    let keyboardRestoreStrategy: KeyboardRestoreStrategy?
    let removed: Bool?
    let url: URL?

    init(_ rule: AppRule, preferences: Preferences) {
        bundleId = rule.bundleId
        bundleName = rule.bundleName
        createdAt = rule.createdAt
        forceEnglishPunctuation = rule.forceEnglishPunctuation
        functionKeyModeRaw = rule.functionKeyModeRaw
        hideIndicator = rule.hideIndicator
        inputSourceId = rule.inputSourceId
        keyboardRestoreStrategy = Self.keyboardRestoreStrategy(for: rule, preferences: preferences)
        removed = rule.removed
        url = rule.url
    }

    func insert(in context: NSManagedObjectContext) {
        let rule = AppRule(context: context)
        rule.bundleId = bundleId
        rule.bundleName = bundleName
        rule.createdAt = createdAt
        rule.forceEnglishPunctuation = forceEnglishPunctuation ?? false
        rule.functionKeyModeRaw = functionKeyModeRaw
        rule.hideIndicator = hideIndicator ?? false
        rule.inputSourceId = inputSourceId
        rule.doNotRestoreKeyboard = keyboardRestoreStrategy == .UseDefaultKeyboardInstead
        rule.doRestoreKeyboard = keyboardRestoreStrategy == .RestorePreviouslyUsedOne
        rule.removed = removed ?? false
        rule.url = url
    }

    private static func keyboardRestoreStrategy(for rule: AppRule, preferences: Preferences) -> KeyboardRestoreStrategy? {
        if rule.doNotRestoreKeyboard, rule.doRestoreKeyboard {
            return preferences.isRestorePreviouslyUsedInputSource
                ? .UseDefaultKeyboardInstead
                : .RestorePreviouslyUsedOne
        }

        if rule.doNotRestoreKeyboard {
            return .UseDefaultKeyboardInstead
        }

        if rule.doRestoreKeyboard {
            return .RestorePreviouslyUsedOne
        }

        return nil
    }
}

struct SettingsBackupBrowserRule: Codable {
    let createdAt: Date?
    let disabled: Bool?
    let hideIndicator: Bool?
    let inputSourceId: String?
    let keyboardRestoreStrategyRaw: String?
    let sample: String?
    let typeValue: Int32?
    let value: String?

    init(_ rule: BrowserRule) {
        createdAt = rule.createdAt
        disabled = rule.disabled
        hideIndicator = rule.hideIndicator
        inputSourceId = rule.inputSourceId
        keyboardRestoreStrategyRaw = rule.keyboardRestoreStrategyRaw
        sample = rule.sample
        typeValue = rule.typeValue
        value = rule.value
    }

    func insert(in context: NSManagedObjectContext) {
        let rule = BrowserRule(context: context)
        rule.createdAt = createdAt
        rule.disabled = disabled ?? false
        rule.hideIndicator = hideIndicator ?? false
        rule.inputSourceId = inputSourceId
        rule.keyboardRestoreStrategyRaw = keyboardRestoreStrategyRaw
        rule.sample = sample
        rule.typeValue = typeValue ?? BrowserRuleType.domainSuffix.rawValue
        rule.value = value
    }
}

struct SettingsBackupKeyboardConfig: Codable {
    let id: String?
    let textColorHex: String?
    let bgColorHex: String?

    init(_ config: KeyboardConfig) {
        id = config.id
        textColorHex = config.textColorHex
        bgColorHex = config.bgColorHex
    }

    func insert(in context: NSManagedObjectContext) {
        guard let id else { return }

        let config = KeyboardConfig(context: context)
        config.id = id
        config.textColorHex = textColorHex
        config.bgColorHex = bgColorHex
    }
}

struct SettingsBackupHotKeyGroup: Codable {
    let createdAt: Date?
    let id: String?
    let inputSourceIds: String?

    init(_ group: HotKeyGroup) {
        createdAt = group.createdAt
        id = group.id
        inputSourceIds = group.inputSourceIds
    }

    func insert(in context: NSManagedObjectContext) {
        let group = HotKeyGroup(context: context)
        group.createdAt = createdAt
        group.id = id
        group.inputSourceIds = inputSourceIds
    }
}

extension PreferencesVM {
    func exportSettingsBackupData() throws -> Data {
        let backup = try makeSettingsBackup()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.outputFormatting.insert(.withoutEscapingSlashes)
        return try encoder.encode(backup)
    }

    func readSettingsBackup(from url: URL) throws -> SettingsBackup {
        let data = try Data(contentsOf: url)
        return try Self.decodeSettingsBackup(from: data)
    }

    static func decodeSettingsBackup(from data: Data) throws -> SettingsBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(SettingsBackup.self, from: data)
        try backup.validate()
        return backup
    }

    func importSettingsBackup(_ backup: SettingsBackup) throws {
        try backup.validate()

        let shortcutNamesToReset = currentSettingsBackupShortcutNames()
            .union(backup.settingsBackupShortcutNames)

        try replacePersistedRecords(with: backup)

        update {
            backup.preferences.apply(to: &$0)
        }
        migrateShortcutPreferencesIfNeed()

        resetKeyboardShortcuts(named: shortcutNamesToReset)
        applyKeyboardShortcuts(backup.keyboardShortcuts)

        mainStorage.refresh()
        clearKeyboardCache()
    }
}

private extension PreferencesVM {
    func makeSettingsBackup() throws -> SettingsBackup {
        let appRules = try fetchAppRules()
        let browserRules = try fetchBrowserRules()
        let keyboardConfigs = try fetchKeyboardConfigs()
        let hotKeyGroups = try fetchHotKeyGroups()

        return SettingsBackup(
            app: .current,
            preferences: SettingsBackupPreferences(preferences),
            appRules: appRules.map { SettingsBackupAppRule($0, preferences: preferences) },
            browserRules: browserRules.map(SettingsBackupBrowserRule.init),
            keyboardConfigs: keyboardConfigs.map(SettingsBackupKeyboardConfig.init),
            hotKeyGroups: hotKeyGroups.map(SettingsBackupHotKeyGroup.init),
            keyboardShortcuts: keyboardShortcuts(for: hotKeyGroups)
        )
    }

    func replacePersistedRecords(with backup: SettingsBackup) throws {
        let context = container.viewContext
        var result: Result<Void, Error> = .success(())

        context.performAndWait {
            do {
                try deleteSettingsBackupObjects(AppRule.fetchRequest(), in: context)
                try deleteSettingsBackupObjects(BrowserRule.fetchRequest(), in: context)
                try deleteSettingsBackupObjects(KeyboardConfig.fetchRequest(), in: context)
                try deleteSettingsBackupObjects(HotKeyGroup.fetchRequest(), in: context)

                backup.appRules.forEach { $0.insert(in: context) }
                backup.browserRules.forEach { $0.insert(in: context) }
                backup.keyboardConfigs.forEach { $0.insert(in: context) }
                backup.hotKeyGroups.forEach { $0.insert(in: context) }

                try context.save()
            } catch {
                context.rollback()
                result = .failure(error)
            }
        }

        try result.get()
    }

    func fetchAppRules() throws -> [AppRule] {
        let request = AppRule.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "createdAt", ascending: true),
            NSSortDescriptor(key: "bundleId", ascending: true),
        ]
        return try container.viewContext.fetch(request)
    }

    func fetchBrowserRules() throws -> [BrowserRule] {
        let request = BrowserRule.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "createdAt", ascending: true),
            NSSortDescriptor(key: "value", ascending: true),
        ]
        return try container.viewContext.fetch(request)
    }

    func fetchKeyboardConfigs() throws -> [KeyboardConfig] {
        let request = KeyboardConfig.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
        return try container.viewContext.fetch(request)
    }

    func fetchHotKeyGroups() throws -> [HotKeyGroup] {
        let request = HotKeyGroup.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "createdAt", ascending: true),
            NSSortDescriptor(key: "id", ascending: true),
        ]
        return try container.viewContext.fetch(request)
    }

    func keyboardShortcuts(for hotKeyGroups: [HotKeyGroup]) -> [String: KeyboardShortcuts.Shortcut] {
        currentInputSourceShortcutNames()
            .union(hotKeyGroups.compactMap(\.id))
            .reduce(into: [:]) { result, name in
                guard let shortcut = KeyboardShortcuts.getShortcut(for: KeyboardShortcuts.Name(name)) else { return }
                result[name] = shortcut
            }
    }

    func currentSettingsBackupShortcutNames() -> Set<String> {
        currentInputSourceShortcutNames().union(getHotKeyGroups().compactMap(\.id))
    }

    func currentInputSourceShortcutNames() -> Set<String> {
        Set(InputSource.sources.map(\.persistentIdentifier))
    }

    func resetKeyboardShortcuts(named names: Set<String>) {
        KeyboardShortcuts.reset(names.sorted().map { KeyboardShortcuts.Name($0) })
    }

    func applyKeyboardShortcuts(_ shortcuts: [String: KeyboardShortcuts.Shortcut]) {
        for (name, shortcut) in shortcuts where !name.isEmpty {
            KeyboardShortcuts.setShortcut(shortcut, for: KeyboardShortcuts.Name(name))
        }
    }
}

private extension SettingsBackup {
    var settingsBackupShortcutNames: Set<String> {
        Set(keyboardShortcuts.keys).union(hotKeyGroups.compactMap(\.id))
    }
}

private func deleteSettingsBackupObjects<T: NSManagedObject>(
    _ request: NSFetchRequest<T>,
    in context: NSManagedObjectContext
) throws {
    for object in try context.fetch(request) {
        context.delete(object)
    }
}
