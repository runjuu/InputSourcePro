import Carbon
import XCTest
@testable import Input_Source_Pro

final class MarkdownPunctuationMappingTests: XCTestCase {
    private typealias InputContext = MarkdownPunctuationMapping.InputContext

    private let pinyin = InputContext(
        sourceID: "com.apple.inputmethod.SCIM.ITABC",
        inputModeID: "com.apple.inputmethod.SCIM.ITABC",
        keyboardLayoutID: "com.apple.keylayout.PinyinKeyboard"
    )

    private let mappedKeys: [(keyCode: CGKeyCode, flags: CGEventFlags, replacement: String)] = [
        (CGKeyCode(kVK_ANSI_Grave), [], "`"),
        (CGKeyCode(kVK_ANSI_4), .maskShift, "$"),
        (CGKeyCode(kVK_ANSI_Comma), .maskShift, "《》"),
        (CGKeyCode(kVK_ANSI_Period), .maskShift, ">"),
        (CGKeyCode(kVK_ANSI_LeftBracket), [], "["),
        (CGKeyCode(kVK_ANSI_RightBracket), [], "]")
    ]

    func testANSIAndISOMapOnlySpecifiedKeysOnSupportedPinyinLayouts() {
        for layoutID in ["com.apple.keylayout.PinyinKeyboard", "com.apple.keylayout.ABC", "com.apple.keylayout.US"] {
            let context = InputContext(
                sourceID: pinyin.sourceID,
                inputModeID: pinyin.inputModeID,
                keyboardLayoutID: layoutID
            )

            for keyboardType: Int64 in [40, 41] {
                for key in mappedKeys {
                    XCTAssertEqual(
                        MarkdownPunctuationMapping.replacement(
                            for: key.keyCode, flags: key.flags, keyboardType: keyboardType
                        ) { context },
                        key.replacement,
                        "Layout: \(layoutID), keyboard: \(keyboardType), key: \(key.keyCode)"
                    )
                }
                XCTAssertNil(MarkdownPunctuationMapping.replacement(
                    for: CGKeyCode(kVK_ANSI_Backslash), flags: [], keyboardType: keyboardType
                ) { context })
            }
        }
    }

    func testJISMapsItsBracketKeysAndPreservesAtSign() {
        let jisKeys = Array(mappedKeys.prefix(4)) + [
            (CGKeyCode(kVK_ANSI_RightBracket), [], "["),
            (CGKeyCode(kVK_ANSI_Backslash), [], "]")
        ]
        for layoutID in ["com.apple.keylayout.PinyinKeyboard", "com.apple.keylayout.ABC", "com.apple.keylayout.US"] {
            let context = InputContext(
                sourceID: pinyin.sourceID,
                inputModeID: pinyin.inputModeID,
                keyboardLayoutID: layoutID
            )
            for key in jisKeys {
                XCTAssertEqual(MarkdownPunctuationMapping.replacement(
                    for: key.keyCode, flags: key.flags, keyboardType: 42
                ) { context }, key.replacement)
            }
            XCTAssertNil(MarkdownPunctuationMapping.replacement(
                for: CGKeyCode(kVK_ANSI_LeftBracket), flags: [], keyboardType: 42
            ) { context })
        }
    }

    func testKeyboardChangesTakeEffectOnTheNextKey() {
        for (keyboardType, expected): (Int64, String) in [(40, "]"), (42, "["), (41, "]"), (42, "[")] {
            XCTAssertEqual(MarkdownPunctuationMapping.replacement(
                for: CGKeyCode(kVK_ANSI_RightBracket), flags: [], keyboardType: keyboardType
            ) { self.pinyin }, expected)
        }
    }

    func testUnknownAndOutOfRangeKeyboardTypesPassThrough() {
        for keyboardType: Int64 in [0, 255, -1, Int64.max] {
            for key in mappedKeys {
                XCTAssertNil(MarkdownPunctuationMapping.replacement(
                    for: key.keyCode, flags: key.flags, keyboardType: keyboardType
                ) {
                    XCTFail("Unknown keyboard must not query the input source")
                    return self.pinyin
                })
            }
        }
    }

    func testRussianLettersPassThrough() {
        for sourceID in ["com.apple.keylayout.Russian", "com.apple.keylayout.RussianWin"] {
            let context = InputContext(sourceID: sourceID, inputModeID: nil, keyboardLayoutID: sourceID)
            for key in mappedKeys {
                XCTAssertNil(MarkdownPunctuationMapping.replacement(for: key.keyCode, flags: key.flags, keyboardType: 40) { context })
            }
        }
    }

    func testLatinSourcesPassThroughEvenOnSupportedLayouts() {
        for sourceID in ["com.apple.keylayout.ABC", "com.apple.keylayout.US"] {
            let context = InputContext(sourceID: sourceID, inputModeID: nil, keyboardLayoutID: sourceID)
            for key in mappedKeys {
                XCTAssertNil(MarkdownPunctuationMapping.replacement(for: key.keyCode, flags: key.flags, keyboardType: 40) { context })
            }
        }
    }

