import Foundation

enum CaretHelperFiles {
    static let sourceID = "com.runjuu.Input-Source-Pro.inputmethod.PaletteControl"
    static let installedAppName = "Cursor Helper.app"
    static let legacyAppName = "ISP Palette Control.app"
    static let legacySourceID = "dev.inputsourcepro.inputmethod.PaletteControl"

    static func legacyInstallation(nextTo destination: URL) throws -> URL? {
        let legacy = destination.deletingLastPathComponent().appendingPathComponent(legacyAppName)
        guard legacy != destination, FileManager.default.fileExists(atPath: legacy.path) else { return nil }
        try validate(legacy, identifiers: [sourceID, legacySourceID])
        return legacy
    }

    private static func validate(_ url: URL, identifiers: Set<String>) throws {
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        guard let identifier = info?["CFBundleIdentifier"] as? String, identifiers.contains(identifier) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    static func migrateLegacy(_ legacy: URL?, backup: URL, install: () throws -> Void,
                              register: (URL) throws -> Void) throws {
        guard let legacy = legacy else { try install(); return }
        try validate(legacy, identifiers: [sourceID, legacySourceID])
        let manager = FileManager.default
        try manager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: legacy, to: backup)
        try manager.removeItem(at: legacy)
        do { try install() }
        catch {
            let installError = error
            try manager.copyItem(at: backup, to: legacy)
            try register(legacy)
            throw installError
        }
    }

    static func permissionDescriptor(_ flattened: CFDictionary, installedBundle: URL) throws -> CFDictionary {
        let plist = installedBundle.appendingPathComponent("Contents/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
        guard let identifier = info?["CFBundleIdentifier"] as? String,
              identifier == sourceID,
              var descriptor = flattened as? [String: Any],
              descriptor["InputSourceKind"] as? String == "Non Keyboard Input Method" else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: plist.path])
        }
        // TIS can retain the old bundle ID after a helper is replaced at the same path.
        // Settings resolves the installed identity instead of that process's cached identity.
        descriptor["Bundle ID"] = identifier
        return descriptor as CFDictionary
    }

    static func install(staged: URL, destination: URL, backup: URL?, register: (URL) throws -> Void) throws {
        let manager = FileManager.default
        if let backup = backup {
            try manager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: destination, to: backup)
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: destination)
        }
        do {
            try register(destination)
        } catch {
            let registrationError = error
            try manager.removeItem(at: destination)
            if let backup = backup {
                try manager.copyItem(at: backup, to: destination)
                try register(destination)
            }
            throw registrationError
        }
    }

    /// Validate the whole removal set before deleting anything. Unknown files are preserved.
    static func removalCandidates(destination: URL, backups: URL) throws -> [URL] {
        let manager = FileManager.default
        var result: [URL] = []
        func rejectSymlink(_ url: URL) throws {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        func appendBundle(_ url: URL, identifiers: Set<String> = [sourceID]) throws {
            guard manager.fileExists(atPath: url.path) else { return }
            try rejectSymlink(url)
            try validate(url, identifiers: identifiers)
            result.append(url)
        }
        try appendBundle(destination)
        if let legacy = try legacyInstallation(nextTo: destination) { result.append(legacy) }
        if manager.fileExists(atPath: backups.path) {
            try rejectSymlink(backups)
            for directory in try manager.contentsOfDirectory(at: backups, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
                try rejectSymlink(directory)
                try appendBundle(directory.appendingPathComponent(destination.lastPathComponent))
                if destination.lastPathComponent != legacyAppName {
                    try appendBundle(directory.appendingPathComponent(legacyAppName), identifiers: [sourceID, legacySourceID])
                }
            }
        }
        return result
    }
}
