import SwiftUI

struct QuestionMark<Content: View>: View {
    @State var isPresented: Bool = false

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Button(action: { isPresented.toggle() }) {
            SwiftUI.Image(systemName: "questionmark")
        }
        .font(.system(size: 10).weight(.bold))
        .frame(width: 18, height: 18)
        .cornerRadius(99)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            content
        }
    }
}
