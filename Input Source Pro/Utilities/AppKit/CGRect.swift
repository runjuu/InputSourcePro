import AppKit
import Foundation

extension CGRect {
    func relativeTo(screen: NSScreen) -> CGRect {
        let point = CGPoint(
            x: minX - screen.frame.minX,
            y: minY - screen.frame.minY
        )

        return CGRect(origin: point, size: size)
    }
}
