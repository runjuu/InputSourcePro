import Carbon
import Cocoa
import Combine
import CoreGraphics
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

    func select(useCJKVFix: Bool) {
        Self.logger.debug { "Select \(id)" }

        guard Self.getCurrentInputSource().id != id else {
            Self.logger.debug { "Skip Select \(id)" }
            return
        }

        let updateStrategy: String = {
            if isCJKVR {
                // https://stackoverflow.com/a/60375569
                if useCJKVFix,
                   PermissionsVM.checkAccessibility(prompt: false),
                   let selectPreviousShortcut = Self.getSelectPreviousShortcut()
                {
                    TISSelectInputSource(tisInputSource)

                    // Workaround for TIS CJKV layout bug:
                    // when it's CJKV, select nonCJKV input first and then return
                    if let nonCJKV = Self.nonCJKVSource() {
                        Self.logger.debug { "S1: Start" }
                        TISSelectInputSource(nonCJKV.tisInputSource)
                        Self.logger.debug { "S1: selectPrevious" }
                        Self.selectPrevious(shortcut: selectPreviousShortcut)
                        Self.logger.debug { "S1: Done" }
                    }

                    return "S1"
                } else {
                    TISSelectInputSource(tisInputSource)
                    return "S0-2"
                }
            } else {
                TISSelectInputSource(tisInputSource)

                return "S0-2"
            }
        }()

        Self.logger.debug { "Select by \(updateStrategy)" }
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

    static func selectPrevious(shortcut: (Int, UInt64)) {
        let src = CGEventSource(stateID: .hidSystemState)

        let key = CGKeyCode(shortcut.0)
        let flag = CGEventFlags(rawValue: shortcut.1)

        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)!
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)!

        down.flags = flag
        up.flags = flag

        let ctrlDown = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_Control), keyDown: true)
        let ctrlUp = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_Control), keyDown: false)

        ctrlDown?.post(tap: .cghidEventTap)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        ctrlUp?.post(tap: .cghidEventTap)
    }

    // from read-symbolichotkeys script of Karabiner
    // github.com/tekezo/Karabiner/blob/master/src/util/read-symbolichotkeys/read-symbolichotkeys/main.m
    static func getSelectPreviousShortcut() -> (Int, UInt64)? {
        guard let dict = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys") else {
            return nil
        }
        guard let symbolichotkeys = dict["AppleSymbolicHotKeys"] as! NSDictionary? else {
            return nil
        }
        guard let symbolichotkey = symbolichotkeys["60"] as! NSDictionary? else {
            return nil
        }
        if (symbolichotkey["enabled"] as! NSNumber).intValue != 1 {
            return nil
        }
        guard let value = symbolichotkey["value"] as! NSDictionary? else {
            return nil
        }
        guard let parameters = value["parameters"] as! NSArray? else {
            return nil
        }
        return (
            (parameters[1] as! NSNumber).intValue,
            (parameters[2] as! NSNumber).uint64Value
        )
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
