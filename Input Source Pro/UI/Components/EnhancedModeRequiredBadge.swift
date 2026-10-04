import SwiftUI

struct EnhancedModeRequiredBadge: View {
    @EnvironmentObject var preferencesVM: PreferencesVM
    @EnvironmentObject var permissionsVM: PermissionsVM

    @State private var isShowAccessibilityRequest = false

    var body: some View {
        Button(action: enableEnhancedMode) {
            Text("Enhanced Mode Required".i18n())
        }
        .buttonStyle(EnhanceModeRequiredButtonStyle())
        .disabled(preferencesVM.preferences.isEnhancedModeEnabled)
        .accessibilityHidden(preferencesVM.preferences.isEnhancedModeEnabled)
        .opacity(preferencesVM.preferences.isEnhancedModeEnabled ? 0 : 1)
        .animation(.easeInOut, value: preferencesVM.preferences.isEnhancedModeEnabled)
        .sheet(isPresented: $isShowAccessibilityRequest) {
            AccessibilityPermissionRequestView(isPresented: $isShowAccessibilityRequest)
        }
    }

    private func enableEnhancedMode() {
        if permissionsVM.isAccessibilityEnabled {
            preferencesVM.update {
                $0.isEnhancedModeEnabled = true
            }
        } else {
            isShowAccessibilityRequest = true
        }
    }
}

struct EnhanceModeRequiredButtonStyle: ButtonStyle {
    func makeBody(configuration: Self.Configuration) -> some View {
        configuration.label
            .font(.system(size: 10))
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(Color.yellow)
            .foregroundColor(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
    }
}
