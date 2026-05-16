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
        return InputSource.resolvePersistedIdentifier(inputSourceId)
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
    static func firstEnabledRule(matching url: URL, in rules: [BrowserRule]) -> BrowserRule? {
        return rules.first { !$0.disabled && $0.validate(url: url) }
    }

    static func validate(type: BrowserRuleType, url: URL, value: String?) -> Bool {
        switch type {
        case .domainSuffix:
            guard let suffix = normalizedDomain(value),
                  let host = normalizedDomain(url.host)
            else { return false }

            return host == suffix || host.hasSuffix(".\(suffix)")
        case .domain:
            guard let domain = normalizedDomain(value),
                  let host = normalizedDomain(url.host)
            else { return false }

            return host == domain
        case .urlRegex:
            if let regex = try? NSRegularExpression(pattern: value ?? "", options: .caseInsensitive) {
                return regex.matches(url.absoluteString)
            }
            return false
        }
    }

    private static func normalizedDomain(_ value: String?) -> String? {
        let domain = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()

        guard let domain, !domain.isEmpty else { return nil }
        return domain
    }
}

extension BrowserRule {
    var keyboardRestoreStrategy: KeyboardRestoreStrategy? {
        guard let rawValue = keyboardRestoreStrategyRaw
        else { return nil }

        return KeyboardRestoreStrategy(rawValue: rawValue)
    }
}
