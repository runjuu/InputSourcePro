import SwiftUI

struct SettingsSection<Content: View, Tips: View>: View {
    let title: String

    let tips: Tips?

    let noI18N: Bool

    let content: Content

    init(title: String, noI18N: Bool = false, tips: Tips? = nil, @ViewBuilder _ content: () -> Content) {
        self.title = title
        self.noI18N = noI18N
        self.tips = tips
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading) {
            if !title.isEmpty || tips != nil {
                HStack {
                    if !title.isEmpty {
                        Text(noI18N ? title : title.i18n())
                            .opacity(0.8)
                    }

                    tips
                }
                .padding(.horizontal)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity)
            .background(NSColor.background2.color)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(NSColor.border2.color, lineWidth: 1)
            )
        }
    }
}

// Support optional footer
extension SettingsSection where Tips == EmptyView {
    init(title: String, noI18N: Bool = false, @ViewBuilder _ content: () -> Content) {
        self.title = title
        self.noI18N = noI18N
        tips = nil
        self.content = content()
    }
}
