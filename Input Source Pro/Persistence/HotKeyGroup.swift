import Cocoa

extension HotKeyGroup {
    private static let separator = "∆"

    private var ids: [String] {
        return inputSourceIds?.components(separatedBy: Self.separator) ?? []
    }

    @MainActor
    var inputSources: [InputSource] {
        get {
            return ids.compactMap { InputSource.resolvePersistedIdentifier($0) }
        }
        set {
            inputSourceIds = newValue.map { $0.persistentIdentifier }.joined(separator: Self.separator)
        }
    }
}
