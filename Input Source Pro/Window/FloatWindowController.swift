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
        IndicatorDiagnostics.record("window.orderFront owner=\(type(of: self)) frame=\(String(describing: window?.frame))")
        window?.orderFront(nil)
    }

    func deactive() {
        IndicatorDiagnostics.record("window.orderOut owner=\(type(of: self)) frame=\(String(describing: window?.frame))")
        window?.orderOut(nil)
    }

    func windowDidMove(_ notification: Notification) {
        IndicatorDiagnostics.record("window.didMove owner=\(type(of: self)) frame=\(String(describing: window?.frame)) visible=\(window?.isVisible ?? false)")
    }

    func windowDidResize(_ notification: Notification) {
        IndicatorDiagnostics.record("window.didResize owner=\(type(of: self)) frame=\(String(describing: window?.frame)) visible=\(window?.isVisible ?? false)")
    }

    func moveTo(point: CGPoint) {
        window?.setFrameOrigin(point)
    }
}
