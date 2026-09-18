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
            // App-switch trigger: suppress only when the same input source stays
            // active, so unchanged-keyboard app switches don't pop the indicator.
            if preferencesVM.preferences.isActiveWhenSwitchApp,
               !event.isAppChangesWithUnchangedInputSource
            {
                return true
            }

            // Focused-field trigger is independent: even on unchanged-keyboard
            // app switches (e.g. browser address-bar transitions), the indicator
            // should still appear immediately if the focused element is an input
            // container. The AX watcher installed below does not replay the
            // current focus, so we must evaluate it here.
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

// MARK: - Always near mouse

extension IndicatorWindowController {
    enum AlwaysNearMouse {
        enum Placement: Equatable {
            case hidden
            case caret(CGPoint)
            case mouse
        }

        /// Caret first: pin to a text caret when one was found, otherwise follow
        /// the mouse. While scrolling the caret moves with the content, so hide
        /// for that moment, as the always-on indicator does.
        static func placement(isScrolling: Bool, position: PreferencesVM.IndicatorPositionInfo?) -> Placement {
            guard let position = position, position.kind.isInputArea else { return .mouse }

            if isScrolling {
                return .hidden
            }

            return .caret(position.point)
        }

        static func placementPublisher(
            isScrolling: AnyPublisher<Bool, Never>,
            getPosition: @escaping () -> AnyPublisher<PreferencesVM.IndicatorPositionInfo?, Never>
        ) -> AnyPublisher<Placement, Never> {
            Deferred {
                var lastPosition: PreferencesVM.IndicatorPositionInfo?

                return isScrolling
                    .flatMapLatest { isScrolling -> AnyPublisher<Placement, Never> in
                        if isScrolling {
                            // Hide a pinned caret immediately without querying moving
                            // content. Mouse following stays active during scrolling.
                            return Just(placement(isScrolling: true, position: lastPosition))
                                .eraseToAnyPublisher()
                        }

                        return getPosition()
                            .map { position in
                                lastPosition = position
                                return placement(isScrolling: false, position: position)
                            }
                            .eraseToAnyPublisher()
                    }
                    .removeDuplicates()
            }
            .eraseToAnyPublisher()
        }
    }

