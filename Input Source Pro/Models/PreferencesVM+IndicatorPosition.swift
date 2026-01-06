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

                return self.getPositionAroundFloatingWindow(app, size: appSize)
                    .flatMapLatest { positionForFloatingWindow -> AnyPublisher<IndicatorPositionInfo?, Never> in
                        if let positionForFloatingWindow = positionForFloatingWindow {
                            return Just((.floatingApp, positionForFloatingWindow)).eraseToAnyPublisher()
                        }

                        if self.preferences.isEnhancedModeEnabled,
                           self.preferences.tryToDisplayIndicatorNearCursor == true,
                           self.isAbleToQueryLocation(app)
                        {
                            return self.getPositionAroundInputCursor(size: appSize)
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
    func getPositionAroundInputCursor(
        size _: CGSize
    ) -> AnyPublisher<(point: CGPoint, isContainer: Bool)?, Never> {
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

            let offset: CGFloat = 12
            let padding: CGFloat = 5
            let visibleFrame = screen.visibleFrame
            let maxXPoint = visibleFrame.maxX
            let minXPoint = visibleFrame.minX
            let maxYPoint = visibleFrame.maxY
            let minYPoint = visibleFrame.minY

            var mousePoint = CGPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y)

            // default offset
            mousePoint.x += offset
            mousePoint.y -= offset

            // move app to cursor's right/bottom edge
            mousePoint.y -= size.height

            // avoid overflow
            mousePoint.x = min(maxXPoint - size.width - padding, mousePoint.x)
            mousePoint.x = max(minXPoint + padding, mousePoint.x)
            mousePoint.y = min(maxYPoint - size.height - padding, mousePoint.y)
            mousePoint.y = max(minYPoint + padding, mousePoint.y)

            observer.send(mousePoint)
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
