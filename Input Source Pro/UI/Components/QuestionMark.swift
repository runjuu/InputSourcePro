import SwiftUI

struct QuestionMark<Content: View>: View {
    @State var isPresented: Bool = false

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Button(action: { isPresented.toggle() }) {
            SwiftUI.Image(systemName: "questionmark.circle")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            content
        }
    }
}
