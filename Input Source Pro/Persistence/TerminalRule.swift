import Foundation

/// Picks an input source for a program running in a terminal (claude, nvim…).
/// Stored in UserDefaults as part of `Preferences.terminalRules`.
struct TerminalRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var program: String
    var inputSourceId: String?
    var disabled = false
    var createdAt = Date()

    @MainActor
    var forcedKeyboard: InputSource? {
        InputSource.resolvePersistedIdentifier(inputSourceId)
    }

    /// Exact match against the program's key or name, ignoring case and
    /// surrounding whitespace.
    func matches(_ program: TerminalProgram) -> Bool {
        let value = Self.normalized(self.program)
        guard !value.isEmpty else { return false }

        return [program.key, program.name].contains { $0.map(Self.normalized) == value }
    }

    static func firstEnabledRule(
        matching program: TerminalProgram,
        in rules: [TerminalRule],
        where isUsable: (TerminalRule) -> Bool = { _ in true }
    ) -> TerminalRule? {
        rules.first { !$0.disabled && $0.matches(program) && isUsable($0) }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension TerminalRule {
    /// Only `program` is required, so a rule stored or backed up without a field added
    /// later still reads: the synthesized decoder would fail on it, and one unreadable
    /// rule empties the stored list and rejects a whole backup.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            program: try container.decode(String.self, forKey: .program),
            inputSourceId: try container.decodeIfPresent(String.self, forKey: .inputSourceId),
            disabled: try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false,
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        )
    }
}