    func testRequiresBothTheVerifiedSourceAndMode() {
        let contexts = [
            InputContext(sourceID: pinyin.sourceID, inputModeID: nil, keyboardLayoutID: pinyin.keyboardLayoutID),
            InputContext(sourceID: pinyin.sourceID, inputModeID: "unknown", keyboardLayoutID: pinyin.keyboardLayoutID),
            InputContext(sourceID: "unknown", inputModeID: pinyin.inputModeID, keyboardLayoutID: pinyin.keyboardLayoutID),
            InputContext(
                sourceID: "com.apple.inputmethod.TCIM.Pinyin",
                inputModeID: "com.apple.inputmethod.TCIM.Pinyin",
                keyboardLayoutID: pinyin.keyboardLayoutID
            )
        ]

        for context in contexts {
            XCTAssertNil(MarkdownPunctuationMapping.replacement(for: CGKeyCode(kVK_ANSI_Comma), flags: .maskShift, keyboardType: 40) { context })
        }
    }

    func testUnsupportedUnderlyingLayoutsPassThrough() {
        for layoutID in ["com.apple.keylayout.Russian", "com.apple.keylayout.French", "custom.layout", ""] {
            let context = InputContext(
                sourceID: pinyin.sourceID,
                inputModeID: pinyin.inputModeID,
                keyboardLayoutID: layoutID
            )
            XCTAssertNil(MarkdownPunctuationMapping.replacement(for: CGKeyCode(kVK_ANSI_Comma), flags: .maskShift, keyboardType: 40) { context })
        }
    }

    func testSourceChangesTakeEffectOnTheNextKeyInBothDirections() {
        let latin = InputContext(sourceID: "com.apple.keylayout.ABC", inputModeID: nil, keyboardLayoutID: "com.apple.keylayout.ABC")
        var context = pinyin
        var contextReads = 0
        let provider = {
            contextReads += 1
            return context
        }

        XCTAssertEqual(
            MarkdownPunctuationMapping.replacement(for: CGKeyCode(kVK_ANSI_Comma), flags: .maskShift, keyboardType: 40, contextProvider: provider),
            "《》"
        )
        context = latin
        XCTAssertNil(MarkdownPunctuationMapping.replacement(for: CGKeyCode(kVK_ANSI_Comma), flags: .maskShift, keyboardType: 40, contextProvider: provider))
        context = pinyin
        XCTAssertEqual(
            MarkdownPunctuationMapping.replacement(for: CGKeyCode(kVK_ANSI_Comma), flags: .maskShift, keyboardType: 40, contextProvider: provider),
            "《》"
        )
        XCTAssertEqual(contextReads, 3)
    }

    func testUnderlyingLayoutChangesTakeEffectOnTheNextKey() {
        var context = pinyin
        XCTAssertEqual(MarkdownPunctuationMapping.replacement(for: CGKeyCode(kVK_ANSI_Comma), flags: .maskShift, keyboardType: 40) { context }, "《》")

        context = InputContext(sourceID: pinyin.sourceID, inputModeID: pinyin.inputModeID, keyboardLayoutID: "custom.layout")
        XCTAssertNil(MarkdownPunctuationMapping.replacement(for: CGKeyCode(kVK_ANSI_Comma), flags: .maskShift, keyboardType: 40) { context })
    }

    func testOtherPunctuationAndShiftVariantsPassThroughWithoutReadingTheInputSource() {
        let keys: [(CGKeyCode, CGEventFlags)] = [
            (CGKeyCode(kVK_ANSI_Comma), []),
            (CGKeyCode(kVK_ANSI_Period), []),
            (CGKeyCode(kVK_ANSI_4), []),
            (CGKeyCode(kVK_ANSI_Grave), .maskShift),
            (CGKeyCode(kVK_ANSI_LeftBracket), .maskShift),
            (CGKeyCode(kVK_ANSI_RightBracket), .maskShift),
            (CGKeyCode(kVK_ANSI_Quote), []),
            (CGKeyCode(kVK_ANSI_Quote), .maskShift),
            (CGKeyCode(kVK_ANSI_Semicolon), []),
            (CGKeyCode(kVK_ANSI_A), [])
        ]

        for (keyCode, flags) in keys {
            XCTAssertNil(MarkdownPunctuationMapping.replacement(for: keyCode, flags: flags, keyboardType: 40) {
                XCTFail("Unmapped key must not query the input source")
                return self.pinyin
            })
        }
    }

    func testShortcutsAndCapsLockPassThroughWithoutReadingTheInputSource() {
        let modifiers: [CGEventFlags] = [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn, .maskAlphaShift]
        let keys = mappedKeys + [(CGKeyCode(kVK_ANSI_Backslash), [], "]")]
        for keyboardType: Int64 in [40, 41, 42] {
            for modifier in modifiers {
                for key in keys {
                    XCTAssertNil(MarkdownPunctuationMapping.replacement(
                        for: key.keyCode, flags: key.flags.union(modifier), keyboardType: keyboardType
                    ) {
                        XCTFail("Modified key must not query the input source")
                        return self.pinyin
                    })
                }
            }
        }
    }

    func testJISShiftedBracketKeysPassThrough() {
        for keyCode in [kVK_ANSI_RightBracket, kVK_ANSI_Backslash] {
            XCTAssertNil(MarkdownPunctuationMapping.replacement(
                for: CGKeyCode(keyCode), flags: .maskShift, keyboardType: 42
            ) { self.pinyin })
        }
    }

    func testUnavailableInputContextPassesThrough() {
        XCTAssertNil(MarkdownPunctuationMapping.replacement(for: CGKeyCode(kVK_ANSI_Comma), flags: .maskShift, keyboardType: 40) { nil })
    }
}
