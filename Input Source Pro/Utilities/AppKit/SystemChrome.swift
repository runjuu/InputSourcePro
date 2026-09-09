import AppKit
import Foundation

enum SystemChrome {
    static let dockBundleID = "com.apple.dock"
    static let launchpadLauncherBundleID = "com.apple.launchpad.launcher"

    private static let pointerChromeBundleIDs: Set<String> = [
        dockBundleID,
    ]

    private static let neverCacheBundleIDs: Set<String> = [
        dockBundleID,
        launchpadLauncherBundleID,
    ]

    static func isPointerChrome(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return pointerChromeBundleIDs.contains(bundleIdentifier)
    }

    static func isLaunchpadRelated(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == dockBundleID || bundleIdentifier == launchpadLauncherBundleID
    }

    static func shouldNeverCache(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return neverCacheBundleIDs.contains(bundleIdentifier)
    }

    static func ruleAliasBundleIDs(for bundleId: String) -> [String] {
        switch bundleId {
        case dockBundleID:
            return [launchpadLauncherBundleID]
        case launchpadLauncherBundleID:
            return [dockBundleID]
        default:
            return []
        }
    }

    static func dockRunningApplication() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == dockBundleID }
    }
}
