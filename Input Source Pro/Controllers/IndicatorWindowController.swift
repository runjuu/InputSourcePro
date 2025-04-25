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
                      !preferencesVM.isHideIndicator(appKind)
                else { return self.justHidePublisher() }

                let app = appKind.getApp()

                if preferencesVM.isShowAlwaysOnIndicator(app: app) {
                    return self.alwaysOnPublisher(event: event, inputSource: inputSource, appKind: appKind)
                } else if preferencesVM.needDetectFocusedFieldChanges(app: app) {
                    return self.autoShowPublisher(event: event, inputSource: inputSource, appKind: appKind)
                } else {
                    return self.autoHidePublisher(event: event, inputSource: inputSource, appKind: appKind)
                }
            }
            .eraseToAnyPublisher()

        indicatorVM.screenIsLockedPublisher
            .flatMapLatest { isLocked in isLocked ? Empty().eraseToAnyPublisher() : indicatorPublisher }
            .sink { _ in }
            .store(in: cancelBag)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
