import SwiftUI

enum KeyboardRestoreStrategy: String, CaseIterable, Identifiable {
    case UseDefaultKeyboardInstead
    case RestorePreviouslyUsedOne

    var name: String {
        switch self {
        case .UseDefaultKeyboardInstead:
            return "Use Default Keyboard Instead".i18n()
        case .RestorePreviouslyUsedOne:
            return "Restore Previously Used One".i18n()
        }
    }

    var SFSymbol: String {
        switch self {
        case .UseDefaultKeyboardInstead:
            return "􀀊"
        case .RestorePreviouslyUsedOne:
            return "􀅉"
        }
    }

    var id: Self { self }
}
