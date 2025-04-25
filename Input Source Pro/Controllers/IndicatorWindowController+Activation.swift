import AppKit
import AXSwift
import Combine
import CombineExt

// MARK: - Default indicator: auto hide

extension IndicatorWindowController {
    func autoHidePublisher(
        event: IndicatorVM.ActivateEvent,
        inputSource: InputSource,
        appKind: AppKind
    ) -> AnyPublisher<Void, Never> {
        return Just(event)
            .tap { [weak self] in self?.updateIndicator(event: $0, inputSource: inputSource) }
            .flatMapLatest { [weak self] _ -> AnyPublisher<Void, Never> in
                guard let self = self,
                      let appSize = self.getAppSize()
                else { return Empty().eraseToAnyPublisher() }

                return self.preferencesVM
                    .getIndicatorPositionPublisher(appSize: appSize, app: appKind.getApp())
                    .compactMap { $0 }
                    .first()
                    .tap { self.moveIndicator(position: $0) }
                    .flatMapLatest { _ -> AnyPublisher<Bool, Never> in
                        Publishers.Merge(
                            Timer.delay(seconds: 1).mapToVoid(),
                            // hover event
                            self.indicatorVC.hoverableView.hoverdPublisher
                                .filter { $0 }
                                .first()
                                .flatMapLatest { _ in
                                    Timer.delay(seconds: 0.15)
                                }
                                .mapToVoid()
                        )
                        .first()
                        .mapTo(false)
                        .prepend(true)
                        .tap { isActive in
                            self.isActive = isActive
                        }
                        .eraseToAnyPublisher()
                    }
                    .mapToVoid()
                    .eraseToAnyPublisher()
            }
            .mapToVoid()
            .eraseToAnyPublisher()
    }
}

// MARK: - Default indicator: auto show

extension IndicatorWindowController {
    func autoShowPublisher(
        event: IndicatorVM.ActivateEvent,
        inputSource: InputSource,
        appKind: AppKind
    ) -> AnyPublisher<Void, Never> {
        let app = appKind.getApp()
        let application = app.getApplication(preferencesVM: preferencesVM)

        let needActivateAtFirstTime = {
            if preferencesVM.preferences.isActiveWhenSwitchApp {
                return true
            }

            if preferencesVM.preferences.isActiveWhenFocusedElementChangesEnabled,
               let focusedUIElement = app.focuedUIElement(application: application),
               UIElement.isInputContainer(focusedUIElement)
            {
                return true
            }

            return false
        }()

        if !needActivateAtFirstTime, isActive {
            isActive = false
        }

        return app
            .watchAX([.focusedUIElementChanged], [.application, .window])
            .compactMap { _ in app.focuedUIElement(application: application) }
            .removeDuplicates()
            .filter { UIElement.isInputContainer($0) }
            .mapTo(true)
            .prepend(needActivateAtFirstTime)
            .filter { $0 }
            .compactMap { [weak self] _ in self?.autoHidePublisher(event: event, inputSource: inputSource, appKind: appKind) }
            .switchToLatest()
            .eraseToAnyPublisher()
    }
}

// MARK: - Just hide indicator

extension IndicatorWindowController {
    func justHidePublisher() -> AnyPublisher<Void, Never> {
        Just(true)
            .tap { [weak self] _ in self?.isActive = false }
            .mapToVoid()
            .eraseToAnyPublisher()
    }
}

// MARK: - AlwaysOn

extension IndicatorWindowController {
    @MainActor
    enum AlwaysOn {
        enum Event {
            case cursorMoved, showAlwaysOnIndicator, scrollStart, scrollEnd
        }

        struct State {
            typealias Changes = (current: State, prev: State)

            static let initial = State(isShowAlwaysOnIndicator: false, isScrolling: false)

            var isShowAlwaysOnIndicator: Bool
            var isScrolling: Bool

            func reducer(_ event: Event) -> State {
                switch event {
                case .scrollStart:
                    return update {
                        $0.isScrolling = true
                    }
                case .scrollEnd:
                    return update {
                        $0.isScrolling = false
                    }
                case .showAlwaysOnIndicator:
                    return update {
                        $0.isShowAlwaysOnIndicator = true
                    }
                case .cursorMoved:
                    return self
                }
            }

            func update(_ change: (inout State) -> Void) -> State {
                var draft = self

                change(&draft)

                return draft
            }
        }

        static func statePublisher(app: NSRunningApplication) -> AnyPublisher<State.Changes, Never> {
            let show = app.watchAX(
                [.selectedTextChanged],
                [.application, .window] + Role.validInputElms
            )
            .mapTo(Event.cursorMoved)

            let checkIfUnfocusedTimer = Timer.interval(seconds: 1)
                .mapTo(Event.cursorMoved)

            let showAlwaysOnIndicatorTimer = Timer.delay(seconds: 0.8)
                .mapTo(Event.showAlwaysOnIndicator)

            let hide = NSEvent.watch(matching: [.scrollWheel])
                .flatMapLatest { _ in Timer
                    .delay(seconds: 0.3)
                    .mapTo(Event.scrollEnd)
                    .prepend(Event.scrollStart)
                }
                .removeDuplicates()
                .eraseToAnyPublisher()

            return Publishers.MergeMany([show, hide, checkIfUnfocusedTimer, showAlwaysOnIndicatorTimer])
                .prepend(.cursorMoved)
                .scan((State.initial, State.initial)) { changes, event -> State.Changes in
                    (changes.current.reducer(event), changes.current)
                }
                .receive(on: DispatchQueue.main)
                .eraseToAnyPublisher()
        }
    }

    func alwaysOnPublisher(
        event: IndicatorVM.ActivateEvent,
        inputSource: InputSource,
        appKind: AppKind
    ) -> AnyPublisher<Void, Never> {
        typealias Action = () -> Void

        let app = appKind.getApp()
        var isAlwaysOnIndicatorShowed = false

        updateIndicator(
            event: event,
            inputSource: inputSource
        )

        return AlwaysOn
            .statePublisher(app: app)
            .flatMapLatest { [weak self] state -> AnyPublisher<Action, Never> in
                let ACTION_HIDE: Action = { self?.isActive = false }
                let ACTION_SHOW: Action = { self?.isActive = true }
                let ACTION_SHOW_ALWAYS_ON_INDICATOR: Action = { self?.indicatorVC.showAlwaysOnView() }

                if !state.current.isScrolling,
                   let self = self,
                   let appSize = self.getAppSize()
                {
                    return self.preferencesVM.getIndicatorPositionPublisher(appSize: appSize, app: app)
                        .map { position -> Action in
                            guard let position = position
                            else { return ACTION_HIDE }

                            return {
                                if state.current.isShowAlwaysOnIndicator,
                                   !isAlwaysOnIndicatorShowed
                                {
                                    isAlwaysOnIndicatorShowed = true
                                    ACTION_SHOW_ALWAYS_ON_INDICATOR()
                                }

                                if position.kind.isInputArea {
                                    self.moveIndicator(position: position)
                                    ACTION_SHOW()
                                } else {
                                    if state.current.isShowAlwaysOnIndicator {
                                        ACTION_HIDE()
                                    } else {
                                        self.moveIndicator(position: position)
                                        ACTION_SHOW()
                                    }
                                }
                            }
                        }
                        .eraseToAnyPublisher()
                } else {
                    return Just(ACTION_HIDE).eraseToAnyPublisher()
                }
            }
            .tap { $0() }
            .mapToVoid()
            .eraseToAnyPublisher()
    }
}
