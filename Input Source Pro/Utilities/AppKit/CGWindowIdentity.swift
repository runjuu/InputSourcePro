import AppKit
import CoreGraphics
import Foundation

enum CGWindowIdentity {
    static func frontmostWindowNumber(forPid pid: pid_t) -> Int? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        for window in info {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid
            else { continue }

            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            guard let alpha = window[kCGWindowAlpha as String] as? CGFloat, alpha > 0.01
            else { continue }

            guard let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"],
                  width >= 40,
                  height >= 40
            else { continue }

            if let number = window[kCGWindowNumber as String] as? Int {
                return number
            }
            if let number = window[kCGWindowNumber as String] as? CGWindowID {
                return Int(number)
            }
        }

        return nil
    }

    static func cacheToken(forPid pid: pid_t) -> String? {
        guard let number = frontmostWindowNumber(forPid: pid) else { return nil }
        return "w\(number)"
    }
}
