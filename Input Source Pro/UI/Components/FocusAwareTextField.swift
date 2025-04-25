import AppKit
import RxRelay

class FocusAwareTextField: NSTextField {
    let focus$ = PublishRelay<Bool>()

    override func becomeFirstResponder() -> Bool {
        focus$.accept(true)
        return super.becomeFirstResponder()
    }
}
