import AppKit
import SnapKit

@MainActor
class IndicatorViewController: NSViewController {
    let hoverableView = NSViewHoverable(frame: .zero)

    private(set) var config: IndicatorViewConfig? = nil {
        didSet {
            nextAlwaysOnView = config?.renderAlwaysOn()
            nextNormalView = config?.render()

            if normalView == nil || alwaysOnView == nil {
                refresh()
            }
        }
    }

    var fittingSize: CGSize? {
        nextNormalView?.fittingSize ?? normalView?.fittingSize
    }

    private(set) var nextNormalView: NSView? = nil
    private(set) var nextAlwaysOnView: NSView? = nil

    private(set) var normalView: NSView? = nil {
        didSet {
            oldValue?.removeFromSuperview()

            if let normalView = normalView {
                view.addSubview(normalView)

                normalView.snp.makeConstraints { make in
                    let size = normalView.fittingSize

                    make.edges.equalToSuperview()
                    make.width.equalTo(size.width)
                    make.height.equalTo(size.height)
                }
            }
        }
    }

    private(set) var alwaysOnView: NSView? = nil {
        didSet {
            oldValue?.removeFromSuperview()

            if let alwaysOnView = alwaysOnView {
                alwaysOnView.alphaValue = 0
                view.addSubview(alwaysOnView)

                alwaysOnView.snp.makeConstraints { make in
                    make.leading.bottom.equalToSuperview()
                }
            }
        }
    }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func prepare(config: IndicatorViewConfig) {
        self.config = config
    }

    func refresh() {
        if let nextNormalView = nextNormalView {
            normalView = nextNormalView
            self.nextNormalView = nil
        }

        if let nextAlwaysOnView = nextAlwaysOnView {
            alwaysOnView = nextAlwaysOnView
            self.nextAlwaysOnView = nil
        }
    }

    func showAlwaysOnView() {
        normalView?.animator().alphaValue = 0
        alwaysOnView?.animator().alphaValue = 1
    }

    override func loadView() {
        view = hoverableView
    }
}
