import Cocoa
import SwiftUI

extension KeyboardConfig {
    var textColor: Color? {
        get {
            if let hex = textColorHex {
                return Color(hex: hex)
            } else {
                return nil
            }
        }

        set {
            textColorHex = newValue?.hexWithAlpha
        }
    }

    var bgColor: Color? {
        get {
            if let hex = bgColorHex {
                return Color(hex: hex)
            } else {
                return nil
            }
        }

        set {
            bgColorHex = newValue?.hexWithAlpha
        }
    }
}
