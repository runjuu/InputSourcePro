import SwiftUI

enum RuleSettingIconStyle {
    static let size: CGFloat = 16
    static var imageFont: Font { .system(size: size) }
    static var textFont: Font { .system(size: size, weight: .regular, design: .rounded) }
}

struct RuleSettingIcon: View {
    enum Content {
        case system(String)
        case text(String)
    }

    let content: Content
    let color: Color

    init(systemName: String, color: Color = .primary) {
        content = .system(systemName)
        self.color = color
    }

    init(text: String, color: Color = .primary) {
        content = .text(text)
        self.color = color
    }

    var body: some View {
        Group {
            switch content {
            case .system(let name):
                Image(systemName: name)
                    .font(RuleSettingIconStyle.imageFont)
            case .text(let value):
                Text(value)
                    .font(RuleSettingIconStyle.textFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .foregroundColor(color)
        .frame(
            width: RuleSettingIconStyle.size,
            height: RuleSettingIconStyle.size,
            alignment: .center
        )
    }
}
