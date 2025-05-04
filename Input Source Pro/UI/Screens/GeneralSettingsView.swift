import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var preferencesVM: PreferencesVM
    @EnvironmentObject var permissionsVM: PermissionsVM

    @State var isDetectSpotlightLikeApp = false

    var items: [PickerItem] {
        [PickerItem.empty]
            + InputSource.sources.map { PickerItem(id: $0.id, title: $0.name, toolTip: $0.id) }
    }

    var body: some View {
        let keyboardRestoreStrategyBinding = Binding(
            get: { preferencesVM.preferences.isRestorePreviouslyUsedInputSource ?
                KeyboardRestoreStrategy.RestorePreviouslyUsedOne :
                KeyboardRestoreStrategy.UseDefaultKeyboardInstead
            },
            set: { newValue in
                preferencesVM.update {
                    switch newValue {
                    case .RestorePreviouslyUsedOne:
                        $0.isRestorePreviouslyUsedInputSource = true
                    case .UseDefaultKeyboardInstead:
                        $0.isRestorePreviouslyUsedInputSource = false
                    }
                }
            }
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSection(title: "") {
                    PromotionBadge()
                }
                
                SettingsSection(title: "") {
                    EnhancedModeToggle()
                }

                SettingsSection(title: "Default Keyboard") {
                    HStack {
                        Text("For All Apps and Websites".i18n())

                        PopUpButtonPicker<PickerItem?>(
                            items: items,
                            isItemSelected: { $0?.id == preferencesVM.preferences.systemWideDefaultKeyboardId },
                            getTitle: { $0?.title ?? "" },
                            getToolTip: { $0?.toolTip },
                            onSelect: handleSystemWideDefaultKeyboardSelect
                        )
                    }
                    .padding()
                    .border(width: 1, edges: [.bottom], color: NSColor.border2.color)
                }

                SettingsSection(title: "Keyboard Restore Strategy") {
                    VStack(alignment: .leading) {
                        Text("When Switching Back to the App or Website".i18n() + ":")

                        Picker("Keyboard Restore Strategy", selection: keyboardRestoreStrategyBinding) {
                            ForEach(KeyboardRestoreStrategy.allCases) { item in
                                Text(item.name).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding()
                }

                Group {
                    SettingsSection(title: "Indicator Triggers") {
                        HStack {
                            Toggle("", isOn: $preferencesVM.preferences.isActiveWhenLongpressLeftMouse)

                            Text("isActiveWhenLongpressLeftMouse".i18n())

                            Spacer()
                        }
                        .padding()
                        .border(width: 1, edges: [.bottom], color: NSColor.border2.color)

                        HStack {
                            Toggle("", isOn: $preferencesVM.preferences.isActiveWhenSwitchInputSource)

                            Text("isActiveWhenSwitchInputSource".i18n())

                            Spacer()
                        }
                        .padding()
                        .border(width: 1, edges: [.bottom], color: NSColor.border2.color)

                        HStack {
                            Toggle("", isOn: $preferencesVM.preferences.isActiveWhenSwitchApp)

                            Text("isActiveWhenSwitchApp".i18n())

                            Spacer()
                        }
                        .padding()
                        .border(width: 1, edges: [.bottom], color: NSColor.border2.color)

                        HStack {
                            Toggle("", isOn: $preferencesVM.preferences.isActiveWhenFocusedElementChanges)
                                .disabled(!preferencesVM.preferences.isEnhancedModeEnabled)

                            Text("isActiveWhenFocusedElementChanges".i18n())

                            Spacer()

                            EnhancedModeRequiredBadge()
                        }
                        .padding()
                        .border(width: 1, edges: [.bottom], color: NSColor.border2.color)
                    }

                    SettingsSection(title: "") {
                        HStack {
                            Toggle("",
                                   isOn: $preferencesVM.preferences.isHideWhenSwitchAppWithForceKeyboard)
                                .disabled(!(
                                    preferencesVM.preferences.isActiveWhenSwitchApp ||
                                        preferencesVM.preferences.isActiveWhenSwitchInputSource ||
                                        preferencesVM.preferences.isActiveWhenFocusedElementChanges
                                ))

                            Text("isHideWhenSwitchAppWithForceKeyboard")

                            Spacer()
                        }
                        .padding()
                    }
                }

                Group {
                    SettingsSection(title: "System") {
                        HStack {
                            Toggle("", isOn: $preferencesVM.preferences.isLaunchAtLogin)
                            Text("Launch at Login".i18n())
                            Spacer()
                        }
                        .padding()
                        .border(width: 1, edges: [.bottom], color: NSColor.border2.color)

                        HStack {
                            Toggle("", isOn: $preferencesVM.preferences.isShowIconInMenuBar)
                            Text("Display Icon in Menu Bar".i18n())
                            Spacer()
                        }
                        .padding()
                    }

                    SettingsSection(title: "Updates") {
                        HStack {
                            Toggle("", isOn: $preferencesVM.preferences.receiveBetaUpdates)
                            Text("Receive Beta Updates".i18n())
                            Spacer()
                        }
                        .padding()
                        .border(width: 1, edges: [.bottom], color: NSColor.border2.color)
                        
                        Button(action: { preferencesVM.checkUpdates() }, label: {
                            HStack {
                                Text("Check for Updates".i18n() + "...")

                                Spacer()

                                Text(" \(preferencesVM.versionStr) (\(preferencesVM.buildStr))")
                                    .foregroundColor(Color.primary.opacity(0.5))
                            }
                        })
                        .buttonStyle(SectionButtonStyle())
                    }
                }

                Group {
                    SettingsSection(title: "Find Us", tips: Text("Right click each section to copy link").font(.subheadline).opacity(0.5)) {
                        Button(action: { URL.website.open() }, label: {
                            HStack {
                                Text("Website".i18n())
                                    .foregroundColor(Color.primary)

                                Spacer()

                                Text(URL.website.absoluteString)
                            }
                        })
                        .buttonStyle(SectionButtonStyle())
                        .contextMenu {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(URL.website.absoluteString, forType: .string)
                            }
                        }
                        .border(width: 1, edges: [.bottom], color: NSColor.border2.color)

                        Button(action: { URL.twitter.open() }, label: {
                            HStack {
                                Text("Twitter")
                                    .foregroundColor(Color.primary)

                                Spacer()

                                Text("@Runjuu")
                            }
                        })
                        .buttonStyle(SectionButtonStyle())
                        .contextMenu {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(URL.twitter.absoluteString, forType: .string)
                            }
                        }
                        .border(width: 1, edges: [.bottom], color: NSColor.border2.color)

                        Button(action: { URL.email.open() }, label: {
                            HStack {
                                Text("Email")
                                    .foregroundColor(Color.primary)

                                Spacer()

                                Text(URL.emailString)
                            }
                        })
                        .buttonStyle(SectionButtonStyle())
                        .contextMenu {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(URL.emailString, forType: .string)
                            }
                        }
                    }

                    SettingsSection(title: "") {
                        FeedbackButton()
                    }
                }

                SettingsSection(title: "Privacy") {
                    HStack {
                        Text("Privacy Content".i18n())
                            .multilineTextAlignment(.leading)
                            .padding()
                            .opacity(0.8)

                        Spacer(minLength: 0)
                    }
                }

                HStack {
                    Spacer()
                    Text("Created by Runjuu & Die2")
                    Spacer()
                }
                .font(.footnote)
                .opacity(0.5)
            }
            .padding()
        }
        .labelsHidden()
        .toggleStyle(.switch)
        .background(NSColor.background1.color)
        .onAppear(perform: disableIsDetectSpotlightLikeAppIfNeed)
    }

    func disableIsDetectSpotlightLikeAppIfNeed() {
        if !permissionsVM.isAccessibilityEnabled && preferencesVM.preferences.isEnhancedModeEnabled {
            preferencesVM.update {
                $0.isEnhancedModeEnabled = false
            }
        }
    }

    func handleSystemWideDefaultKeyboardSelect(_ index: Int) {
        let defaultKeyboard = items[index]

        preferencesVM.update {
            $0.systemWideDefaultKeyboardId = defaultKeyboard.id
        }
    }
}
