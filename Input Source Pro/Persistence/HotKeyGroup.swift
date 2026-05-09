import Cocoa

extension HotKeyGroup {
    private static let separator = "∆"

    var persistedInputSourceIdentifiers: [String] {
        return inputSourceIds?
            .components(separatedBy: Self.separator)
            .filter { !$0.isEmpty } ?? []
    }

    func updatePersistedInputSourceIdentifiers(_ identifiers: [String]) {
        inputSourceIds = identifiers.joined(separator: Self.separator)
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
