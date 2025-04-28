import SwiftUI

struct BrowserRulesSettingsView: View {
    @State var isPresented = false

    @State var permissionRequest: Browser? = nil

    @State var selectedRules = Set<BrowserRule>()

    @FetchRequest(sortDescriptors: [
        NSSortDescriptor(key: "createdAt", ascending: true),
    ])
    var browserRules: FetchedResults<BrowserRule>

    @EnvironmentObject var preferencesVM: PreferencesVM

    @EnvironmentObject var permissionsVM: PermissionsVM

    var inputSourceItems: [PickerItem] {
        [PickerItem.empty]
            + InputSource.sources.map { PickerItem(id: $0.id, title: $0.name, toolTip: $0.id) }
    }

    var body: some View {
        let isShowPermissionRequest = Binding(
            get: { permissionRequest != nil },
            set: {
                if $0 == false {
                    permissionRequest = nil
                }
            }
        )

        return VStack(spacing: 0) {
            VStack {
                HStack {
                    Text("Default Keyboard for Address Bar".i18n())

                    PopUpButtonPicker<PickerItem?>(
                        items: inputSourceItems,
                        width: 150,
                        isItemSelected: { $0?.id == preferencesVM.preferences.browserAddressDefaultKeyboardId },
                        getTitle: { $0?.title ?? "" },
                        getToolTip: { $0?.toolTip },
                        onSelect: handleBrowserAddressDefaultKeyboardSelect
                    )
                    .disabled(!preferencesVM.preferences.isEnhancedModeEnabled)

                    EnhancedModeRequiredBadge()

                    Spacer(minLength: 0)
                }
            }
            .padding()
            .border(width: 1, edges: [.bottom], color: NSColor.border.color)

            List(browserRules, id: \.self, selection: $selectedRules) { rule in
                BrowserRuleRow(rule: rule)
            }

            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    Button(action: addRule) {
                        SwiftUI.Image(systemName: "plus")
                    }

                    Button(action: removeRules) {
                        SwiftUI.Image(systemName: "minus")
                    }
                    .disabled(selectedRules.isEmpty)
                }

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Browser.allCases.sorted { $0.rawValue < $1.rawValue }, id: \.rawValue) { browser in
                            if NSApplication.isBrowserInstalled(browser.rawValue) {
                                Toggle(isOn: isEnableFor(browser)) {
                                    Text("\(browser.displayName)")
                                }
                            }
                        }
                    }
                }
            }
            .padding(10)
            .border(width: 1, edges: [.top], color: NSColor.gridColor.color)
            .sheet(isPresented: $isPresented, content: {
                BrowserRuleEditView(isPresented: $isPresented, rule: nil)
            })
            .sheet(isPresented: isShowPermissionRequest) {
                BrowserPermissionRequestView(
                    isPresented: isShowPermissionRequest,
                    onSuccess: permissionRequestSuccess
                )
            }
        }
    }

    func addRule() {
        isPresented = true
    }

    func removeRules() {
        for selectedRule in selectedRules {
            preferencesVM.deleteBrowserRule(selectedRule)
        }
        selectedRules.removeAll()
    }

    func isEnableFor(_ browser: Browser) -> Binding<Bool> {
        Binding(
            get: { preferencesVM.isBrowserEnabled(browser) },
            set: { enableFor(browser, enable: $0) }
        )
    }

    func enableFor(_ browser: Browser, enable: Bool) {
        if enable {
            // TODO: replace `isAccessibilityEnabled` with enhance mode
            if permissionsVM.isAccessibilityEnabled {
                toggle(browser: browser, isEnable: true)
            } else {
                permissionRequest = browser
            }
        } else {
            toggle(browser: browser, isEnable: false)
        }
    }

    func permissionRequestSuccess() {
        guard let browser = permissionRequest
        else { return }

        toggle(browser: browser, isEnable: true)
    }

    func toggle(browser: Browser, isEnable: Bool) {
        preferencesVM.update {
            if isEnable {
                $0.isEnhancedModeEnabled = true
            }

            switch browser {
            case .Chrome:
                $0.isEnableURLSwitchForChrome = isEnable
            case .Chromium:
                $0.isEnableURLSwitchForChromium = isEnable
            case .Arc:
                $0.isEnableURLSwitchForArc = isEnable
            case .Safari:
                $0.isEnableURLSwitchForSafari = isEnable
            case .SafariTechnologyPreview:
                $0.isEnableURLSwitchForSafariTechnologyPreview = isEnable
            case .Edge:
                $0.isEnableURLSwitchForEdge = isEnable
            case .Brave:
                $0.isEnableURLSwitchForBrave = isEnable
            case .BraveBeta:
                $0.isEnableURLSwitchForBraveBeta = isEnable
            case .BraveNightly:
                $0.isEnableURLSwitchForBraveNightly = isEnable
            case .Vivaldi:
                $0.isEnableURLSwitchForVivaldi = isEnable
            case .Opera:
                $0.isEnableURLSwitchForOpera = isEnable
            case .Thorium:
                $0.isEnableURLSwitchForThorium = isEnable
            case .Firefox:
                $0.isEnableURLSwitchForFirefox = isEnable
            case .FirefoxDeveloperEdition:
                $0.isEnableURLSwitchForFirefoxDeveloperEdition = isEnable
            case .FirefoxNightly:
                $0.isEnableURLSwitchForFirefoxNightly = isEnable
            case .Zen:
                $0.isEnableURLSwitchForZen = isEnable
            }
        }
    }

    func handleBrowserAddressDefaultKeyboardSelect(_ index: Int) {
        let browserAddressDefaultKeyboard = inputSourceItems[index]

        preferencesVM.update {
            $0.browserAddressDefaultKeyboardId = browserAddressDefaultKeyboard.id
        }
    }
}
