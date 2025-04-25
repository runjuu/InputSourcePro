import AXSwift
import Cocoa

extension NSRunningApplication {
    @MainActor
    func focusedUIElement(preferencesVM: PreferencesVM?) -> UIElement? {
        return focuedUIElement(application: getApplication(preferencesVM: preferencesVM))
    }

    @MainActor
    func focuedUIElement(application: Application?) -> UIElement? {
        if let application = application {
            return try? application.attribute(.focusedUIElement)
        } else {
            return nil
        }
    }

    @MainActor
    func getApplication(preferencesVM: PreferencesVM?) -> Application? {
        if let preferencesVM = preferencesVM,
           preferencesVM.preferences.isEnhancedModeEnabled,
           !NSApplication.isFloatingApp(bundleIdentifier)
        {
            return Application(self)
        } else {
            return nil
        }
    }
}
