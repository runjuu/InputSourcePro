import AppKit
import CoreGraphics
import Foundation

enum LaunchpadOverlayDetector {
    static func isLaunchpadVisible() -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return false }

        for window in info {
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            guard owner == "Dock" || owner == "Launchpad" else { continue }

            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            guard (25 ... 35).contains(layer) else { continue }

            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0

            guard height >= 400, width >= 600 else { continue }

            let area = width * height
            let covers = screens.contains { screen in
                let screenArea = screen.frame.width * screen.frame.height
                return screenArea > 0 && area >= screenArea * 0.75
            }
            if covers {
                return true
            }
        }

        return false
    }
}
