import Cocoa

extension HotKeyGroup {
    private static let separator = "∆"

    private var ids: [String] {
        return inputSourceIds?.components(separatedBy: Self.separator) ?? []
    }

    @MainActor
    var inputSources: [InputSource] {
        get {
            return InputSource.sources
                .filter { ids.contains($0.id) }
        }
        set {
            inputSourceIds = newValue.map { $0.id }.joined(separator: Self.separator)
        }
    }
}
