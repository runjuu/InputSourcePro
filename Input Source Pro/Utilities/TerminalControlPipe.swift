import Foundation

/// A named pipe programs in a terminal write `isp:` lines to
/// (`TerminalControlCommand`) to control their pane's input source. A shell
/// builtin (`echo … 1<>…`) writes it in microseconds.
final class TerminalControlPipe {
    private let path: String
    private let source: DispatchSourceRead

    /// Makes the pipe at `~/Library/Application Support/Input Source Pro/terminal-control`,
    /// replacing what was left there (the last run's pipe, or a plain file a
    /// program created while ISP wasn't running), and calls `onReceive` on the
    /// main queue with the complete lines written since the last call. nil, logged,
    /// when the pipe can't be made.
    init?(onReceive: @escaping @MainActor (String) -> Void) {
        guard let directory = try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Input Source Pro", isDirectory: true)
        else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("terminal-control").path

        unlink(path)
        guard mkfifo(path, 0o600) == 0 else {
            NSLog("Terminal control pipe unavailable: mkfifo failed (\(String(cString: strerror(errno)))).")
            return nil
        }
        // Read-write, so the pipe always has a writer: no EOF, and opening never waits for one.
        let fd = open(path, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else {
            NSLog("Terminal control pipe unavailable: open failed (\(String(cString: strerror(errno)))).")
            unlink(path)
            return nil
        }

        self.path = path
        // Drained off the main thread, so a busy main thread doesn't leave writers waiting on a full pipe.
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "dev.inputsourcepro.terminal-control"))
        var framer = TerminalControlFramer()
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var lines = ""
            // Bounded per event; the source fires again while data remains.
            for _ in 0 ..< 16 {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                lines += framer.append(buffer.prefix(count))
            }
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { onReceive(lines) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    /// Closes and removes the pipe.
    func remove() {
        source.cancel()
        unlink(path)
    }
}

/// Splits what is read from the pipe into complete lines, keeping an unfinished
/// one for the next read. A line longer than `maxPending` is dropped up to its
/// newline, so a runaway writer can't grow memory or have its tail run as a command.
struct TerminalControlFramer {
    static let maxPending = 4 * TerminalControlCommand.maxLength

    private var pending: [UInt8] = []
    private var isDiscarding = false

    /// The lines `bytes` completed, each ending in a newline; empty when none.
    mutating func append(_ bytes: some Collection<UInt8>) -> String {
        var lines = ""
        for byte in bytes {
            if byte == UInt8(ascii: "\n") {
                if !isDiscarding {
                    pending.append(byte)
                    lines += String(decoding: pending, as: UTF8.self)
                }
                pending.removeAll(keepingCapacity: true)
                isDiscarding = false
            } else if !isDiscarding {
                pending.append(byte)
                if pending.count > Self.maxPending {
                    pending.removeAll(keepingCapacity: true)
                    isDiscarding = true
                }
            }
        }
        return lines
    }
}

/// A line `isp:<pid>:<command>` a program writes on the pipe to control
/// its pane's input source; `pid` is the program's own. The id after `select:` /
/// `push:` is a TIS id or ISP's persistent identifier, and may contain colons.
/// The pipe is 0600, so any process of the user can write it: `pid` says which
/// pane a line is for, it doesn't prove who wrote it.
struct TerminalControlCommand: Equatable {
    enum Command: Equatable {
        case select(String), push(String), pop, release

        var name: String {
            switch self {
            case .select: return "select"
            case .push: return "push"
            case .pop: return "pop"
            case .release: return "release"
            }
        }
    }

    static let prefix = "isp:"
    static let maxLength = 256

    let pid: pid_t
    let command: Command

    init(pid: pid_t, command: Command) {
        self.pid = pid
        self.command = command
    }

    init?(line: some StringProtocol) {
        guard line.hasPrefix(Self.prefix), line.count <= Self.maxLength else { return nil }
        let parts = line.dropFirst(Self.prefix.count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              let pid = pid_t(parts[0]), pid > 0
        else { return nil }

        let text = String(parts[1])
        switch text {
        case "pop": command = .pop
        case "release": command = .release
        default:
            if text.hasPrefix("select:"), text.count > 7 {
                command = .select(String(text.dropFirst(7)))
            } else if text.hasPrefix("push:"), text.count > 5 {
                command = .push(String(text.dropFirst(5)))
            } else {
                return nil
            }
        }
        self.pid = pid
    }
}
