import SwiftUI

struct GhostButton<Icon: View>: ButtonStyle {
    @State var isHover = false

    let icon: Icon

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            icon

            if isHover {
                configuration.label
                    .scaleEffect(0.9)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .opacity(isHover ? 1 : 0.6)
        .background(Color.gray.opacity(configuration.isPressed ? 0.6 : isHover ? 0.3 : 0))
        .clipShape(Capsule())
        .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
        .onHover { hover in
            withAnimation {
                isHover = hover
            }
        }
    }
}

struct SectionButtonStyle: ButtonStyle {
    func makeBody(configuration: Self.Configuration) -> some View {
        configuration.label
            .padding()
            .frame(maxWidth: .infinity)
            .background(configuration.isPressed ? Color.gray.opacity(0.05) : Color.clear)
            .foregroundColor(Color.accentColor)
            .cornerRadius(6)
            .contentShape(Rectangle())
    }
}
