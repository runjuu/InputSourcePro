import AppKit

class FloatWindow: NSPanel {
    private let _canBecomeKey: Bool

    override var canBecomeKey: Bool {
        return _canBecomeKey
    }

    init(
        canBecomeKey: Bool,
        contentRect: CGRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        _canBecomeKey = canBecomeKey

        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )

        level = .screenSaver

        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        styleMask.insert(.nonactivatingPanel)

        collectionBehavior = [
            .moveToActiveSpace,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
    }
}
