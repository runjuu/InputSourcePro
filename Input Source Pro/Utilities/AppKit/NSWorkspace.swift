import AppKit

extension NSWorkspace {
    func openAccessibilityPreferences() {
        open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    func openAutomationPreferences() {
        open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        )
    }

    func openKeyboardPreferences() {
        open(
            URL(fileURLWithPath: "/System/Library/PreferencePanes/Keyboard.prefPane")
        )
    }
}

extension NSWorkspace {
    func desktopImage() -> NSImage? {
        guard let mainScreen = NSScreen.main,
              let url = desktopImageURL(for: mainScreen),
              let image = NSImage(contentsOf: url)
        else { return nil }

        return image
    }
}
