import Cocoa
import Combine

@MainActor
class StatusItemController {
    let navigationVM: NavigationVM
    let permissionsVM: PermissionsVM
    let preferencesVM: PreferencesVM
    let applicationVM: ApplicationVM
    let indicatorVM: IndicatorVM
    let feedbackVM: FeedbackVM
    let inputSourceVM: InputSourceVM

    let cancelBag = CancelBag()

    var statusItem: NSStatusItem?
    var hasPreferencesShown = false

    var addRuleMenu: NSMenuItem? {
        guard let app = applicationVM.appKind?.getApp() else { return nil }

        var items: [NSMenuItem] = [
            AppRuleMenuItem(app: app, preferencesVM: preferencesVM, inputSource: nil),
            NSMenuItem.separator(),
        ]

        items[0].toolTip = "Default Keyboard Tooltip".i18n()

        items += InputSource.sources.map {
            AppRuleMenuItem(app: app, preferencesVM: preferencesVM, inputSource: $0)
        }

        items
            .filter { (($0 as? AppRuleMenuItem) != nil) ? true : false }
            .enumerated()
            .forEach { index, item in
                if index < 10 {
                    item.keyEquivalent = "\(index)"
                    item.keyEquivalentModifierMask = .command
                }
            }

        let menu = NSMenuItem(
            title: String(format: "Default Keyboard for %@".i18n(), app.localizedName ?? "Current App".i18n()),
            submenuItems: items
        )

        menu.toolTip = app.bundleIdentifier

        return menu
    }

    var addBrowserRuleMenu: NSMenuItem? {
        guard let browserInfo = applicationVM.appKind?.getBrowserInfo(),
              let host = browserInfo.url.host
        else { return nil }

        var items: [NSMenuItem] = [
            BrowserRuleMenuItem(url: browserInfo.url, preferencesVM: preferencesVM, inputSource: nil),
            NSMenuItem.separator(),
        ]

        items[0].toolTip = "Default Keyboard Tooltip".i18n()

        items += InputSource.sources.map {
            BrowserRuleMenuItem(url: browserInfo.url, preferencesVM: preferencesVM, inputSource: $0)
        }

        items
            .filter { (($0 as? BrowserRuleMenuItem) != nil) ? true : false }
            .enumerated()
            .forEach { index, item in
                if index < 10 {
                    item.keyEquivalent = "\(index)"
                    item.keyEquivalentModifierMask = .command
                }
            }

        return NSMenuItem(
            title: String(format: "Default Keyboard for %@".i18n(), host),
            submenuItems: items
        )
    }

    var settingsMenu: NSMenuItem? {
        NSMenuItem(
            title: "Preferences".i18n() + "...",
            target: self,
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
    }

    var changelogMenu: NSMenuItem? {
        NSMenuItem(
            title: "Changelog".i18n(),
            target: self,
            action: #selector(openChangelog),
            keyEquivalent: ""
        )
    }

    var checkUpdatesMenu: NSMenuItem? {
        NSMenuItem(
            title: "Check for Updates".i18n() + "...",
            target: self,
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
    }

    var menu: NSMenu {
        let menu = NSMenu()

        let items = [
            NSMenuItem(title: "Input Source Pro".i18n(), action: nil, keyEquivalent: ""),
            addBrowserRuleMenu ?? addRuleMenu,
            NSMenuItem.separator(),
            changelogMenu,
            checkUpdatesMenu,
            settingsMenu,
            NSMenuItem.separator(),
            NSMenuItem(
                title: "Quit".i18n(),
                action: #selector(NSApplication.shared.terminate(_:)),
                keyEquivalent: "q"
            ),
        ]
        .compactMap { $0 }

        items.forEach { menu.addItem($0) }

        return menu
    }

    lazy var preferencesWindowController = PreferencesWindowController(
        navigationVM: self.navigationVM,
        permissionsVM: self.permissionsVM,
        preferencesVM: self.preferencesVM,
        indicatorVM: self.indicatorVM,
        feedbackVM: self.feedbackVM,
        inputSourceVM: self.inputSourceVM
    )

    init(
        navigationVM: NavigationVM,
        permissionsVM: PermissionsVM,
        preferencesVM: PreferencesVM,
        applicationVM: ApplicationVM,
        indicatorVM: IndicatorVM,
        feedbackVM: FeedbackVM,
        inputSourceVM: InputSourceVM
    ) {
        self.navigationVM = navigationVM
        self.permissionsVM = permissionsVM
        self.preferencesVM = preferencesVM
        self.applicationVM = applicationVM
        self.indicatorVM = indicatorVM
        self.feedbackVM = feedbackVM
        self.inputSourceVM = inputSourceVM

        preferencesVM.$preferences
            .map(\.isShowIconInMenuBar)
            .removeDuplicates()
            .map { isShow -> AnyPublisher<Void, Never> in
                if isShow {
                    return AnyPublisher.create { [unowned self] _ in
                        statusItem = NSStatusBar.system.statusItem(
                            withLength: NSStatusItem.squareLength
                        )

                        statusItem?.button?.image = NSImage(named: "MenuBarIcon")
                        statusItem?.button?.image?.size = NSSize(width: 16, height: 16)
                        statusItem?.button?.image?.isTemplate = true
                        statusItem?.button?.target = self
                        statusItem?.button?.action = #selector(self.displayMenu)

                        return AnyCancellable { [unowned self] in
                            self.statusItem = nil
                        }
                    }
                } else {
                    return Empty<Void, Never>().eraseToAnyPublisher()
                }
            }
            .switchToLatest()
            .sink {}
            .store(in: cancelBag)
    }

    @objc func displayMenu() {
        // https://stackoverflow.com/a/57612963
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc func openPreferences() {
        NSApp.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = preferencesWindowController.window {
            DispatchQueue.main.async {
                if !self.hasPreferencesShown {
                    self.hasPreferencesShown = true
                    window.center()
                }
                
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc func openChangelog() {
        if let url = URL(string: "https://inputsource.pro/changelog") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func checkForUpdates() {
        preferencesVM.checkUpdates()
    }

    @objc func openFeedback() {
        feedbackVM.show()
        navigationVM.selection = .troubleshooting
        openPreferences()
    }
}
