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

        let needActivateAtFirstTime = event.shouldActivateInitially(
            onAppSwitch: preferencesVM.preferences.isActiveWhenSwitchApp,
            onInputFocus: preferencesVM.preferences.isActiveWhenFocusedElementChangesEnabled,
            isInputFocused: UIElement.isInputContainer(app.focuedUIElement(application: application))
        )

        if !needActivateAtFirstTime, isActive {
            isActive = false
        }

        let focusedInputs = app
            .watchAX([.focusedUIElementChanged], [.application, .window])
            .compactMap { _ in app.focuedUIElement(application: application) }
            .removeDuplicates()
            .filter { UIElement.isInputContainer($0) }
            .mapToVoid()
            .eraseToAnyPublisher()

        return Self.focusTriggeredIndicatorPublisher(
            initialEvent: needActivateAtFirstTime ? event : nil,
            inputSource: inputSource,
            focusedInputs: focusedInputs
        ) { [weak self] event in
            self?.autoHidePublisher(event: event, inputSource: inputSource, appKind: appKind)
                ?? Empty().eraseToAnyPublisher()
        }
    }

    static func focusTriggeredIndicatorPublisher(
        initialEvent: IndicatorVM.ActivateEvent?,
        inputSource: InputSource,
        focusedInputs: AnyPublisher<Void, Never>,
        show: @escaping (IndicatorVM.ActivateEvent) -> AnyPublisher<Void, Never>
    ) -> AnyPublisher<Void, Never> {
        focusedInputs
            // Focus changes show the input source, never replay a previous status badge.
            .map { _ -> IndicatorVM.ActivateEvent? in .inputSourceChanges(inputSource, .noChanges) }
            .prepend(initialEvent)
            .compactMap { $0 }
            .flatMapLatest { show($0) }
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

// MARK: - Always-on indicator

extension IndicatorWindowController {
    func watchAlwaysOnIndicator() {
        let configs = Publishers.CombineLatest4(
            indicatorVM.$state.map(\.inputSource),
            preferencesVM.$preferences,
            preferencesVM.$keyboardConfigs,
            indicatorVM.$isCapsLockOn
        )
        .receive(on: DispatchQueue.main)
        .compactMap { [weak self] inputSource, preferences, _, isCapsLockOn -> IndicatorViewConfig? in
            guard let self = self else { return nil }

            return IndicatorViewConfig(
                inputSource: inputSource,
                kind: .alwaysOn,
                size: preferences.indicatorSize ?? .medium,
                bgColor: self.preferencesVM.getBgNSColor(inputSource),
                textColor: self.preferencesVM.getTextNSColor(inputSource),
                showsCapsLock: preferences.isShowCapsLockStatus && isCapsLockOn
            )
        }
        .eraseToAnyPublisher()

        let positions = Self.alwaysOnPositionPublisher(
            context: Publishers.CombineLatest3(
                applicationVM.$appKind,
                preferencesVM.$preferences,
                indicatorVM.indicatorIsSuspendedPublisher
            ).eraseToAnyPublisher(),
            isAppAllowed: { [weak self] appKind in
                guard let self = self else { return false }
                return self.preferencesVM.isAbleToQueryLocation(appKind.getApp()) &&
                    !self.preferencesVM.isHideIndicator(appKind)
            },
            getPosition: { [weak self] app in
                self?.caretPlacementPublisher(app: app) ?? Just(.hidden).eraseToAnyPublisher()
            }
        )

        alwaysOnIndicator.observe(configs: configs, positions: positions)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.alwaysOnIndicator.reorderOnActiveSpace() }
            .store(in: cancelBag)
    }

    static func alwaysOnPositionPublisher(
        context: AnyPublisher<(AppKind?, Preferences, Bool), Never>,
        isAppAllowed: @escaping (AppKind) -> Bool,
        getPosition: @escaping (NSRunningApplication) -> AnyPublisher<AlwaysNearMouse.Placement, Never>
    ) -> AnyPublisher<CGPoint?, Never> {
        context
            .receive(on: DispatchQueue.main)
            .flatMapLatest { appKind, preferences, isSuspended -> AnyPublisher<CGPoint?, Never> in
                guard let appKind = appKind,
                      !isSuspended,
                      preferences.isAlwaysOnIndicatorEnabled,
                      !preferences.isAlwaysDisplayIndicatorNearMouseEnabled,
                      isAppAllowed(appKind)
                else { return Just(nil).eraseToAnyPublisher() }

                return getPosition(appKind.getApp())
                    .map { placement -> CGPoint? in
                        if case let .caret(point) = placement { return point }
                        return nil
                    }
                    .prepend(nil)
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    private static func caretTrackingEvents(app: NSRunningApplication) -> AnyPublisher<Bool, Never> {
        let cursorMoved = app.watchAX(
            [.selectedTextChanged, .focusedUIElementChanged],
            [.application, .window] + Role.validInputElms
        )
        .mapToVoid()
        .merge(with: Timer.interval(seconds: 1).mapToVoid())

        let isScrolling = NSEvent.watch(matching: [.scrollWheel])
            .flatMapLatest { _ in
                Timer.delay(seconds: 0.3).mapTo(false).prepend(true)
            }
            .prepend(false)
            .removeDuplicates()

        return Publishers.CombineLatest(cursorMoved.prepend(()), isScrolling)
            .map { _, isScrolling in isScrolling }
            .receive(on: DispatchQueue.main)
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
            indicatorVM.indicatorIsSuspendedPublisher.removeDuplicates()
        )
        .flatMapLatest { [weak self] isEnabled, isSuspended -> AnyPublisher<Void, Never> in
            guard let self = self, isEnabled, !isSuspended else { return Empty().eraseToAnyPublisher() }

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
            .map(\.isAlwaysOnIndicatorEnabled)
            .removeDuplicates()

        let badge = indicatorVM.functionKeyModeChangesPublisher()
            .flatMapLatest { event -> AnyPublisher<IndicatorVM.ActivateEvent?, Never> in
                Timer.delay(seconds: 1)
                    .map { _ -> IndicatorVM.ActivateEvent? in nil }
                    .prepend(.some(event))
                    .eraseToAnyPublisher()
            }
            .prepend(nil)
            .eraseToAnyPublisher()

        // Re-render when the indicator's look changes in Settings (style, size,
        // colours, per-keyboard customisation). A @Published value is delivered
        // before its property is updated, so hop to the main queue first.
        let styleChanged = Publishers.Merge3(
            preferencesVM.$preferences.mapToVoid().eraseToAnyPublisher(),
            preferencesVM.$keyboardConfigs.mapToVoid().eraseToAnyPublisher(),
            indicatorVM.$isCapsLockOn.mapToVoid().eraseToAnyPublisher()
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
            .receive(on: DispatchQueue.main)
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
            isScrolling: Self.caretTrackingEvents(app: app)
        ) { [weak self] in
            guard let self = self else { return Just(nil).eraseToAnyPublisher() }

            return self.preferencesVM.getAlwaysOnIndicatorPositionPublisher(app: app)
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

    private func showNearMouseContent(inputSource: InputSource, badge: IndicatorVM.ActivateEvent?) {
        let event = badge
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
