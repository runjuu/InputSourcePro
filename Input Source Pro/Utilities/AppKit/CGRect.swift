import AppKit
import Foundation

extension CGRect {
    func relativeTo(screen: NSScreen) -> CGRect {
        let point = CGPoint(x: minX, y: screen.frame.maxY - maxY)

        return CGRect(origin: point, size: size)
    }
}
