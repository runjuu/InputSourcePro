import Carbon
import Foundation

extension TISInputSource {
    enum Category {
        static var keyboardInputSource: String {
            return kTISCategoryKeyboardInputSource as String
        }
    }

    private func getProperty(_ key: CFString) -> AnyObject? {
        let cfType = TISGetInputSourceProperty(self, key)
        if cfType != nil {
            return Unmanaged<AnyObject>.fromOpaque(cfType!).takeUnretainedValue()
        } else {
            return nil
        }
    }

    var id: String {
        return getProperty(kTISPropertyInputSourceID) as! String
    }

    var name: String {
        return getProperty(kTISPropertyLocalizedName) as! String
    }

    var category: String? {
        return getProperty(kTISPropertyInputSourceCategory) as? String
    }

    var isSelectable: Bool {
        return getProperty(kTISPropertyInputSourceIsSelectCapable) as? Bool ?? false
    }

    var isEnabled: Bool {
        return getProperty(kTISPropertyInputSourceIsEnabled) as? Bool ?? false
    }

    var sourceLanguages: [String] {
        return getProperty(kTISPropertyInputSourceLanguages) as? [String] ?? []
    }

    var inputModeID: String? {
        return getProperty(kTISPropertyInputModeID) as? String
    }

    var iconImageURL: URL? {
        return getProperty(kTISPropertyIconImageURL) as? URL
    }

    var iconRef: IconRef? {
        return OpaquePointer(TISGetInputSourceProperty(self, kTISPropertyIconRef))
    }
}
