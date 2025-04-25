import AppKit

class FloatWindowController: NSWindowController, NSWindowDelegate {
    init(canBecomeKey: Bool = false) {
        super.init(window: FloatWindow(
            canBecomeKey: canBecomeKey,
            contentRect: CGRect(origin: .zero, size: .zero),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        ))

        window?.delegate = self
        window?.ignoresMouseEvents = true
        window?.standardWindowButton(.zoomButton)?.isEnabled = false
        window?.standardWindowButton(.miniaturizeButton)?.isEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension FloatWindowController {
    func active() {
        window?.orderFront(nil)
    }

    func deactive() {
        window?.orderOut(nil)
    }

    func moveTo(point: CGPoint) {
        window?.setFrameOrigin(point)
    }
}