    private static let mouseMoveEvents: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]

    /// While "always display near mouse" is on, this pipeline owns the indicator:
    /// it keeps it visible, pins it to the text caret when the always-on indicator
    /// can find one and otherwise moves it with the pointer, and refreshes its
    /// content itself. The activate-event pipeline is idle in that mode.
    func watchAlwaysNearMouse() {
        Publishers.CombineLatest(
            preferencesVM.$preferences.map(\.isAlwaysDisplayIndicatorNearMouseEnabled).removeDuplicates(),
            indicatorVM.screenIsLockedPublisher.removeDuplicates()
        )
        .flatMapLatest { [weak self] isEnabled, isLocked -> AnyPublisher<Void, Never> in
            guard let self = self, isEnabled, !isLocked else { return Empty().eraseToAnyPublisher() }

            return self.alwaysNearMousePublisher()
        }
        .sink { _ in }
        .store(in: cancelBag)
    }

    private func alwaysNearMousePublisher() -> AnyPublisher<Void, Never> {
        // Give the indicator content right away so it has a size to be placed with.
        showNearMouseContent(inputSource: indicatorVM.state.inputSource, badge: nil)

        // Caret tracking needs the same preferences as the always-on indicator.
        let caretTrackingPreferred = preferencesVM.$preferences
            .map { $0.isEnhancedModeEnabled && $0.tryToDisplayIndicatorNearCursor && $0.isEnableAlwaysOnIndicator }
            .removeDuplicates()

        // The function-key badge shows for a second after a toggle, the same as
        // the transient indicator does.
        let badge: AnyPublisher<FKeyMode?, Never> = indicatorVM.functionKeyModeChangeSubject
            .flatMapLatest { mode -> AnyPublisher<FKeyMode?, Never> in
                Timer.delay(seconds: 1)
                    .map { _ -> FKeyMode? in nil }
                    .prepend(.some(mode))
                    .eraseToAnyPublisher()
            }
            .prepend(nil)
            .eraseToAnyPublisher()

        // Re-render when the indicator's look changes in Settings (style, size,
        // colours, per-keyboard customisation). A @Published value is delivered
        // before its property is updated, so hop to the main queue first.
        let styleChanged = Publishers.Merge(
            preferencesVM.$preferences.mapToVoid().eraseToAnyPublisher(),
            preferencesVM.$keyboardConfigs.mapToVoid().eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)

        // Take the input source from the emitted state for the same reason:
        // reading indicatorVM.state here would lag one change behind.
        let content = Publishers.CombineLatest3(indicatorVM.$state.map(\.inputSource), badge, styleChanged)

        // The global monitor never sees events delivered to this app, so also
        // watch locally to keep following over our own windows.
        let mouseMoved = Publishers.Merge(
            NSEvent.watch(matching: Self.mouseMoveEvents),
            NSEvent.watchLocal(matching: Self.mouseMoveEvents)
        )
        .throttle(for: .milliseconds(16), scheduler: DispatchQueue.main, latest: true)
        .mapToVoid()
        .eraseToAnyPublisher()

        // Local event monitors miss AppKit's menu, control and window-dragging
        // loops. Sample directly in that mode; the main dispatch queue can stall.
        let mouseMovedDuringTracking = Timer.publish(every: 1.0 / 60, on: .main, in: .eventTracking)
            .autoconnect()
            .map { _ in NSEvent.mouseLocation }
            .removeDuplicates()
            .mapToVoid()
            .eraseToAnyPublisher()

        // The panel joins the active Space only when ordered front, so re-order it
        // after a Space switch to bring it along.
        let spaceChanged = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .tap { [weak self] _ in
                guard let self = self, self.isActive else { return }

                self.deactive()
                self.active()
            }
            .mapToVoid()
            .eraseToAnyPublisher()

        return Publishers.CombineLatest(applicationVM.$appKind, caretTrackingPreferred)
            .flatMapLatest { [weak self] appKind, caretTrackingPreferred -> AnyPublisher<Void, Never> in
                guard let self = self else { return Empty().eraseToAnyPublisher() }

                if let appKind = appKind, self.preferencesVM.isHideIndicator(appKind) {
                    self.isActive = false
                    return Empty().eraseToAnyPublisher()
                }

                let placement: AnyPublisher<AlwaysNearMouse.Placement, Never>
                if caretTrackingPreferred,
                   let app = appKind?.getApp(),
                   self.preferencesVM.isAbleToQueryLocation(app)
                {
                    placement = self.caretPlacementPublisher(app: app)
                        .share(replay: 1)
                        .eraseToAnyPublisher()
                } else {
                    placement = Just(.mouse).eraseToAnyPublisher()
                }

                // Re-apply the placement when the content or the Space changes, and
                // whenever the placement itself changes.
                let refresh = Publishers.Merge(
                    content
                        .tap { self.showNearMouseContent(inputSource: $0.0, badge: $0.1) }
                        .mapToVoid()
                        .eraseToAnyPublisher(),
                    spaceChanged
                )
                .prepend(())

                let applied = Publishers.CombineLatest(placement, refresh)
                    .map { placement, _ in placement }
                    .tap { self.apply(placement: $0) }
                    .mapToVoid()
                    .eraseToAnyPublisher()

                // Pointer moves only matter while following the mouse.
                let followed = Publishers.Merge(mouseMoved, mouseMovedDuringTracking)
                    .withLatestFrom(placement)
                    .filter { $0 == .mouse }
                    .tap { _ in self.moveNearMouse() }
                    .mapToVoid()
                    .eraseToAnyPublisher()

                return Publishers.Merge(applied, followed).eraseToAnyPublisher()
            }
            .handleEvents(receiveCancel: { [weak self] in self?.isActive = false })
            .eraseToAnyPublisher()
    }

    /// Where the always-on indicator would put the indicator for this app, driven
    /// by the same signals it uses (caret changes, a 1s poll, scrolling).
    private func caretPlacementPublisher(app: NSRunningApplication) -> AnyPublisher<AlwaysNearMouse.Placement, Never> {
        AlwaysNearMouse.placementPublisher(
            isScrolling: AlwaysOn.statePublisher(app: app)
                .map(\.current.isScrolling)
                .eraseToAnyPublisher()
        ) { [weak self] in
            guard let self = self, let appSize = self.getAppSize()
            else { return Just(nil).eraseToAnyPublisher() }

            return self.preferencesVM.getIndicatorPositionPublisher(appSize: appSize, app: app)
        }
    }

    private func apply(placement: AlwaysNearMouse.Placement) {
        switch placement {
        case .hidden:
            isActive = false
        case let .caret(point):
            guard getAppSize() != nil else { return }

            moveIndicator(position: (.inputCursor, point))
            indicatorVC.showAlwaysOnView()

            if !isActive {
                isActive = true
            }
        case .mouse:
            indicatorVC.showNormalView()
            moveNearMouse()
        }
    }

    private func showNearMouseContent(inputSource: InputSource, badge mode: FKeyMode?) {
        let event: IndicatorVM.ActivateEvent = mode.map { .functionKeyModeChanges($0) }
            ?? .inputSourceChanges(inputSource, .noChanges)

        updateIndicator(event: event, inputSource: inputSource)
    }

    private func moveNearMouse() {
        guard let size = getAppSize(),
              let screen = NSScreen.getScreenWithMouse()
        else { return }

        let point = IndicatorPosition.pointNearMouse(
            mouseLocation: NSEvent.mouseLocation,
            size: size,
            visibleFrame: screen.visibleFrame
        )

        moveIndicator(position: (.nearMouse, point))

        if !isActive {
            isActive = true
        }
    }
}
