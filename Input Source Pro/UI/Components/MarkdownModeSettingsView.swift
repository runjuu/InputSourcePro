import SwiftUI

struct MarkdownModeSettingsView: View {
    @Binding var isEnabled: Bool
    let isInputMonitoringEnabled: Bool
    let isAccessibilityEnabled: Bool
    let failure: PunctuationService.Failure?

    var body: some View {
        SettingsSection(title: "Markdown Mode") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Enable Markdown Mode".i18n(), isOn: $isEnabled)
                        .labelsHidden()
                    Text("Enable Markdown Mode".i18n())
                        .accessibilityHidden(true)
                    Spacer()
                }

                Text("Markdown Mode Description".i18n())
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if !isInputMonitoringEnabled || !isAccessibilityEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Markdown Mode Permissions Description".i18n())
                            .font(.subheadline)

                        if !isInputMonitoringEnabled {
                            Button("Open Permission Settings".i18n()) {
                                NSWorkspace.shared.openInputMonitoringPreferences()
                            }
                        }

                        if !isAccessibilityEnabled {
                            Button("Open Accessibility Settings".i18n()) {
                                NSWorkspace.shared.openAccessibilityPreferences()
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(NSColor.background1.color)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if let failure, let message = failureMessage(failure) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Markdown Mode Is Off".i18n())
                            .fontWeight(.medium)
                        Text(message.i18n())
                            .font(.subheadline)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()
        }
    }

    private func failureMessage(_ failure: PunctuationService.Failure) -> String? {
        switch failure {
        case .missingPermissions:
            return nil
        case .anotherInstanceRunning:
            return "Markdown Mode Another Instance Description"
        case .eventTapCreationFailed:
            return "Markdown Mode Activation Failed Description"
        case .eventTapDisabled:
            return "Markdown Mode Tap Disabled Description"
        case .handlerTimedOut:
            return "Markdown Mode Timeout Description"
        }
    }
}
