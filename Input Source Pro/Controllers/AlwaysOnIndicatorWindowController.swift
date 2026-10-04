import AppKit
import Combine

@MainActor
final class AlwaysOnIndicatorWindowController: FloatWindowController {
    private var cancelBag = CancelBag()

    var position: CGPoint? {
        didSet { updateVisibility() }
    }

    var isDefaultIndicatorVisible = false {
        didSet { updateVisibility() }
    }

    func observe(
        configs: AnyPublisher<IndicatorViewConfig, Never>,
        positions: AnyPublisher<CGPoint?, Never>
    ) {
        cancelBag.cancel()

        configs
            .sink { [weak self] in self?.update(config: $0) }
            .store(in: cancelBag)

        positions
            .sink { [weak self] in self?.position = $0 }
            .store(in: cancelBag)
    }

    func update(config: IndicatorViewConfig) {
        IndicatorDiagnostics.record("alwaysOn.content source=\(config.inputSource.persistentIdentifier) capsLock=\(config.showsCapsLock)")
        guard let view = config.renderAlwaysOn() else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            window?.contentView = view
            window?.setContentSize(view.fittingSize)
            updateVisibility()
        }
    }

    func reorderOnActiveSpace() {
        guard window?.isVisible == true else { return }

        deactive()
        active()
    }

    private func updateVisibility() {
        IndicatorDiagnostics.record("alwaysOn.visibility point=\(String(describing: position)) defaultVisible=\(isDefaultIndicatorVisible) frame=\(String(describing: window?.frame))")
        guard let position = position,
              let window = window,
              window.contentView != nil
        else {
            deactive()
            return
        }

        moveTo(point: CGPoint(x: position.x - window.frame.width / 2, y: position.y))

        if isDefaultIndicatorVisible {
            IndicatorDiagnostics.record("alwaysOn.hidden reason=default-visible")
            deactive()
        } else if !window.isVisible {
            active()
        }
    }
}
