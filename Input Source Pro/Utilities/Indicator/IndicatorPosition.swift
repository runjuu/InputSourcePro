import AppKit

enum IndicatorActuallyPositionKind {
    case floatingApp
    case inputCursor
    case inputRect
    case nearMouse
    case windowCorner
    case screenCorner

    var isInputArea: Bool {
        self == .inputRect || self == .inputCursor
    }
}

enum IndicatorPosition: Int32, CaseIterable, Identifiable {
    case nearMouse = 0
    case windowCorner = 1
    case screenCorner = 2

    var id: Self { self }

    enum Alignment: Int32, CaseIterable {
        case topLeft = 0
        case topCenter = 5
        case topRight = 1
        case centerLeft = 7
        case center = 2
        case centerRight = 8
        case bottomLeft = 3
        case bottomCenter = 6
        case bottomRight = 4
    }

    enum Spacing: Int32, CaseIterable {
        case none = 0
        case xs = 1
        case s = 2
        case m = 3
        case l = 4
        case xl = 5
    }
}

extension IndicatorPosition {
    var name: String {
        switch self {
        case .nearMouse:
            return "Follow Mouse".i18n()
        case .windowCorner:
            return "Relative to App".i18n()
        case .screenCorner:
            return "Relative to Screen".i18n()
        }
    }
}

extension IndicatorPosition.Alignment {
    var name: String {
        switch self {
        case .topLeft:
            return "Top-Left Corner".i18n()
        case .topRight:
            return "Top-Right Corner".i18n()
        case .topCenter:
            return "Top-Center".i18n()
        case .center:
            return "Center".i18n()
        case .centerLeft:
            return "Center-Left".i18n()
        case .centerRight:
            return "Center-Right".i18n()
        case .bottomLeft:
            return "Bottom-Left Corner".i18n()
        case .bottomCenter:
            return "Bottom-Center".i18n()
        case .bottomRight:
            return "Bottom-Right Corner".i18n()
        }
    }
}

extension IndicatorPosition.Spacing {
    static func fromSlide(value: Double) -> Self {
        return .init(rawValue: Int32(value)) ?? .m
    }

    var name: String {
        switch self {
        case .none:
            return "Nope".i18n()
        case .xs:
            return "XS".i18n()
        case .s:
            return "S".i18n()
        case .m:
            return "M".i18n()
        case .l:
            return "L".i18n()
        case .xl:
            return "XL".i18n()
        }
    }
}

extension IndicatorPosition: Codable {
    private enum CodingKeys: String, CodingKey {
        case base
    }

    private enum Base: String, Codable {
        case nearMouse, windowCorner, screenCorner
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .nearMouse:
            try container.encode(Base.nearMouse, forKey: .base)
        case .windowCorner:
            try container.encode(Base.windowCorner, forKey: .base)
        case .screenCorner:
            try container.encode(Base.screenCorner, forKey: .base)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let base = try container.decode(Base.self, forKey: .base)

        switch base {
        case .nearMouse:
            self = .nearMouse
        case .windowCorner:
            self = .windowCorner
        case .screenCorner:
            self = .screenCorner
        }
    }
}

extension IndicatorPosition.Alignment: Codable {
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

extension IndicatorPosition.Spacing: Codable {
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
