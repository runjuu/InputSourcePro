import AppKit
import AXSwift
import Combine
import CombineExt

extension IndicatorVM {
    @MainActor
    enum ActivateEvent {
        case justHide
        case longMouseDown
        case appChanges(current: AppKind?, prev: AppKind?, inputSourceDidChange: Bool)
        case inputSourceChanges(InputSource, InputSourceChangeReason)
        case functionKeyModeChanges(FKeyMode)
        case capsLockChanges(Bool)

        func isAppChangesWithSameAppOrWebsite() -> Bool {
            switch self {
            case let .appChanges(current, prev, _):
                return current?.isSameAppOrWebsite(with: prev) == true
            case .inputSourceChanges:
                return false
            case .functionKeyModeChanges, .capsLockChanges:
                return false
            case .longMouseDown:
                return false
            case .justHide:
                return false
            }
        }

        var isAppChangesWithUnchangedInputSource: Bool {
            switch self {
            case let .appChanges(_, _, inputSourceDidChange):
                return !inputSourceDidChange
            default:
                return false
            }
        }

        var isJustHide: Bool {
            switch self {
            case .justHide: return true
            default: return false
            }
        }

        func shouldActivateInitially(
            onAppSwitch: Bool,
            onInputFocus: Bool,
            isInputFocused: @autoclosure () -> Bool
        ) -> Bool {
            switch self {
            case .inputSourceChanges, .longMouseDown, .functionKeyModeChanges, .capsLockChanges:
                // These events have already passed their own trigger preferences.
                return true
            case let .appChanges(_, _, inputSourceDidChange):
                return (onAppSwitch && inputSourceDidChange) || (onInputFocus && isInputFocused())
            case .justHide:
                return false
            }
        }
    }

    func longMouseDownPublisher() -> AnyPublisher<ActivateEvent, Never> {
        preferencesVM.$preferences
            .map(\.isActiveWhenLongpressLeftMouse)
            .removeDuplicates()
            .flatMapLatest { isEnabled -> AnyPublisher<ActivateEvent, Never> in
                guard isEnabled else { return Empty().eraseToAnyPublisher() }

                return AnyPublisher<NSEvent, Never>
                    .create { observer in
                        let monitor = NSEvent.addGlobalMonitorForEvents(
                            matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged],
                            handler: { observer.send($0) }
                        )

                        return AnyCancellable {
                            if let monitor = monitor {
                                NSEvent.removeMonitor(monitor)
                            }
                        }
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
                    .mapTo(.longMouseDown)
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    func functionKeyModeChangesPublisher() -> AnyPublisher<ActivateEvent, Never> {
        functionKeyModeChangeSubject
            .map { ActivateEvent.functionKeyModeChanges($0) }
            .eraseToAnyPublisher()
    }

    func capsLockChangesPublisher() -> AnyPublisher<ActivateEvent, Never> {
        Self.capsLockChangesPublisher(
            states: $isCapsLockOn.eraseToAnyPublisher(),
            enabled: preferencesVM.$preferences.map(\.isShowCapsLockStatus).eraseToAnyPublisher()
        )
    }

    static func capsLockChangesPublisher(
        states: AnyPublisher<Bool, Never>,
        enabled: AnyPublisher<Bool, Never>
    ) -> AnyPublisher<ActivateEvent, Never> {
        states
            .removeDuplicates()
            .dropFirst()
            .withLatestFrom(enabled) { (state: $0, enabled: $1) }
            .filter(\.enabled)
            .map { .capsLockChanges($0.state) }
            .eraseToAnyPublisher()
    }

    func stateChangesPublisher() -> AnyPublisher<ActivateEvent, Never> {
        $state
            .withPrevious()
            .map { [weak self] previous, current -> ActivateEvent in
                if let preferencesVM = self?.preferencesVM {
                    if previous?.appKind?.getId() != current.appKind?.getId() {
                        let event = ActivateEvent.appChanges(
                            current: current.appKind,
                            prev: previous?.appKind,
                            inputSourceDidChange: previous?.inputSource.persistentIdentifier != current.inputSource.persistentIdentifier
                        )

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

                    if previous?.inputSource.persistentIdentifier != current.inputSource.persistentIdentifier {
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
        case let .appChanges(current, prev, inputSourceDidChange):
            return "appChanges(\(String(describing: current)), \(String(describing: prev)), inputSourceDidChange: \(inputSourceDidChange))"
        case .inputSourceChanges:
            return "inputSourceChanges"
        case let .functionKeyModeChanges(mode):
            return "functionKeyModeChanges(\(mode.rawValue))"
        case let .capsLockChanges(isOn):
            return "capsLockChanges(\(isOn))"
        case .longMouseDown:
            return "longMouseDown"
        case .justHide:
            return "justHide"
        }
    }
}

extension IndicatorVM.ActivateEvent {
    // AppKind's description can include a browser URL; log only process identity.
    var diagnosticDescription: String {
        switch self {
        case let .appChanges(current, previous, changed):
            return "appChanges(pid=\(current?.getApp().processIdentifier ?? 0),previousPID=\(previous?.getApp().processIdentifier ?? 0),sourceChanged=\(changed))"
        case let .inputSourceChanges(source, reason):
            return "inputSourceChanges(source=\(source.persistentIdentifier),reason=\(reason.diagnosticDescription))"
        default:
            return description
        }
    }
}

extension IndicatorVM.InputSourceChangeReason {
    var diagnosticDescription: String {
        switch self {
        case .noChanges: return "noChanges"
        case .system: return "system"
        case .shortcut: return "shortcut"
        case .appSpecified: return "appSpecified"
        }
    }
}
