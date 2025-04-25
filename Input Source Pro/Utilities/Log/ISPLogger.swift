import AppKit
import os

class ISPLogger {
    let category: String

    var disabled: Bool

    init(category: String, disabled: Bool = false) {
        self.category = category
        self.disabled = disabled
    }

    func debug(_ getString: () -> String) {
        if disabled { return }
        // TODO: - Add toggle
        #if DEBUG
            let str = getString()
            let formatter = DateFormatter()
            formatter.dateFormat = "H:mm:ss.SSSS"
            print(formatter.string(from: Date()), "[\(category)]", str)
        #endif
    }
}
