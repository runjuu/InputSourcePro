import Carbon
import Cocoa
import Combine
import CoreGraphics

private let nameMap = [
    "com.apple.inputmethod.Korean.2SetKorean": "한",
    "com.apple.inputmethod.Korean.3SetKorean": "한",
    "com.apple.inputmethod.Korean.390Sebulshik": "한",
    "com.apple.inputmethod.Korean.GongjinCheongRomaja": "한",
    "com.apple.inputmethod.Korean.HNCRomaja": "한",

    "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese": "あ",
    "com.apple.inputmethod.Kotoeri.KanaTyping.Japanese": "あ",

    "com.apple.keylayout.Irish": "IE",
    "com.apple.keylayout.Dvorak-Right": "DV",
    "com.apple.keylayout.DVORAK-QWERTYCMD": "DV",
    "com.apple.keylayout.Dvorak-Left": "DV",
    "com.apple.keylayout.Dvorak": "DV",
    "com.apple.keylayout.Colemak": "CO",
    "com.apple.keylayout.British-PC": "GB",
    "com.apple.keylayout.British": "GB",
    "com.apple.keylayout.Australian": "AU",
    "com.apple.keylayout.ABC-India": "IN",
    "com.apple.keylayout.USInternational-PC": "US",
    "com.apple.keylayout.US": "US",
    "com.apple.keylayout.USExtended": "A",
    "com.apple.keylayout.ABC": "A",
    "com.apple.keylayout.Canadian": "CA",

    "com.apple.inputmethod.TCIM.Cangjie": "倉",
    "com.apple.inputmethod.TCIM.Pinyin": "繁拼",
    "com.apple.inputmethod.TCIM.Shuangpin": "雙",
    "com.apple.inputmethod.TCIM.WBH": "畫",
    "com.apple.inputmethod.TCIM.Jianyi": "速",
    "com.apple.inputmethod.TCIM.Zhuyin": "注",
    "com.apple.inputmethod.TCIM.ZhuyinEten": "注",

    "com.apple.inputmethod.TYIM.Sucheng": "速",
    "com.apple.inputmethod.TYIM.Stroke": "畫",
    "com.apple.inputmethod.TYIM.Phonetic": "粤拼",
    "com.apple.inputmethod.TYIM.Cangjie": "倉",

    "com.apple.inputmethod.SCIM.WBX": "五",
    "com.apple.inputmethod.SCIM.WBH": "画",
    "com.apple.inputmethod.SCIM.Shuangpin": "双",
    "com.apple.inputmethod.SCIM.ITABC": "拼",
]

extension InputSource {
    func getSystemLabelName() -> String? {
        return nameMap[id]
    }
}
