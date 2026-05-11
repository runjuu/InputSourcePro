import SwiftUI

struct TroubleshootingSettingsView: View {
    @EnvironmentObject var preferencesVM: PreferencesVM

    @State var isShowCJKVFixEnableFailedView = false

    var body: some View {
        let isCJKVFixEnabledBinding = Binding(
            get: { preferencesVM.preferences.isCJKVFixEnabled },
            set: { onToggleCJKVFix($0) }
        )
        let cJKVFixStrategyBinding = Binding(
            get: { preferencesVM.preferences.cJKVFixStrategy },
            set: { onSelectCJKVFixStrategy($0) }
        )

        ScrollView {
            VStack(spacing: 18) {
                SettingsSection(title: "") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Toggle("", isOn: isCJKVFixEnabledBinding)
                                .disabled(!preferencesVM.preferences.isEnhancedModeEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()

                            Text("Enabled CJKV Fix".i18n())
                                .font(.headline)

                            Spacer()

                            EnhancedModeRequiredBadge()
                        }

                        Text(.init("Enabled CJKV Fix Description".i18n()))
                            .font(.system(size: 12))
                            .opacity(0.8)

                        VStack(alignment: .leading, spacing: 6) {
                            Picker("", selection: cJKVFixStrategyBinding) {
                                ForEach(CJKVFixStrategy.allCases) { strategy in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(strategy.name)

                                        Text(strategy.explanation)
                                            .font(.body)
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .tag(strategy)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.radioGroup)
                            .accessibilityLabel("CJKV Fix Method".i18n())
                            .disabled(
                                !preferencesVM.preferences.isEnhancedModeEnabled ||
                                    !preferencesVM.preferences.isCJKVFixEnabled
                            )
                        }
                    }
                    .padding()
                }
                
                SettingsSection(title: "") {
                    CursorLagFixView()
                }

                SettingsSection(title: "") {
                    FeedbackButton()
                }
            }
            .padding()
        }
        .background(NSColor.background1.color)
        .sheet(isPresented: $isShowCJKVFixEnableFailedView) {
            CJKVFixEnableFailedView(isPresented: $isShowCJKVFixEnableFailedView)
        }
    }

    func onToggleCJKVFix(_ isCJKVFixEnabled: Bool) {
        if isCJKVFixEnabled {
            let selectedStrategy = preferencesVM.preferences.cJKVFixStrategy

            if selectedStrategy == .previousInputSourceShortcut,
               InputSourceSwitcher.getPreviousInputSourceShortcut() == nil {
                isShowCJKVFixEnableFailedView = true
            } else {
                preferencesVM.update {
                    $0.isCJKVFixEnabled = true
                    $0.cJKVFixStrategy = selectedStrategy
                }
            }
        } else {
            preferencesVM.update {
                $0.isCJKVFixEnabled = false
            }
        }
    }

    func onSelectCJKVFixStrategy(_ cJKVFixStrategy: CJKVFixStrategy) {
        if cJKVFixStrategy == .previousInputSourceShortcut,
           InputSourceSwitcher.getPreviousInputSourceShortcut() == nil {
            isShowCJKVFixEnableFailedView = true
            return
        }

        preferencesVM.update {
            $0.cJKVFixStrategy = cJKVFixStrategy
        }
    }
}

enum CursorSettingStatus {
    case enabled
    case disabled
    case undefined
    case unknown
}
