import Foundation

enum IndicatorInfo: Int32, CaseIterable, Identifiable {
    case iconAndTitle = 0
    case iconOnly = 1
    case titleOnly = 2

    var id: Self { self }

    var name: String {
        switch self {
        case .iconAndTitle: return "Icon and Title".i18n()
        case .iconOnly: return "Icon".i18n()
        case .titleOnly: return "Title".i18n()
        }
    }
}

extension IndicatorInfo: Codable {
    private enum CodingKeys: String, CodingKey {
        case base
    }

    private enum Base: String, Codable {
        case iconAndTitle, iconOnly, titleOnly
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .iconAndTitle:
            try container.encode(Base.iconAndTitle, forKey: .base)
        case .iconOnly:
            try container.encode(Base.iconOnly, forKey: .base)
        case .titleOnly:
            try container.encode(Base.titleOnly, forKey: .base)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let base = try container.decode(Base.self, forKey: .base)

        switch base {
        case .iconAndTitle:
            self = .iconAndTitle
        case .iconOnly:
            self = .iconOnly
        case .titleOnly:
            self = .titleOnly
        }
    }
}
