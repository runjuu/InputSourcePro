import AppKit
import AXSwift
import Combine
import CombineExt

extension IndicatorVM {
    @MainActor
    enum ActivateEvent {
        case justHide
        case longMouseDown
        case appChanges(current: AppKind?, prev: AppKind?)
        case inputSourceChanges(InputSource, InputSourceChangeReason)

        func isAppChangesWithSameAppOrWebsite() -> Bool {
            switch self {
            case let .appChanges(current, prev):
                return current?.isSameAppOrWebsite(with: prev) == true
            case .inputSourceChanges:
                return false
            case .longMouseDown:
                return false
            case .justHide:
                return false
            }
        }

        var isJustHide: Bool {
            switch self {
            case .justHide: return true
            default: return false
            }
        }
    }

    func longMouseDownPublisher() -> AnyPublisher<ActivateEvent, Never> {
        AnyPublisher<NSEvent, Never>
            .create { observer in
                let monitor = NSEvent.addGlobalMonitorForEvents(
                    matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged],
                    handler: { observer.send($0) }
                )

                return AnyCancellable { NSEvent.removeMonitor(monitor!) }
            }
            .flatMapLatest { event -> AnyPublisher<Void, Never> in
                if event.type == .leftMouseDown {
                    return Timer
                        .delay(seconds: 0.35)
                        .mapToVoid()
                        .eraseToAnyPublisher()
                } else {
                    return Empty<Void, Never>().eraseToAnyPublisher()
                }
            }
            .filter { [weak self] _ in
                self?.preferencesVM.preferences.isActiveWhenLongpressLeftMouse ?? false
            }
            .mapTo(.longMouseDown)
    }

    func stateChangesPublisher() -> AnyPublisher<ActivateEvent, Never> {
        $state
            .withPrevious()
            .map { [weak self] previous, current -> ActivateEvent in
                if let preferencesVM = self?.preferencesVM {
                    if previous?.appKind?.getId() != current.appKind?.getId() {
                        let event = ActivateEvent.appChanges(current: current.appKind, prev: previous?.appKind)

                        if preferencesVM.preferences.isActiveWhenSwitchApp || preferencesVM.preferences.isActiveWhenFocusedElementChangesEnabled {
                            if preferencesVM.preferences.isHideWhenSwitchAppWithForceKeyboard {
                                switch current.inputSourceChangeReason {
                                case let .appSpecified(status):
                                    switch status {
                                    case .cached:
                                        return event
                                    case .specified:
                                        return .justHide
                                    }
                                default:
                                    return .justHide
                                }
                            } else {
                                return event
                            }
                        } else {
                            return .justHide
                        }
                    }

                    if previous?.inputSource.id != current.inputSource.id {
                        switch current.inputSourceChangeReason {
                        case .noChanges:
                            return .justHide
                        case .system, .shortcut, .appSpecified:
                            guard preferencesVM.preferences.isActiveWhenSwitchInputSource else { return .justHide }
                            return .inputSourceChanges(current.inputSource, current.inputSourceChangeReason)
                        }
                    }
                }

                return .justHide
            }
            .eraseToAnyPublisher()
    }
}

extension IndicatorVM.ActivateEvent: @preconcurrency CustomStringConvertible {
    var description: String {
        switch self {
        case let .appChanges(current, prev):
            return "appChanges(\(String(describing: current)), \(String(describing: prev))"
        case .inputSourceChanges:
            return "inputSourceChanges"
        case .longMouseDown:
            return "longMouseDown"
        case .justHide:
            return "justHide"
        }
    }
}
