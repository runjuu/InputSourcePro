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
                      !event.isJustHide,
                      !self.preferencesVM.isHideIndicator(appKind)
                else { return self.justHidePublisher() }

                let app = appKind.getApp()

                // Function-key toggles are one-shot status changes: always use the
                // transient auto-hide path, never the persistent always-on / auto-show
                // flows that are tied to the focused input field.
                if case .functionKeyModeChanges = event {
                    return self.autoHidePublisher(event: event, inputSource: inputSource, appKind: appKind)
                }

                if self.preferencesVM.isShowAlwaysOnIndicator(app: app) {
                    return self.alwaysOnPublisher(event: event, inputSource: inputSource, appKind: appKind)
                } else if self.preferencesVM.needDetectFocusedFieldChanges(app: app) {
                    return self.autoShowPublisher(event: event, inputSource: inputSource, appKind: appKind)
                } else if event.isAppChangesWithUnchangedInputSource {
                    // App switch that keeps the same input source: nothing switched,
                    // so don't pop the indicator up.
                    return self.justHidePublisher()
                } else {
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
