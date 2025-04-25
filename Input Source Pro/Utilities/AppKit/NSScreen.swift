import AppKit

extension NSScreen {
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
        return NSScreen.screens.first
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
