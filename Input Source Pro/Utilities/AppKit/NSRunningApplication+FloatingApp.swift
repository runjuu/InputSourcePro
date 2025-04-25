import AppKit
import Foundation

extension NSRunningApplication {
    // FIXME: check window info
    var isFloatingApp: Bool {
        NSApplication.isFloatingApp(bundleIdentifier)
    }
}
