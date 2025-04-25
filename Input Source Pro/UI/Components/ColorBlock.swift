import SwiftUI

struct ColorBlocks: View {
    typealias Scheme = (a: Color, b: Color)

    let onSelectColor: (Scheme) -> Void

    let colors: [Scheme] = [
        (.init(hex: "#FFF"), .init(hex: "#000")),
        (.init(hex: "#FFF"), .init(hex: "#ef233c")),
        (.init(hex: "#FFF"), .init(hex: "#f77f00")),
        (.init(hex: "#000"), .init(hex: "#F6CB56")),
        (.init(hex: "#FFF"), .init(hex: "#2c6e49")),
        (.init(hex: "#FFF"), .init(hex: "#0c7489")),
        (.init(hex: "#FFF"), .init(hex: "#023e8a")),
        (.init(hex: "#FFF"), .init(hex: "#7209b7")),
    ]

    var body: some View {
        HStack {
            ForEach(Array(zip(colors.indices, colors)), id: \.0) { _, scheme in
                Spacer()
                ColorBlock(colorA: scheme.a, colorB: scheme.b)
                    .onTapGesture {
                        onSelectColor(scheme)
                    }
                Spacer()
            }
        }
    }
}

struct ColorBlock: View {
    let colorA: Color

    let colorB: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(colorB)
            .overlay(
                SwiftUI.Image(systemName: "textformat")
                    .foregroundColor(colorA)
                    .font(.system(size: 12, weight: .semibold))
            )
            .frame(width: 28, height: 20)
    }
}
