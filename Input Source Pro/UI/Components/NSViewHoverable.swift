import AppKit
import Combine

class NSViewHoverable: NSView {
    private let hoverdSubject: PassthroughSubject<Bool, Never>

    let hoverdPublisher: AnyPublisher<Bool, Never>

    override init(frame frameRect: NSRect) {
        hoverdSubject = PassthroughSubject()
        hoverdPublisher = hoverdSubject.eraseToAnyPublisher()

        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }

        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseMoved(with _: NSEvent) {
        hoverdSubject.send(true)
    }

    override func mouseExited(with _: NSEvent) {
        hoverdSubject.send(false)
    }
}
