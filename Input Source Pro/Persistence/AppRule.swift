import Cocoa

extension AppRule {
    var image: NSImage? {
        guard let path = url else { return nil }

        return NSWorkspace.shared.icon(forFile: path.path)
    }
}

extension AppRule {
    @MainActor
    var forcedKeyboard: InputSource? {
        return InputSource.resolvePersistedIdentifier(inputSourceId)
    }

    var functionKeyMode: FKeyMode? {
        get {
            guard let rawValue = functionKeyModeRaw else { return nil }
            return FKeyMode(rawValue: rawValue)
        }
        set {
            functionKeyModeRaw = newValue?.rawValue
        }
    }
    
    var shouldForceEnglishPunctuation: Bool {
        return forceEnglishPunctuation
    }
}
