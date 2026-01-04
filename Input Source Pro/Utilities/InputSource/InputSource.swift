import Carbon
import Cocoa
import CryptoKit

@MainActor
class InputSource {
    static let logger = ISPLogger(
        category: "🤖 " + String(describing: InputSource.self),
        disabled: true
    )

    let tisInputSource: TISInputSource

    let icon: NSImage?

    var id: String { tisInputSource.id }
    var name: String { tisInputSource.name }
    var inputModeID: String? { tisInputSource.inputModeID }

    var isCJKVR: Bool {
        guard let lang = tisInputSource.sourceLanguages.first else { return false }

        return lang == "ru" || lang == "ko" || lang == "ja" || lang == "vi" || lang.hasPrefix("zh")
    }

    init(tisInputSource: TISInputSource) {
        self.tisInputSource = tisInputSource

        icon = { () -> NSImage? in
            if let imgName = Self.iconMap[String(tisInputSource.id.sha256().prefix(8))],
               let image = NSImage(named: imgName)
            {
                return image.markTemplateIfGrayScaleOrPdf()
            }

            guard let imageURL = tisInputSource.iconImageURL else {
                if #available(macOS 11.0, *) {
                    return nil
                } else {
                    if let iconRef = tisInputSource.iconRef {
                        return NSImage(iconRef: iconRef).markTemplateIfGrayScaleOrPdf()
                    } else {
                        return nil
                    }
                }
            }

            for url in [imageURL.retinaImageURL, imageURL.tiffImageURL, imageURL] {
                if let image = NSImage(contentsOf: url) {
                    return image.markTemplateIfGrayScaleOrPdf(url: url)
                }
            }

            if let baseURL = imageURL.baseURL,
               baseURL.lastPathComponent.hasSuffix(".app")
            {
                return NSWorkspace.shared.icon(forFile: baseURL.relativePath)
            }

            return nil
        }()
    }

    @discardableResult
    func select(useCJKVFix: Bool) -> Bool {
        Self.logger.debug { "Select \(id)" }
        let didSwitch = InputSourceSwitcher.switchToInputSource(self, useCJKVFix: useCJKVFix)
        if !didSwitch {
            Self.logger.debug { "Failed to select \(id)" }
        }
        return didSwitch
    }
}

extension InputSource: @preconcurrency Equatable {
    static func == (lhs: InputSource, rhs: InputSource) -> Bool {
        return lhs.id == rhs.id
    }
}

extension InputSource {
    private static var cancelBag = CancelBag()

    @MainActor
    static func getCurrentInputSource() -> InputSource {
        return InputSource(tisInputSource: TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    }
}

extension InputSource {
    static var sources: [InputSource] {
        let inputSourceNSArray = TISCreateInputSourceList(nil, false).takeRetainedValue() as NSArray
        let inputSourceList = inputSourceNSArray as! [TISInputSource]

        return inputSourceList
            .filter { $0.category == TISInputSource.Category.keyboardInputSource && $0.isSelectable }
            .map { InputSource(tisInputSource: $0) }
    }

    static func nonCJKVSource() -> InputSource? {
        return sources.first(where: { !$0.isCJKVR })
    }

    static func anotherCJKVSource(current: InputSource) -> InputSource? {
        return sources.first(where: { $0 != current && $0.isCJKVR })
    }

    // from read-symbolichotkeys script of Karabiner
    // github.com/tekezo/Karabiner/blob/master/src/util/read-symbolichotkeys/read-symbolichotkeys/main.m
    static func getSelectPreviousShortcut() -> (Int, UInt64)? {
        guard let shortcut = InputSourceSwitcher.systemSelectPreviousShortcut() else {
            return nil
        }
        return (Int(shortcut.keyCode), shortcut.modifiers.rawValue)
    }
}

private extension URL {
    var retinaImageURL: URL {
        var components = pathComponents
        let filename: String = components.removeLast()
        let ext: String = pathExtension
        let retinaFilename = filename.replacingOccurrences(of: "." + ext, with: "@2x." + ext)
        return NSURL.fileURL(withPathComponents: components + [retinaFilename])!
    }

    var tiffImageURL: URL {
        return deletingPathExtension().appendingPathExtension("tiff")
    }
}

extension InputSource: @preconcurrency CustomStringConvertible {
    var description: String {
        id
    }
}
