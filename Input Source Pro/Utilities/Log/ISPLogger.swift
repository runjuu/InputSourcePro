import AppKit
import os

class ISPLogger {
    let category: String

    var disabled: Bool

    init(category: String, disabled: Bool = false) {
        self.category = category
        self.disabled = disabled
    }

    func debug(_ getString: () -> String) {
        if disabled { return }
        // TODO: - Add toggle
        #if DEBUG
            let str = getString()
            let formatter = DateFormatter()
            formatter.dateFormat = "H:mm:ss.SSSS"
            print(formatter.string(from: Date()), "[\(category)]", str)
        #endif
    }
}

/// Geometry and event diagnostics only: never pass editor text, URLs or AX values.
/// File work stays off the UI thread; keep the current and previous 5 MiB segments.
enum IndicatorDiagnostics {
    static let isEnabled: Bool = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        if let value = ProcessInfo.processInfo.environment["ISP_INDICATOR_DIAGNOSTICS"] {
            return value == "1"
        }
        if let value = UserDefaults.standard.object(forKey: "IndicatorDiagnosticsEnabled") as? Bool {
            return value
        }
        #if DEBUG
            return true
        #else
            return false
        #endif
    }()

    private static let writer = Writer()

    static func record(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let thread = Thread.isMainThread ? "main" : "background"
        let line = String(format: "%.6f", uptime) + " [\(thread)] " + message()
        writer.enqueue(line)
    }

    private final class Writer: @unchecked Sendable {
        private let queue = DispatchQueue(label: "dev.inputsourcepro.indicator-diagnostics", qos: .utility)
        private var handle: FileHandle?
        private var byteCount: UInt64 = 0
        private var failed = false
        private let limit: UInt64 = 5 * 1024 * 1024
        private let session = UUID().uuidString
        private let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Input Source Pro", isDirectory: true)

        func enqueue(_ line: String) {
            queue.async { [self] in
                guard !failed else { return }
                do {
                    if handle == nil { try open() }
                    if byteCount >= limit {
                        try handle?.close()
                        handle = nil
                        let previous = directory.appendingPathComponent("indicator-previous.log")
                        if FileManager.default.fileExists(atPath: previous.path) {
                            try FileManager.default.removeItem(at: previous)
                        }
                        try FileManager.default.moveItem(
                            at: directory.appendingPathComponent("indicator.log"), to: previous
                        )
                        try open()
                    }
                    try write(line + "\n")
                } catch {
                    failed = true
                    NSLog("Indicator diagnostics could not write log: %@", error.localizedDescription)
                }
            }
        }

        private func open() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("indicator.log")
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            handle = try FileHandle(forWritingTo: url)
            byteCount = try handle!.seekToEnd()
            try write("SESSION \(session) date=\(ISO8601DateFormatter().string(from: Date())) pid=\(ProcessInfo.processInfo.processIdentifier) version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") build=\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?") os=\(ProcessInfo.processInfo.operatingSystemVersionString) uptime=\(ProcessInfo.processInfo.systemUptime)\n")
        }

        private func write(_ line: String) throws {
            let data = Data(line.utf8)
            try handle?.write(contentsOf: data)
            byteCount += UInt64(data.count)
        }
    }
}
