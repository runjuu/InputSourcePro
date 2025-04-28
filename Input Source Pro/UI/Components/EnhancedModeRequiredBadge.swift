import SwiftUI

struct EnhancedModeRequiredBadge: View {
    @EnvironmentObject var preferencesVM: PreferencesVM

    var body: some View {
        Button(action: {}) {
            Text("Enhanced Mode Required".i18n())
        }
        .buttonStyle(EnhanceMoreRequiredButtonStyle())
        .opacity(preferencesVM.preferences.isEnhancedModeEnabled ? 0 : 1)
        .animation(.easeInOut, value: preferencesVM.preferences.isEnhancedModeEnabled)
    }
}

struct EnhanceMoreRequiredButtonStyle: ButtonStyle {
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
