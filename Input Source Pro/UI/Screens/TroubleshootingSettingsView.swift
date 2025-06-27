import SwiftUI

struct TroubleshootingSettingsView: View {
    @EnvironmentObject var preferencesVM: PreferencesVM

    @State var isShowCJKVFixEnableFailedView = false

    var body: some View {
        let isCJKVFixEnabledBinding = Binding(
            get: { preferencesVM.preferences.isCJKVFixEnabled },
            set: { onToggleCJKVFix($0) }
        )

        ScrollView {
            VStack(spacing: 18) {
                SettingsSection(title: "") {
                    VStack(alignment: .leading) {
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
            if InputSource.getSelectPreviousShortcut() == nil {
                isShowCJKVFixEnableFailedView = true
            } else {
                preferencesVM.update {
                    $0.isCJKVFixEnabled = true
                }
            }
        } else {
            preferencesVM.update {
                $0.isCJKVFixEnabled = false
            }
        }
    }
}

enum CursorSettingStatus {
    case enabled
    case disabled
    case undefined
    case unknown
}
