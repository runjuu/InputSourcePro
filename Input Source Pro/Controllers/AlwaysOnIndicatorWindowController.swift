import AppKit
import Combine

@MainActor
final class AlwaysOnIndicatorWindowController: FloatWindowController {
    private var cancelBag = CancelBag()

    var position: CGPoint? {
        didSet { updateVisibility() }
    }

    var defaultIndicatorFrame: CGRect? {
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
        guard let view = config.renderAlwaysOn() else { return }

        window?.contentView = view
        window?.setContentSize(view.fittingSize)
        updateVisibility()
    }

    func reorderOnActiveSpace() {
        guard window?.isVisible == true else { return }

        deactive()
        active()
    }

    private func updateVisibility() {
        guard let position = position,
              let window = window,
              window.contentView != nil
        else {
            deactive()
            return
        }

        moveTo(point: position)

        if let defaultIndicatorFrame = defaultIndicatorFrame,
           defaultIndicatorFrame.intersects(window.frame)
        {
            deactive()
        } else if !window.isVisible {
            active()
        }
    }
}
