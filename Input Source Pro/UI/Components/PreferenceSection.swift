import SwiftUI

struct PreferenceSection<Content: View>: View {
    let title: String

    let content: Content

    let hideDivider: Bool

    init(title: String, hideDivider: Bool = false, @ViewBuilder _ content: () -> Content) {
        self.title = title
        self.hideDivider = hideDivider
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack {
                    Text(title.isEmpty ? title : "\(title.i18n()):")
                        .fontWeight(.bold)
                        .tracking(0.2)
                        .frame(width: 100, alignment: .leading)
                }

                VStack(alignment: .leading) {
                    content
                }

                Spacer(minLength: 0)
            }

            if !hideDivider {
                Divider()
                    .padding(.vertical)
            }
        }
    }
}
