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

    func getIndicatorPositionPublisher(
        appSize: CGSize,
        app: NSRunningApplication
    ) -> AnyPublisher<IndicatorPositionInfo?, Never> {
        Just(preferences.indicatorPosition)
            .compactMap { $0 }
            .flatMapLatest { [weak self] position -> AnyPublisher<IndicatorPositionInfo?, Never> in
                let DEFAULT = self?.getIndicatorBasePosition(
                    appSize: appSize,
                    app: app,
                    position: position
                ) ?? Empty(completeImmediately: true).eraseToAnyPublisher()

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
                            return self.getPositionAroundInputCursor()
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

        return getPositionAroundInputCursor()
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

    func getPositionAroundInputCursor() -> AnyPublisher<(point: CGPoint, isContainer: Bool)?, Never> {
        Future { promise in
            DispatchQueue.global().async {
                guard let rectInfo = systemWideElement.getCursorRectInfo(),
                      let screen = NSScreen.getScreenInclude(rect: rectInfo.rect)
                else { return promise(.success(nil)) }

                if rectInfo.isContainer,
                   rectInfo.rect.width / screen.frame.width > 0.7 &&
                   rectInfo.rect.height / screen.frame.height > 0.7
                {
                    return promise(.success(nil))
                }

                let offset: CGFloat = 6

                return promise(.success((
                    CGPoint(x: rectInfo.rect.minX, y: rectInfo.rect.maxY + offset),
                    rectInfo.isContainer
                )))
            }
        }
        .receive(on: DispatchQueue.main)
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
