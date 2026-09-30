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

    var isActive = false {
        didSet {
            if isActive {
                indicatorVC.view.animator().alphaValue = 1
                window?.displayIfNeeded()
                active()
            } else {
                indicatorVC.view.animator().alphaValue = 0
                deactive()
            }
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

        let indicatorPublisher = indicatorVM.activateEventPublisher
            .receive(on: DispatchQueue.main)
            .map { (event: $0, inputSource: self.indicatorVM.state.inputSource) }
            .flatMapLatest { [weak self] params -> AnyPublisher<Void, Never> in
                let event = params.event
                let inputSource = params.inputSource

                guard let self = self else { return Empty().eraseToAnyPublisher() }
                guard let appKind = self.applicationVM.appKind,
                      !preferencesVM.isHideIndicator(appKind)
                else { return self.justHidePublisher() }

                let app = appKind.getApp()

                switch Self.activationMode(
                    event: event,
                    alwaysOn: preferencesVM.isShowAlwaysOnIndicator(app: app),
                    focusedField: preferencesVM.needDetectFocusedFieldChanges(app: app)
                ) {
                case .hide:
                    return self.justHidePublisher()
                case .alwaysOn:
                    return self.alwaysOnPublisher(event: event, inputSource: inputSource, appKind: appKind)
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

        Publishers.CombineLatest(indicatorVM.screenIsLockedPublisher, isAlwaysNearMouse)
            .map { isLocked, isAlwaysNearMouse in isLocked || isAlwaysNearMouse }
            .removeDuplicates()
            .flatMapLatest { isIdle in isIdle ? Empty().eraseToAnyPublisher() : indicatorPublisher }
            .sink { _ in }
            .store(in: cancelBag)

        watchAlwaysNearMouse()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension IndicatorWindowController {
    enum ActivationMode {
        case hide, autoHide, autoShow, alwaysOn
    }

    static func activationMode(
        event: IndicatorVM.ActivateEvent,
        alwaysOn: Bool,
        focusedField: Bool
    ) -> ActivationMode {
        if event.isJustHide {
            return .hide
        }

        // Function-key feedback is transient even when field tracking is enabled.
        if case .functionKeyModeChanges = event {
            return .autoHide
        }

        if alwaysOn {
            return .alwaysOn
        }

        if focusedField {
            return .autoShow
        }

        return event.isAppChangesWithUnchangedInputSource ? .hide : .autoHide
    }
}
