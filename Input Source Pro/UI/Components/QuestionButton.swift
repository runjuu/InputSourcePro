import SwiftUI

struct QuestionButton<Content: View, Popover: View>: View {
    @State var displayTips = false

    @Environment(\.colorScheme) var colorScheme: ColorScheme

    let content: () -> Content
    let popover: (ColorScheme) -> Popover

    init(
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder popover: @escaping (ColorScheme) -> Popover
    ) {
        self.content = content
        self.popover = popover
    }

    var body: some View {
        Button(action: { displayTips.toggle() }) {
            content()
                .font(.body.bold())
        }
        .buttonStyle(QuestionButtonStyle())
        .popover(isPresented: $displayTips, arrowEdge: .top) {
            VStack(spacing: 0) {
                popover(colorScheme)
            }
            .frame(width: 280)
        }
    }
}

struct QuestionButtonStyle: ButtonStyle {
    @State var isHover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isHover ? 1 : 0.8)
            .background(Color.gray.opacity(configuration.isPressed ? 0.6 : isHover ? 0.3 : 0.15))
            .clipShape(Circle())
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
            .onHover { hover in
                withAnimation {
                    isHover = hover
                }
            }
    }
}
