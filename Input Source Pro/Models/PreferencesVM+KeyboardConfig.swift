import AppKit
import Bodega
import Boutique
import Foundation
import SwiftUI

extension PreferencesVM {
    func addKeyboardConfig(_ inputSource: InputSource) -> KeyboardConfig {
        if let config = getKeyboardConfig(inputSource) {
            return config
        } else {
            let config = KeyboardConfig(context: container.viewContext)

            config.id = inputSource.id

            saveContext()

            return config
        }
    }

    func update(_ config: KeyboardConfig, textColor: Color, bgColor: Color) {
        saveContext {
            config.textColor = textColor == self.preferences.indicatorForgegroundColor ? nil : textColor
            config.bgColor = bgColor == self.preferences.indicatorBackgroundColor ? nil : bgColor
        }
    }

    func getKeyboardConfig(_ inputSource: InputSource) -> KeyboardConfig? {
        return keyboardConfigs.first(where: { $0.id == inputSource.id })
    }

    func getOrCreateKeyboardConfig(_ inputSource: InputSource) -> KeyboardConfig {
        return getKeyboardConfig(inputSource) ?? addKeyboardConfig(inputSource)
    }
}

extension PreferencesVM {
    func getTextNSColor(_ inputSource: InputSource) -> NSColor? {
        let isAutoAppearanceMode = preferences.isAutoAppearanceMode

        if let keyboardColor = getKeyboardConfig(inputSource)?.textColor {
            return NSColor(keyboardColor)
        } else {
            return isAutoAppearanceMode
                ? preferences.indicatorForgeground?.dynamicColor
                : NSColor(preferences.indicatorForgegroundColor)
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
        let isAutoAppearanceMode = preferences.isAutoAppearanceMode

        if let bgColor = getKeyboardConfig(inputSource)?.bgColor {
            return NSColor(bgColor)
        } else {
            return isAutoAppearanceMode
                ? preferences.indicatorBackground?.dynamicColor
                : NSColor(preferences.indicatorBackgroundColor)
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
    struct DeprecatedKeyboardSettings: Codable & Equatable & Identifiable {
        let id: String

        var textColorHex: String?
        var bgColorHex: String?
    }

    func migratePreferncesIfNeed() {
        if preferences.prevInstalledBuildVersion <= 462 {
            update {
                $0.indicatorInfo = $0.isShowInputSourcesLabel ? .iconAndTitle : .iconOnly
            }
        }
    }

    func migrateBoutiqueIfNeed() {
        let storagePath = Store<DeprecatedKeyboardSettings>.documentsDirectory(appendingPath: "KeyboardSettings")

        guard preferences.prevInstalledBuildVersion == 316,
              FileManager.default.fileExists(atPath: storagePath.path) else { return }

        let store = Store<DeprecatedKeyboardSettings>(storagePath: storagePath)
        let inputSources = InputSource.sources

        store.$items
            .filter { $0.count > 0 }
            .first()
            .sink { [weak self] items in
                self?.saveContext {
                    for item in items {
                        guard let inputSource = inputSources.first(where: { $0.id == item.id }),
                              let config = self?.getOrCreateKeyboardConfig(inputSource)
                        else { continue }

                        config.textColorHex = item.textColorHex
                        config.bgColorHex = item.bgColorHex
                    }
                }

                do {
                    try FileManager.default.removeItem(at: storagePath)
                } catch {
                    print("Boutique migration error: \(error.localizedDescription)")
                }
            }
            .store(in: cancelBag)
    }
}
