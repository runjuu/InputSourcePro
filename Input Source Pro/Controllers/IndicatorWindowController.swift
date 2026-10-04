import AppKit
import AXSwift
import Carbon
import Combine
import CombineExt
import SnapKit

@MainActor
class IndicatorWindowController: FloatWindowController {
    let permissionsVM: PermissionsVM
    let preferencesVM: PreferencesVM
    let indicatorVM: IndicatorVM
    let applicationVM: ApplicationVM
    let inputSourceVM: InputSourceVM

    let indicatorVC = IndicatorViewController()
    let alwaysOnIndicator = AlwaysOnIndicatorWindowController()

    var isActive = false {
        didSet {
            IndicatorDiagnostics.record("indicator.active old=\(oldValue) new=\(isActive) frame=\(String(describing: window?.frame))")
            if isActive {
                indicatorVC.view.animator().alphaValue = 1
                window?.displayIfNeeded()
                active()
            } else {
                indicatorVC.view.animator().alphaValue = 0
                deactive()
            }

            alwaysOnIndicator.defaultIndicatorFrame = isActive ? window?.frame : nil
        }
    }

    var cancelBag = CancelBag()

    init(
        permissionsVM: PermissionsVM,
        preferencesVM: PreferencesVM,
        indicatorVM: IndicatorVM,
        applicationVM: ApplicationVM,
        inputSourceVM: InputSourceVM
    ) {
        self.permissionsVM = permissionsVM
        self.preferencesVM = preferencesVM
        self.indicatorVM = indicatorVM
        self.applicationVM = applicationVM
        self.inputSourceVM = inputSourceVM

        super.init()

        contentViewController = indicatorVC

        IndicatorDiagnostics.record("indicator.init screens=\(NSScreen.screens.map { "frame=\($0.frame) visible=\($0.visibleFrame) scale=\($0.backingScaleFactor)" })")

        let indicatorPublisher = indicatorVM.activateEventPublisher
            .receive(on: DispatchQueue.main)
            .map { (event: $0, inputSource: self.indicatorVM.state.inputSource) }
            .flatMapLatest { [weak self] params -> AnyPublisher<Void, Never> in
                let event = params.event
                let inputSource = params.inputSource
                IndicatorDiagnostics.record("activation.received event=\(event.diagnosticDescription) renderedSource=\(inputSource.persistentIdentifier) frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")

                guard let self = self else { return Empty().eraseToAnyPublisher() }
                guard let appKind = self.applicationVM.appKind,
                      !preferencesVM.isHideIndicator(appKind)
                else {
                    IndicatorDiagnostics.record("activation.hide reason=missing-or-excluded-app")
                    return self.justHidePublisher()
                }

                let app = appKind.getApp()

                let mode = Self.activationMode(
                    event: event,
                    focusedField: preferencesVM.needDetectFocusedFieldChanges(app: app)
                )
                IndicatorDiagnostics.record("activation.mode mode=\(mode) app=\(app.bundleIdentifier ?? "?") pid=\(app.processIdentifier)")
                switch mode {
                case .hide:
                    return self.justHidePublisher()
                case .autoShow:
                    return self.autoShowPublisher(event: event, inputSource: inputSource, appKind: appKind)
                case .autoHide:
                    return self.autoHidePublisher(event: event, inputSource: inputSource, appKind: appKind)
                }
            }
            .eraseToAnyPublisher()

        // While the indicator is pinned to the mouse (see watchAlwaysNearMouse),
        // that pipeline owns visibility and position, so this one stays idle.
        let isAlwaysNearMouse = preferencesVM.$preferences
            .map(\.isAlwaysDisplayIndicatorNearMouseEnabled)
            .removeDuplicates()

        Publishers.CombineLatest(indicatorVM.indicatorIsSuspendedPublisher, isAlwaysNearMouse)
            .map { isSuspended, isAlwaysNearMouse in isSuspended || isAlwaysNearMouse }
            .removeDuplicates()
            .flatMapLatest { [weak self] isIdle -> AnyPublisher<Void, Never> in
                IndicatorDiagnostics.record("activation.pipeline idle=\(isIdle)")
                if isIdle { return self?.justHidePublisher() ?? Empty().eraseToAnyPublisher() }
                return indicatorPublisher
            }
            .sink { _ in }
            .store(in: cancelBag)

        watchAlwaysNearMouse()
        watchAlwaysOnIndicator()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension IndicatorWindowController {
    enum ActivationMode {
        case hide, autoHide, autoShow
    }

    static func activationMode(
        event: IndicatorVM.ActivateEvent,
        focusedField: Bool
    ) -> ActivationMode {
        if event.isJustHide {
            return .hide
        }

        if focusedField {
            return .autoShow
        }

        return event.isAppChangesWithUnchangedInputSource ? .hide : .autoHide
    }
}
