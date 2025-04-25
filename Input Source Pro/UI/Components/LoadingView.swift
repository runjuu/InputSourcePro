import SwiftUI

struct LoadingView<Content>: View where Content: View {
    var isShowing: Bool

    var content: () -> Content

    var body: some View {
        ZStack(alignment: .center) {
            self.content()
                .disabled(isShowing)
                .opacity(isShowing ? 0.5 : 1)

            VStack {
                ProgressView()
                    .frame(width: 30, height: 30)
            }
            .opacity(isShowing ? 1 : 0)
            .animation(.easeOut, value: isShowing)
        }
    }
}
