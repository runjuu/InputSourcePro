import Cocoa

enum BrowserRuleType: Int32, CaseIterable {
    case domainSuffix = 0
    case domain = 1
    case urlRegex = 2

    var name: String {
        switch self {
        case .domainSuffix:
            return "DOMAIN-SUFFIX"
        case .domain:
            return "DOMAIN"
        case .urlRegex:
            return "URL-REGEX"
        }
    }

    var explanation: String {
        return "\(name) Explanation".i18n()
    }
}

extension BrowserRule {
    @MainActor
    var forcedKeyboard: InputSource? {
        guard let inputSourceId = inputSourceId else { return nil }

        return InputSource.sources.first { $0.id == inputSourceId }
    }

    var type: BrowserRuleType {
        get {
            return BrowserRuleType(rawValue: typeValue) ?? .domainSuffix
        }

        set {
            typeValue = newValue.rawValue
        }
    }

    func validate(url: URL) -> Bool {
        return Self.validate(type: type, url: url, value: value)
    }

    func id() -> String {
        return "\(type.name)_\(value ?? "")_\(createdAt?.timeIntervalSince1970 ?? 0)"
    }
}

extension BrowserRule {
    static func validate(type: BrowserRuleType, url: URL, value: String?) -> Bool {
        switch type {
        case .domainSuffix:
            if let suffix = value,
               let host = url.host,
               let regex = try? NSRegularExpression(pattern: "\(suffix)$", options: .caseInsensitive)
            {
                return regex.matches(host)
            }
            return false
        case .domain:
            return url.host == value
        case .urlRegex:
            if let regex = try? NSRegularExpression(pattern: value ?? "", options: .caseInsensitive) {
                return regex.matches(url.absoluteString)
            }
            return false
        }
    }
}

extension BrowserRule {
    var keyboardRestoreStrategy: KeyboardRestoreStrategy? {
        guard let rawValue = keyboardRestoreStrategyRaw
        else { return nil }

        return KeyboardRestoreStrategy(rawValue: rawValue)
    }
}
