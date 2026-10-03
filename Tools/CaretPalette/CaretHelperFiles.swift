import Foundation

enum CaretHelperFiles {
    static let sourceID = "dev.inputsourcepro.inputmethod.PaletteControl"
    static let legacyHelpers = [
        (name: "ISP Caret Control.app", identifier: "dev.inputsourcepro.inputmethod.CaretControl"),
        (name: "InputSourcePro Caret Probe 20261003.app", identifier: "dev.inputsourcepro.CaretPaletteProbe"),
    ]

    static func hasLegacyHelpers(beside destination: URL) -> Bool {
        legacyHelpers.contains {
            FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().appendingPathComponent($0.name).path)
        }
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
        func appendBundle(_ url: URL, identifier: String = sourceID) throws {
            guard manager.fileExists(atPath: url.path) else { return }
            try rejectSymlink(url)
            let plist = url.appendingPathComponent("Contents/Info.plist")
            let data = try Data(contentsOf: plist)
            let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            guard info?["CFBundleIdentifier"] as? String == identifier else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
            result.append(url)
        }
        try appendBundle(destination)
        for helper in legacyHelpers {
            try appendBundle(destination.deletingLastPathComponent().appendingPathComponent(helper.name), identifier: helper.identifier)
        }
        if manager.fileExists(atPath: backups.path) {
            try rejectSymlink(backups)
            for directory in try manager.contentsOfDirectory(at: backups, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                guard UUID(uuidString: directory.lastPathComponent) != nil || directory.lastPathComponent == "initial-installer-check" else { continue }
                try rejectSymlink(directory)
                try appendBundle(directory.appendingPathComponent(destination.lastPathComponent))
            }
        }
        return result
    }
}
