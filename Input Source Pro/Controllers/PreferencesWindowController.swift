import AppKit
import SwiftUI

@MainActor
class PreferencesWindowController: NSWindowController {
    let navigationVM: NavigationVM
    let permissionsVM: PermissionsVM
    let preferencesVM: PreferencesVM
    let indicatorVM: IndicatorVM
    let feedbackVM: FeedbackVM
    let inputSourceVM: InputSourceVM

    init(
        navigationVM: NavigationVM,
        permissionsVM: PermissionsVM,
        preferencesVM: PreferencesVM,
        indicatorVM: IndicatorVM,
        feedbackVM: FeedbackVM,
        inputSourceVM: InputSourceVM
    ) {
        self.navigationVM = navigationVM
        self.permissionsVM = permissionsVM
        self.preferencesVM = preferencesVM
        self.indicatorVM = indicatorVM
        self.feedbackVM = feedbackVM
        self.inputSourceVM = inputSourceVM

        let window = NSWindow(
            contentViewController: NSHostingController(
                rootView: PreferencesView()
                    .environmentObject(navigationVM)
                    .environmentObject(preferencesVM)
                    .environmentObject(indicatorVM)
                    .environmentObject(permissionsVM)
                    .environmentObject(feedbackVM)
                    .environmentObject(inputSourceVM)
            )
        )

        super.init(window: window)

        window.delegate = self

        configureWindow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureWindow() {
        window?.standardWindowButton(NSWindow.ButtonType.zoomButton)?.isEnabled = false
        window?.standardWindowButton(NSWindow.ButtonType.miniaturizeButton)?.isEnabled = false

        window?.title = "Input Source Pro"
        window?.titleVisibility = .hidden
        window?.titlebarAppearsTransparent = true
        window?.styleMask.insert(.fullSizeContentView)
    }
}

extension PreferencesWindowController: NSWindowDelegate {
    func windowWillClose(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
