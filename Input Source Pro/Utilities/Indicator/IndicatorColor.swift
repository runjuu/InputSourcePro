import SwiftUI

struct IndicatorColor {
    let light: Color
    let dark: Color
}

extension IndicatorColor {
    var dynamicColor: NSColor {
        return NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.darkAqua]) {
            case .darkAqua?:
                return NSColor(self.dark)
            default:
                return NSColor(self.light)
            }
        }
    }
}

extension IndicatorColor {
    static let background = IndicatorColor(
        light: .white.opacity(0.95),
        dark: .black
    )

    static let forgeground = IndicatorColor(
        light: .black,
        dark: .white
    )
}

extension IndicatorColor: Codable {
    private enum CodingKeys: String, CodingKey { case light, dark }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lightStr = try container.decode(String.self, forKey: .light)
        let darkStr = try container.decode(String.self, forKey: .dark)

        light = Color(hex: lightStr)
        dark = Color(hex: darkStr)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(light.hexWithAlpha, forKey: .light)
        try container.encode(dark.hexWithAlpha, forKey: .dark)
    }
}
