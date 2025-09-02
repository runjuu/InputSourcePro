import SwiftUI

struct InputMonitoringRequiredBadge: View {
    @EnvironmentObject var permissionsVM: PermissionsVM

    var body: some View {
        Button(action: {
            NSWorkspace.shared.openInputMonitoringPreferences()
        }) {
            Text("Input Monitoring Required".i18n())
        }
        .buttonStyle(InputMonitoringRequiredButtonStyle())
        .opacity(permissionsVM.isInputMonitoringEnabled ? 0 : 1)
        .animation(.easeInOut, value: permissionsVM.isInputMonitoringEnabled)
    }
}

struct InputMonitoringRequiredButtonStyle: ButtonStyle {
    func makeBody(configuration: Self.Configuration) -> some View {
        configuration.label
            .font(.system(size: 10))
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(Color.orange)
            .foregroundColor(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
    }
}