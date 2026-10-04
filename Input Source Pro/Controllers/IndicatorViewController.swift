import AppKit
import SnapKit

@MainActor
class IndicatorViewController: NSViewController {
    enum Layout {
        case floatingWindow, preview
    }

    enum DisplayMode {
        case normal, alwaysOn
    }

    private let layout: Layout
    private var displayMode: DisplayMode = .normal
    private var caretContentOffset = CGPoint.zero
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

                    switch layout {
                    case .floatingWindow:
                        make.leading.bottom.equalToSuperview()
                    case .preview:
                        // SwiftUI needs the full content bounds to size and align previews.
                        make.edges.equalToSuperview()
                    }
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
                    make.leading.equalToSuperview().offset(caretContentOffset.x)
                    make.bottom.equalToSuperview().offset(-caretContentOffset.y)
                }
            }
        }
    }

    init(layout: Layout = .floatingWindow) {
        self.layout = layout
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func prepare(config: IndicatorViewConfig) {
        IndicatorDiagnostics.record("view.prepare source=\(config.inputSource.persistentIdentifier) capsLock=\(config.showsCapsLock) badge=\(config.badge != nil) before=\(view.frame)")
        self.config = config
        IndicatorDiagnostics.record("view.prepared fitting=\(String(describing: fittingSize))")
    }

    func refresh() {
        IndicatorDiagnostics.record("view.refresh normalPending=\(nextNormalView != nil) alwaysOnPending=\(nextAlwaysOnView != nil) frame=\(view.frame)")
        if let nextNormalView = nextNormalView {
            normalView = nextNormalView
            self.nextNormalView = nil
        }

        if let nextAlwaysOnView = nextAlwaysOnView {
            alwaysOnView = nextAlwaysOnView
            self.nextAlwaysOnView = nil
        }
        applyDisplayMode()
    }

    /// Keep the displayed content unchanged while an asynchronous position query
    /// runs, then commit its replacement and frame in the same AppKit transaction.
    func refresh(at point: CGPoint, displayMode: DisplayMode = .normal) {
        guard let window = view.window, let size = fittingSize else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            self.displayMode = displayMode
            refresh()
            view.layoutSubtreeIfNeeded()
            var origin = point
            var frame = CGRect(origin: origin, size: CGSize(width: ceil(size.width), height: ceil(size.height)))
            caretContentOffset = .zero
            if displayMode == .alwaysOn, config?.badge == nil, let alwaysOnView = alwaysOnView {
                let compactSize = alwaysOnView.fittingSize
                origin.x -= compactSize.width / 2
                let layout = PixelAlignedWindowLayout(
                    origin: NSScreen.pixelAlignedOrigin(origin, near: point),
                    size: CGSize(width: max(size.width, compactSize.width), height: max(size.height, compactSize.height))
                )
                frame = layout.frame
                caretContentOffset = layout.contentOffset
            }
            alwaysOnView?.snp.updateConstraints {
                $0.leading.equalToSuperview().offset(caretContentOffset.x)
                $0.bottom.equalToSuperview().offset(-caretContentOffset.y)
            }
            window.setFrame(frame, display: true)
            view.layoutSubtreeIfNeeded()
        }
    }

    func showAlwaysOnView() {
        displayMode = .alwaysOn
        applyDisplayMode()
    }

    func showNormalView() {
        displayMode = .normal
        applyDisplayMode()
    }

    private func applyDisplayMode() {
        // Status badges retain their glyph and title even at the caret.
        let showsAlwaysOn = displayMode == .alwaysOn && config?.badge == nil
        IndicatorDiagnostics.record("view.mode requested=\(displayMode) compact=\(showsAlwaysOn)")
        normalView?.alphaValue = showsAlwaysOn ? 0 : 1
        alwaysOnView?.alphaValue = showsAlwaysOn ? 1 : 0
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        IndicatorDiagnostics.record("view.layout frame=\(view.frame) window=\(String(describing: view.window?.frame)) normal=\(String(describing: normalView?.frame)) normalAlpha=\(normalView?.alphaValue ?? -1) alwaysOn=\(String(describing: alwaysOnView?.frame)) alwaysOnAlpha=\(alwaysOnView?.alphaValue ?? -1)")
    }

    override func loadView() {
        view = hoverableView
    }
}
