import Carbon

enum CaretInputSource {
    static func find(_ identifier: String) -> TISInputSource? {
        // TIS returns nil, rather than an empty array, for some unregistered sources.
        guard let result = TISCreateInputSourceList(
            [kTISPropertyInputSourceID as String: identifier] as CFDictionary, true
        ) else { return nil }
        return (result.takeRetainedValue() as? [TISInputSource])?.first
    }
}
