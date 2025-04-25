import SwiftUI

struct IndicatorAlignmentView<Content: View>: View {
    let content: Content

    let alignment: IndicatorPosition.Alignment

    init(
        alignment: IndicatorPosition.Alignment,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.alignment = alignment
    }

    var body: some View {
        VStack {
            if [.bottomLeft, .bottomRight, .bottomCenter].contains(alignment) {
                Spacer(minLength: 0)
            }

            HStack {
                if [.topRight, .bottomRight, .centerRight].contains(alignment) {
                    Spacer(minLength: 0)
                }

                content

                if [.topLeft, .bottomLeft, .centerLeft].contains(alignment) {
                    Spacer(minLength: 0)
                }
            }

            if [.topRight, .topLeft, .topCenter].contains(alignment) {
                Spacer(minLength: 0)
            }
        }
    }
}
