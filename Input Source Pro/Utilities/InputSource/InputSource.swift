import Carbon
import Cocoa
import CryptoKit

@MainActor
class InputSource {
    private static let persistentIdentifierSeparator = "::"

    static let logger = ISPLogger(
        category: "🤖 " + String(describing: InputSource.self),
        disabled: true
    )

    let tisInputSource: TISInputSource

    let icon: NSImage?

    var id: String { tisInputSource.id }
    var name: String { tisInputSource.name }
    var inputModeID: String? { tisInputSource.inputModeID }
    var persistentIdentifier: String {
        if let inputModeID = normalizedInputModeID {
            return "\(id)\(Self.persistentIdentifierSeparator)\(inputModeID)"
        }

        return id
    }

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
        InputSourceSwitcher.switchToInputSource(self, useCJKVFix: useCJKVFix)
    }

    private var normalizedInputModeID: String? {
        guard let inputModeID, !inputModeID.isEmpty else { return nil }
        return inputModeID
    }
}

extension InputSource: @preconcurrency Equatable {
    static func == (lhs: InputSource, rhs: InputSource) -> Bool {
        return lhs.persistentIdentifier == rhs.persistentIdentifier
    }
}

extension InputSource {
    private static var cancelBag = CancelBag()

    @MainActor
    static func getCurrentInputSource() -> InputSource {
        return InputSource(tisInputSource: TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    }

    static func resolvePersistedIdentifier(_ persistedIdentifier: String?) -> InputSource? {
        guard let persistedIdentifier, !persistedIdentifier.isEmpty else { return nil }

        let sources = Self.sources
        let (sourceID, inputModeID) = splitPersistedIdentifier(persistedIdentifier)

        if let inputModeID {
            if let exactMatch = sources.first(where: { $0.persistentIdentifier == persistedIdentifier }) {
                return exactMatch
            }

            if let modeMatch = sources.first(where: { $0.inputModeID == inputModeID }) {
                return modeMatch
            }
        }

        if let modeMatch = sources.first(where: { $0.inputModeID == persistedIdentifier }) {
            return modeMatch
        }

        let matches = sources.filter { $0.id == sourceID }

        guard !matches.isEmpty else { return nil }

        if let inputModeID,
           let modeMatch = matches.first(where: { $0.inputModeID == inputModeID })
        {
            return modeMatch
        }

        if matches.count > 1 {
            logger.debug { "Ambiguous persisted input source identifier \(persistedIdentifier); preferring an input-mode match." }
        }

        if let preferredModeMatch = matches.first(where: { $0.inputModeID != nil }) {
            return preferredModeMatch
        }

        return matches.first
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

    private static func splitPersistedIdentifier(_ persistedIdentifier: String) -> (sourceID: String, inputModeID: String?) {
        let components = persistedIdentifier.components(separatedBy: persistentIdentifierSeparator)

        guard components.count >= 2 else {
            return (persistedIdentifier, nil)
        }

        let sourceID = components[0]
        let inputModeID = components.dropFirst().joined(separator: persistentIdentifierSeparator)
        return (sourceID, inputModeID.isEmpty ? nil : inputModeID)
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
        persistentIdentifier
    }
}
