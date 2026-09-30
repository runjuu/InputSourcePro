import Carbon
import CoreGraphics

enum MarkdownPunctuationMapping {
    struct InputContext: Equatable {
        let sourceID: String
        let inputModeID: String?
        let keyboardLayoutID: String
    }

    private static let pinyinSourceID = "com.apple.inputmethod.SCIM.ITABC"
    private static let supportedKeyboardLayouts: Set<String> = [
        "com.apple.keylayout.PinyinKeyboard",
        "com.apple.keylayout.ABC",
        "com.apple.keylayout.US"
    ]

    private static let replacements: [CGKeyCode: (normal: String?, shifted: String?)] = [
        CGKeyCode(kVK_ANSI_Grave): ("`", nil),
        CGKeyCode(kVK_ANSI_4): (nil, "$"),
        CGKeyCode(kVK_ANSI_Comma): (nil, "《》"),
        CGKeyCode(kVK_ANSI_Period): (nil, ">")
    ]

    private static let ansiBrackets: [CGKeyCode: (normal: String?, shifted: String?)] = [
        CGKeyCode(kVK_ANSI_LeftBracket): ("[", nil),
        CGKeyCode(kVK_ANSI_RightBracket): ("]", nil)
    ]

    private static let jisBrackets: [CGKeyCode: (normal: String?, shifted: String?)] = [
        CGKeyCode(kVK_ANSI_RightBracket): ("[", nil),
        CGKeyCode(kVK_ANSI_Backslash): ("]", nil)
    ]

    static func replacement(
        for keyCode: CGKeyCode,
        flags: CGEventFlags,
        keyboardType: Int64,
        contextProvider: () -> InputContext? = currentInputContext
    ) -> String? {
        guard let keyboardType = Int16(exactly: keyboardType) else { return nil }
        let brackets: [CGKeyCode: (normal: String?, shifted: String?)]
        switch KBGetLayoutType(keyboardType) {
        case OSType(kKeyboardANSI), OSType(kKeyboardISO):
            brackets = ansiBrackets
        case OSType(kKeyboardJIS):
            brackets = jisBrackets
        default:
            return nil
        }
        guard let mapping = replacements[keyCode] ?? brackets[keyCode] else { return nil }

        let preservedModifiers: CGEventFlags = [
            .maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn, .maskAlphaShift
        ]
        guard flags.intersection(preservedModifiers).isEmpty,
              let replacement = flags.contains(.maskShift) ? mapping.shifted : mapping.normal
        else { return nil }

        guard let context = contextProvider(),
              context.sourceID == pinyinSourceID,
              context.inputModeID == pinyinSourceID,
              supportedKeyboardLayouts.contains(context.keyboardLayoutID)
        else { return nil }

        return replacement
    }

    static func currentInputContext() -> InputContext? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let sourceID = stringProperty(kTISPropertyInputSourceID, of: source),
              let keyboardLayoutID = stringProperty(kTISPropertyInputSourceID, of: layout)
        else { return nil }

        return InputContext(
            sourceID: sourceID,
            inputModeID: stringProperty(kTISPropertyInputModeID, of: source),
            keyboardLayoutID: keyboardLayoutID
        )
    }

    private static func stringProperty(_ key: CFString, of source: TISInputSource) -> String? {
        guard let value = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
}
