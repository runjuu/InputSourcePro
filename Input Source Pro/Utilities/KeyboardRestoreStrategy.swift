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

    var systemImageName: String {
        switch self {
        case .UseDefaultKeyboardInstead:
            return "d.circle.fill"
        case .RestorePreviouslyUsedOne:
            return "arrow.uturn.left.circle.fill"
        }
    }

    var id: Self { self }
}
