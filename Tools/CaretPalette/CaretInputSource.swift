import Carbon

enum CaretInputSource {
    static func find(_ identifier: String, bundleIdentifier: String? = nil) -> TISInputSource? {
        // TIS returns nil, rather than an empty array, for some unregistered sources.
        var properties = [kTISPropertyInputSourceID as String: identifier]
        if let bundleIdentifier = bundleIdentifier { properties[kTISPropertyBundleID as String] = bundleIdentifier }
        guard let result = TISCreateInputSourceList(properties as CFDictionary, true) else { return nil }
        return (result.takeRetainedValue() as? [TISInputSource])?.first
    }
}
