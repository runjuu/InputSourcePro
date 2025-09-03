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
        guard let inputSourceId = inputSourceId else { return nil }

        return InputSource.sources.first { $0.id == inputSourceId }
    }
    
    var shouldForceEnglishPunctuation: Bool {
        return forceEnglishPunctuation
    }
}
