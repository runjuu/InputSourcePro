import Cocoa

extension HotKeyGroup {
    static let persistedIdentifierSeparator = "∆"

    var persistedInputSourceIdentifiers: [String] {
        return inputSourceIds?
            .components(separatedBy: Self.persistedIdentifierSeparator)
            .filter { !$0.isEmpty } ?? []
    }

    func updatePersistedInputSourceIdentifiers(_ identifiers: [String]) {
        inputSourceIds = identifiers.joined(separator: Self.persistedIdentifierSeparator)
    }

    @MainActor
    var inputSources: [InputSource] {
        get {
            return InputSource.resolvePersistedIdentifiers(persistedInputSourceIdentifiers)
        }
        set {
            updatePersistedInputSourceIdentifiers(newValue.map { $0.persistentIdentifier })
        }
    }
}
