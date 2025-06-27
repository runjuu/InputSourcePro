import SwiftUI

struct RebootRequiredBadge: View {
    let isRequired: Bool
    
    var body: some View {
        Button(action: {}) {
            Text("System Reboot Required".i18n())
        }
        .buttonStyle(RebootRequiredButtonStyle())
        .opacity(isRequired ? 1 : 0)
        .animation(.easeInOut, value: isRequired)
    }
}

struct RebootRequiredButtonStyle: ButtonStyle {
    func makeBody(configuration: Self.Configuration) -> some View {
        configuration.label
            .font(.system(size: 10))
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(Color.gray)
            .foregroundColor(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
    }
}
