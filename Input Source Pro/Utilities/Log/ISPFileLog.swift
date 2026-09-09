import AppKit
import Foundation
import os.log

enum ISPFileLog {
    private static let queue = DispatchQueue(label: "pro.inputsource.filelog")
    private static let osLog = Logger(subsystem: "pro.inputsource.InputSourcePro", category: "FileLog")
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/InputSourcePro", isDirectory: true)
    }

    static var fileURL: URL {
        directoryURL.appendingPathComponent("isp.log", isDirectory: false)
    }

    @MainActor
    static func startSession() {
        ensureDirectory()
        let marker = String(repeating: "-", count: 72)
        writeRaw("\n\(marker)\n\(iso.string(from: Date())) ISP SESSION START pid=\(ProcessInfo.processInfo.processIdentifier)\n\(marker)\n")
        event("boot", "session start")
    }

    @MainActor
    static func event(_ kind: String, _ message: String, includeSnapshot: Bool = true) {
        let stamp = iso.string(from: Date())
        var line = "\(stamp) [\(kind)] \(message)"
        if includeSnapshot {
            line += " | \(snapshot())"
        }
        writeRaw(line + "\n")
        osLog.info("\(kind, privacy: .public): \(message, privacy: .public)")
        #if DEBUG
            print(stamp, "[\(kind)]", message)
        #endif
    }

    @MainActor
    static func snapshot() -> String {
        let front = NSWorkspace.shared.frontmostApplication
        let layout = InputSource.getCurrentInputSource()
        let launchpad = LaunchpadOverlayDetector.isLaunchpadVisible()
        let ws = "\(front?.localizedName ?? "?")[\(front?.bundleIdentifier ?? "nil")#\(front?.processIdentifier ?? 0)] pol=\(front?.activationPolicy.rawValue ?? -1)"
        let lay = "\(layout.name)[\(layout.persistentIdentifier)]"
        return "ws=\(ws) launchpad=\(launchpad) layout=\(lay)"
    }

    static func openInFinder() {
        ensureDirectory()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            writeRaw("")
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private static func writeRaw(_ text: String) {
        queue.async {
            ensureDirectory()
            let path = fileURL.path
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let data = text.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }
}
