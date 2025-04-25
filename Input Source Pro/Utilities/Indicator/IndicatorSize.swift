import AppKit

enum IndicatorSize: Int32, CaseIterable, Identifiable {
    case small = 1
    case medium = 2
    case large = 3

    var displayName: String {
        switch self {
        case .small:
            return "Small".i18n()
        case .medium:
            return "Medium".i18n()
        case .large:
            return "Large".i18n()
        }
    }

    var id: Self { self }
}

extension IndicatorSize: Codable {
    private enum CodingKeys: String, CodingKey {
        case base
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .base)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawValue = try container.decode(Int32.self, forKey: .base)

        self = Self(rawValue: rawValue)!
    }
}
