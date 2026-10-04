import AppKit
import AXSwift
import Combine
import CombineExt

extension PreferencesVM {
    func calcSpacing(minLength: CGFloat) -> CGFloat {
        guard let spacing = preferences.indicatorPositionSpacing else { return 0 }

        switch spacing {
        case .none:
            return 0
        case .xs:
            return minLength * 0.02
        case .s:
            return minLength * 0.05
        case .m:
            return minLength * 0.08
        case .l:
            return minLength * 0.13
        case .xl:
            return minLength * 0.21
        }
    }

    typealias IndicatorPositionInfo = (kind: IndicatorActuallyPositionKind, point: CGPoint)
    typealias CursorPosition = (point: CGPoint, isContainer: Bool)

    static func preferredCaretPositionPublisher(
        palette: @escaping () -> CGPoint?,
        accessibility: @escaping () -> AnyPublisher<CursorPosition?, Never>,
        awaitingConfirmation: @escaping () -> Bool = { false },
        traceID: String = UUID().uuidString
    ) -> AnyPublisher<CursorPosition?, Never> {
        Deferred {
            if let point = palette() {
                IndicatorDiagnostics.record("caret.chosen id=\(traceID) provider=helper point=\(point)")
                return Just<CursorPosition?>((point, false)).eraseToAnyPublisher()
            }
            if awaitingConfirmation() {
                IndicatorDiagnostics.record("caret.chosen id=\(traceID) provider=none reason=helper-suppresses-AX")
                return Just<CursorPosition?>(nil).eraseToAnyPublisher()
            }
            IndicatorDiagnostics.record("caret.query id=\(traceID) provider=AX")
            return accessibility()
                .map { position in
                    // The helper may have connected while the Accessibility query was running.
                    if let point = palette() {
                        IndicatorDiagnostics.record("caret.chosen id=\(traceID) provider=helper-after-AX point=\(point)")
                        return (point: point, isContainer: false)
                    }
                    let suppressed = awaitingConfirmation()
                    IndicatorDiagnostics.record("caret.chosen id=\(traceID) provider=AX suppressed=\(suppressed) result=\(String(describing: position))")
                    return suppressed ? nil : position
                }
                .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
    }


    static func caretPositionWhenReadyPublisher(
        query: @escaping () -> AnyPublisher<CursorPosition?, Never>,
        changes: AnyPublisher<Void, Never>,
        awaitingConfirmation: @escaping () -> Bool,
        deadline: @escaping () -> AnyPublisher<Void, Never> = {
            Timer.delay(seconds: 0.75).mapToVoid().eraseToAnyPublisher()
        }
    ) -> AnyPublisher<CursorPosition?, Never> {
        Deferred {
            query().flatMapLatest { position -> AnyPublisher<CursorPosition?, Never> in
                guard position == nil, awaitingConfirmation() else {
                    return Just(position).eraseToAnyPublisher()
                }

                // A pending helper sample is not a missing caret. Keep the default
                // indicator unplaced until confirmation resolves, without delaying
                // apps that already have a position or are not in an input field.
                let confirmed = changes
                    .prepend(())
                    .flatMapLatest { query() }
                    .filter { $0 != nil || !awaitingConfirmation() }
                    .eraseToAnyPublisher()

                return Publishers.Merge(
                    confirmed,
                    deadline().map { _ -> CursorPosition? in nil }
                )
                .first()
                .eraseToAnyPublisher()
            }
            .first()
        }
        .eraseToAnyPublisher()
    }

    func getIndicatorPositionPublisher(
        appSize: CGSize,
        app: NSRunningApplication,
        traceID: String = UUID().uuidString
    ) -> AnyPublisher<IndicatorPositionInfo?, Never> {
        let fallback = {
            self.getDefaultIndicatorPositionPublisher(appSize: appSize, app: app, traceID: traceID)
        }
        guard preferences.isAlwaysOnIndicatorEnabled,
              !preferences.tryToDisplayIndicatorNearCursor,
              !preferences.isAlwaysDisplayIndicatorNearMouseEnabled,
              isAbleToQueryLocation(app),
              !NSApplication.isSpotlightLikeApp(app.bundleIdentifier)
        else { return fallback() }

        IndicatorDiagnostics.record("position.waitForAlwaysOn id=\(traceID) pid=\(app.processIdentifier)")
        return Self.positionUnlessCaretAvailablePublisher(
            caret: Self.caretPositionWhenReadyPublisher(
                query: { self.getPositionAroundInputCursor(app: app, traceID: traceID) },
                changes: CaretPalette.shared.changes,
                awaitingConfirmation: { CaretPalette.shared.isAwaitingConfirmation(for: app) }
            ),
            fallback: fallback
        )
    }

    static func positionUnlessCaretAvailablePublisher(
        caret: AnyPublisher<CursorPosition?, Never>,
        fallback: @escaping () -> AnyPublisher<IndicatorPositionInfo?, Never>
    ) -> AnyPublisher<IndicatorPositionInfo?, Never> {
        caret.first()
            .flatMapLatest { position -> AnyPublisher<IndicatorPositionInfo?, Never> in
                guard position == nil else {
                    IndicatorDiagnostics.record("position.suppressed reason=always-on-caret-available")
                    return Just(nil).eraseToAnyPublisher()
                }
                return fallback()
            }
            .eraseToAnyPublisher()
    }

    private func getDefaultIndicatorPositionPublisher(
        appSize: CGSize,
        app: NSRunningApplication,
        traceID: String
    ) -> AnyPublisher<IndicatorPositionInfo?, Never> {
        IndicatorDiagnostics.record("position.begin id=\(traceID) pid=\(app.processIdentifier) size=\(appSize) base=\(String(describing: preferences.indicatorPosition)) enhanced=\(preferences.isEnhancedModeEnabled) nearCursor=\(String(describing: preferences.tryToDisplayIndicatorNearCursor)) alwaysOn=\(preferences.isAlwaysOnIndicatorEnabled) alwaysNearMouse=\(preferences.isAlwaysDisplayIndicatorNearMouseEnabled)")
        return Just(preferences.indicatorPosition)
            .compactMap { $0 }
            .flatMapLatest { [weak self] position -> AnyPublisher<IndicatorPositionInfo?, Never> in
                let DEFAULT = self?.getIndicatorBasePosition(
                    appSize: appSize,
                    app: app,
                    position: position
                ).handleEvents(receiveOutput: {
                    IndicatorDiagnostics.record("position.fallback id=\(traceID) result=\(String(describing: $0))")
                }).eraseToAnyPublisher() ?? Empty(completeImmediately: true).eraseToAnyPublisher()

                guard let self = self
                else { return DEFAULT }

                if SpotlightIndicatorPosition.usesSearchFieldBounds(bundleIdentifier: app.bundleIdentifier) {
                    return self.getPositionAroundSpotlightSearchField(app, size: appSize)
                        .flatMapLatest { point -> AnyPublisher<IndicatorPositionInfo?, Never> in
                            if let point = point {
                                return Just((.floatingApp, point)).eraseToAnyPublisher()
                            }

                            // Never fall back to the screen-sized Siri host window.
                            return self.getPositionNearMouse(size: appSize)
                                .map { $0.map { (.nearMouse, $0) } }
                                .eraseToAnyPublisher()
                        }
                        .eraseToAnyPublisher()
                }

                return self.getPositionAroundFloatingWindow(app, size: appSize)
                    .flatMapLatest { positionForFloatingWindow -> AnyPublisher<IndicatorPositionInfo?, Never> in
                        if let positionForFloatingWindow = positionForFloatingWindow {
                            return Just((.floatingApp, positionForFloatingWindow)).eraseToAnyPublisher()
                        }

                        if self.preferences.isEnhancedModeEnabled,
                           self.preferences.tryToDisplayIndicatorNearCursor == true,
                           self.isAbleToQueryLocation(app)
                        {
                            return Self.caretPositionWhenReadyPublisher(
                                query: { self.getPositionAroundInputCursor(app: app, traceID: traceID) },
                                changes: CaretPalette.shared.changes,
                                awaitingConfirmation: { CaretPalette.shared.isAwaitingConfirmation(for: app) }
                            )
                                .map { cursorPosition -> AnyPublisher<IndicatorPositionInfo?, Never> in
                                    guard let cursorPosition = cursorPosition else { return DEFAULT }

                                    return Just((cursorPosition.isContainer ? .inputRect : .inputCursor, cursorPosition.point))
                                        .eraseToAnyPublisher()
                                }
                                .switchToLatest()
                                .eraseToAnyPublisher()
                        }

                        return DEFAULT
                    }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    func getAlwaysOnIndicatorPositionPublisher(
        app: NSRunningApplication
    ) -> AnyPublisher<IndicatorPositionInfo?, Never> {
        guard preferences.isEnhancedModeEnabled,
              isAbleToQueryLocation(app),
              !NSApplication.isSpotlightLikeApp(app.bundleIdentifier)
        else { return Just(nil).eraseToAnyPublisher() }

        let traceID = UUID().uuidString
        IndicatorDiagnostics.record("position.alwaysOn id=\(traceID) pid=\(app.processIdentifier)")
        return getPositionAroundInputCursor(app: app, traceID: traceID)
            .map { position in
                position.map { ($0.isContainer ? .inputRect : .inputCursor, $0.point) }
            }
            .eraseToAnyPublisher()
    }

    func getIndicatorBasePosition(
        appSize: CGSize,
        app: NSRunningApplication,
        position: IndicatorPosition
    ) -> AnyPublisher<IndicatorPositionInfo?, Never> {
        Just(position)
            .flatMapLatest { [weak self] _ -> AnyPublisher<IndicatorPositionInfo?, Never> in
                guard let self = self else { return Just(nil).eraseToAnyPublisher() }

                switch position {
                case .nearMouse:
                    return self.getPositionNearMouse(size: appSize)
                        .map {
                            guard let position = $0 else { return nil }
                            return (.nearMouse, position)
                        }
                        .eraseToAnyPublisher()
                case .windowCorner:
                    return self.getPositionRelativeToAppWindow(size: appSize, app)
                        .map {
                            guard let position = $0 else { return nil }
                            return (.windowCorner, position)
                        }
                        .eraseToAnyPublisher()
                case .screenCorner:
                    return self.getPositionRelativeToScreen(size: appSize, app)
                        .map {
                            guard let position = $0 else { return nil }
                            return (.screenCorner, position)
                        }
                        .eraseToAnyPublisher()
                }
            }
            .eraseToAnyPublisher()
    }
}

private extension PreferencesVM {
    func getPositionAroundSpotlightSearchField(
        _ app: NSRunningApplication, size: CGSize
    ) -> AnyPublisher<CGPoint?, Never> {
        Future<CGRect?, Never> { promise in
            DispatchQueue.global().async {
                let bounds = Application(app).flatMap { SpotlightIndicatorPosition.searchFieldBounds(in: $0) }
                promise(.success(bounds))
            }
        }
        .receive(on: DispatchQueue.main)
        .map { bounds in
            guard let bounds = bounds,
                  let screen = NSScreen.getScreenInclude(rect: bounds)
            else { return nil }

            return SpotlightIndicatorPosition.point(
                searchFieldBounds: bounds,
                indicatorSize: size,
                visibleFrame: screen.visibleFrame
            )
        }
        .eraseToAnyPublisher()
    }

    func getPositionAroundInputCursor(app: NSRunningApplication, traceID: String) -> AnyPublisher<(point: CGPoint, isContainer: Bool)?, Never> {
        Self.preferredCaretPositionPublisher(
            palette: { CaretPalette.shared.point(for: app) },
            accessibility: {
                Future<(point: CGPoint, isContainer: Bool)?, Never> { promise in
                    DispatchQueue.global().async {
                        let started = ProcessInfo.processInfo.systemUptime
                        IndicatorDiagnostics.record("AX.begin id=\(traceID) expectedPID=\(app.processIdentifier)")
                        defer { IndicatorDiagnostics.record("AX.end id=\(traceID) elapsedMs=\((ProcessInfo.processInfo.systemUptime - started) * 1000)") }
                        guard let rectInfo = systemWideElement.getCursorRectInfo(traceID: traceID),
                              let screen = NSScreen.getScreenInclude(rect: rectInfo.rect)
                        else {
                            IndicatorDiagnostics.record("AX.missing id=\(traceID) reason=no-rect-or-screen")
                            return promise(.success(nil))
                        }
                        IndicatorDiagnostics.record("AX.geometry id=\(traceID) rect=\(rectInfo.rect) container=\(rectInfo.isContainer) screen=\(screen.frame)")

                        if rectInfo.isContainer,
                           rectInfo.rect.width / screen.frame.width > 0.7 &&
                           rectInfo.rect.height / screen.frame.height > 0.7
                        {
                            IndicatorDiagnostics.record("AX.rejected id=\(traceID) reason=oversized-container")
                            return promise(.success(nil))
                        }

                        return promise(.success((
                            rectInfo.indicatorPoint,
                            rectInfo.isContainer
                        )))
                    }
                }
                .receive(on: DispatchQueue.main)
                .eraseToAnyPublisher()
            },
            awaitingConfirmation: { CaretPalette.shared.suppressesAccessibilityFallback(for: app) },
            traceID: traceID
        )
        .handleEvents(
            receiveOutput: { IndicatorDiagnostics.record("caret.delivered id=\(traceID) result=\(String(describing: $0)) frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)") },
            receiveCancel: { IndicatorDiagnostics.record("caret.cancel id=\(traceID)") }
        )
        .eraseToAnyPublisher()
    }

    func getPositionNearMouse(size: CGSize) -> AnyPublisher<CGPoint?, Never> {
        AnyPublisher.create { observer in
            guard let screen = NSScreen.getScreenWithMouse() else { return AnyCancellable {} }

            observer.send(IndicatorPosition.pointNearMouse(
                mouseLocation: NSEvent.mouseLocation,
                size: size,
                visibleFrame: screen.visibleFrame
            ))
            observer.send(completion: .finished)

            return AnyCancellable {}
        }
    }

    func getPositionRelativeToAppWindow(
        size: CGSize,
        _ app: NSRunningApplication
    ) -> AnyPublisher<CGPoint?, Never> {
        app.getWindowInfoPublisher()
            .map { [weak self] windowInfo -> CGPoint? in
                guard let self = self,
                      let windowBounds = windowInfo?.bounds,
                      NSScreen.getScreenInclude(rect: windowBounds) != nil
                else { return nil }

                return self.getPositionWithin(
                    rect: windowBounds,
                    size: size,
                    alignment: self.preferences.indicatorPositionAlignment ?? .bottomRight
                )
            }
            .eraseToAnyPublisher()
    }

    func getPositionRelativeToScreen(
        size: CGSize,
        _ app: NSRunningApplication
    ) -> AnyPublisher<CGPoint?, Never> {
        app.getWindowInfoPublisher()
            .map { [weak self] windowInfo -> CGPoint? in
                guard let self = self,
                      let windowBounds = windowInfo?.bounds,
                      let screen = NSScreen.getScreenInclude(rect: windowBounds) ??
                      NSScreen.getScreenWithMouse() ??
                      NSScreen.main
                else { return nil }

                return self.getPositionWithin(
                    rect: screen.visibleFrame,
                    size: size,
                    alignment: self.preferences.indicatorPositionAlignment ?? .bottomRight
                )
            }
            .eraseToAnyPublisher()
    }

    func getPositionAround(rect: CGRect) -> (NSScreen, CGPoint)? {
        guard let screen = NSScreen.getScreenInclude(rect: rect) else { return nil }

        return (screen, rect.origin)
    }

    func getPositionAroundFloatingWindow(
        _ app: NSRunningApplication, size: CGSize
    ) -> AnyPublisher<CGPoint?, Never> {
        guard NSApplication.isSpotlightLikeApp(app.bundleIdentifier) else { return Just(nil).eraseToAnyPublisher() }

        return app.getWindowInfoPublisher()
            .map { [weak self] windowInfo -> CGPoint? in
                guard let self = self,
                      let rect = windowInfo?.bounds,
                      let (screen, point) = self.getPositionAround(rect: rect)
                else { return nil }

                let offset: CGFloat = 6

                let position = CGPoint(
                    x: point.x,
                    y: point.y + rect.height + offset
                )

                if screen.frame.contains(CGRect(origin: position, size: size)) {
                    return position
                } else {
                    return nil
                }
            }
            .eraseToAnyPublisher()
    }

    func getPositionWithin(
        rect: NSRect,
        size: CGSize,
        alignment: IndicatorPosition.Alignment
    ) -> CGPoint {
        let spacing = calcSpacing(minLength: min(rect.width, rect.height))

        switch alignment {
        case .topLeft:
            return CGPoint(
                x: rect.minX + spacing,
                y: rect.maxY - size.height - spacing
            )
        case .topCenter:
            return CGPoint(
                x: rect.midX - size.width / 2,
                y: rect.maxY - size.height - spacing
            )
        case .topRight:
            return CGPoint(
                x: rect.maxX - size.width - spacing,
                y: rect.maxY - size.height - spacing
            )
        case .center:
            return CGPoint(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2
            )
        case .centerLeft:
            return CGPoint(
                x: rect.minX + spacing,
                y: rect.midY - size.height / 2
            )
        case .centerRight:
            return CGPoint(
                x: rect.maxX - size.width - spacing,
                y: rect.midY - size.height / 2
            )
        case .bottomLeft:
            return CGPoint(
                x: rect.minX + spacing,
                y: rect.minY + spacing
            )
        case .bottomCenter:
            return CGPoint(
                x: rect.midX - size.width / 2,
                y: rect.minY + spacing
            )
        case .bottomRight:
            return CGPoint(
                x: rect.maxX - size.width - spacing,
                y: rect.minY + spacing
            )
        }
    }
}
