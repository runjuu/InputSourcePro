import AppKit

struct PixelAlignedWindowLayout {
    let frame: CGRect
    let contentOffset: CGPoint

    init(origin: CGPoint, size: CGSize) {
        // AppKit rounds panel origins to whole points. Keep the remaining pixel offset
        // inside the transparent window, with enough room to avoid clipping the content.
        let windowOrigin = CGPoint(x: floor(origin.x), y: floor(origin.y))
        contentOffset = CGPoint(x: origin.x - windowOrigin.x, y: origin.y - windowOrigin.y)
        frame = CGRect(origin: windowOrigin, size: CGSize(
            width: ceil(size.width + contentOffset.x),
            height: ceil(size.height + contentOffset.y)
        ))
    }
}

extension NSScreen {
    static func pixelAlignedOrigin(_ origin: CGPoint, near anchor: CGPoint) -> CGPoint {
        // Use the destination screen, since the indicator may still be on another display.
        guard let screen = screens.first(where: { NSMouseInRect(anchor, $0.frame, false) }) else {
            return origin
        }
        return screen.backingAlignedRect(
            CGRect(origin: origin, size: .zero),
            options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest]
        ).origin
    }

    static func getScreenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        let screens = NSScreen.screens

        return screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
    }

    static func getScreenInclude(rect: CGRect) -> NSScreen? {
        return NSScreen.screens
            .map { screen in (screen, screen.frame.intersection(rect)) }
            .filter { _, intersect in !intersect.isNull }
            .map { screen, intersect in (screen, intersect.size.width * intersect.size.height) }
            .max { lhs, rhs in lhs.1 < rhs.1 }?.0
    }
}

extension NSScreen {
    /// The screen whose bottom left is at (0, 0).
    static var primary: NSScreen? {
        return NSScreen.screens.first(where: { $0.frame.origin == .zero }) ??
            NSScreen.main ??
            NSScreen.screens.first
    }

    /// Converts the rectangle from Quartz "display space" to Cocoa "screen space".
    /// <http://stackoverflow.com/a/19887161/23649>
    static func convertFromQuartz(_ rect: CGRect) -> CGRect? {
        return NSScreen.primary.map { screen in
            var result = rect
            result.origin.y = screen.frame.maxY - result.maxY
            return result
        }
    }
}
