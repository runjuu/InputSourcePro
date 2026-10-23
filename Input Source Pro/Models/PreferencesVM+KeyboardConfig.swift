import AppKit
import Foundation
import SwiftUI

extension PreferencesVM {
    private var didMigrateModeAwareKeyboardConfigsKey: String {
        "didMigrateModeAwareKeyboardConfigs"
    }

    func updateKeyboardConfig(_ inputSource: InputSource, _ change: (KeyboardConfig) -> Void) {
        let config: KeyboardConfig
        if let existingConfig = getKeyboardConfig(inputSource) {
            config = existingConfig
        } else {
            config = KeyboardConfig(context: container.viewContext)
            config.id = inputSource.persistentIdentifier
        }

        change(config)
        saveContext()
    }

    func resetKeyboardColors(_ inputSource: InputSource) {
        guard let config = getKeyboardConfig(inputSource) else { return }

        saveContext {
            config.textColor = nil
            config.bgColor = nil
        }
    }

    func swapKeyboardColors(_ inputSource: InputSource) {
        let foreground = getTextColor(inputSource)
        let background = getBgColor(inputSource)
        updateKeyboardConfig(inputSource) {
            $0.textColor = background
            $0.bgColor = foreground
        }
    }

    func getKeyboardConfig(_ inputSource: InputSource) -> KeyboardConfig? {
        return keyboardConfigs.first(where: { $0.id == inputSource.persistentIdentifier })
            ?? keyboardConfigs.first(where: { $0.id == inputSource.id })
    }

    func migrateKeyboardConfigIdentifiersIfNeed() {
        guard !UserDefaults.standard.bool(forKey: didMigrateModeAwareKeyboardConfigsKey) else { return }

        let request = KeyboardConfig.fetchRequest()

        do {
            let configs = try container.viewContext.fetch(request)
            var existingIDs = Set(configs.compactMap(\.id))

            let didSave = saveContext {
                for config in configs {
                    guard let legacyID = config.id, !legacyID.isEmpty else { continue }
                    guard !InputSource.hasModeAwareIdentifier(legacyID) else { continue }

                    let inputSources = InputSource.resolvePersistedIdentifiers(
                        [legacyID],
                        expandingLegacySourceIDs: true
                    )

                    for inputSource in inputSources {
                        let targetID = inputSource.persistentIdentifier
                        guard targetID != legacyID, !existingIDs.contains(targetID) else { continue }

                        let migratedConfig = KeyboardConfig(context: self.container.viewContext)
                        migratedConfig.id = targetID
                        migratedConfig.textColorHex = config.textColorHex
                        migratedConfig.bgColorHex = config.bgColorHex
                        existingIDs.insert(targetID)
                    }
                }
            }

            if didSave {
                UserDefaults.standard.set(true, forKey: didMigrateModeAwareKeyboardConfigsKey)
            }
        } catch {
            print("migrateKeyboardConfigIdentifiers error: \(error.localizedDescription)")
        }
    }
}

extension PreferencesVM {
    /// The indicator's default foreground color, honoring auto-appearance mode and
    /// ignoring any per-input-source override. Used by badges that aren't backed by
    /// an `InputSource` (e.g. the Function Keys / Media Keys mode indicator).
    var defaultIndicatorTextNSColor: NSColor? {
        preferences.isAutoAppearanceMode
            ? preferences.indicatorForgeground?.dynamicColor
            : NSColor(preferences.indicatorForgegroundColor)
    }

    /// The indicator's default background color, honoring auto-appearance mode and
    /// ignoring any per-input-source override. Counterpart to `defaultIndicatorTextNSColor`.
    var defaultIndicatorBgNSColor: NSColor? {
        preferences.isAutoAppearanceMode
            ? preferences.indicatorBackground?.dynamicColor
            : NSColor(preferences.indicatorBackgroundColor)
    }

    func getTextNSColor(_ inputSource: InputSource) -> NSColor? {
        if let keyboardColor = getKeyboardConfig(inputSource)?.textColor {
            return NSColor(keyboardColor)
        } else {
            return defaultIndicatorTextNSColor
        }
    }

    func getTextColor(_ inputSource: InputSource) -> Color {
        if let nsColor = getTextNSColor(inputSource) {
            return Color(nsColor)
        } else {
            return preferences.indicatorForgegroundColor
        }
    }

    func getBgNSColor(_ inputSource: InputSource) -> NSColor? {
        if let bgColor = getKeyboardConfig(inputSource)?.bgColor {
            return NSColor(bgColor)
        } else {
            return defaultIndicatorBgNSColor
        }
    }

    func getBgColor(_ inputSource: InputSource) -> Color {
        if let nsColor = getBgNSColor(inputSource) {
            return Color(nsColor)
        } else {
            return preferences.indicatorBackgroundColor
        }
    }
}

extension PreferencesVM {
    func migratePreferncesIfNeed() {
        update {
            $0.migrateCJKVFixStrategyIfNeed()
        }

        if preferences.prevInstalledBuildVersion <= 462 {
            update {
                $0.indicatorInfo = $0.isShowInputSourcesLabel ? .iconAndTitle : .iconOnly
            }
        }
    }
}
