import Foundation

/// A named pipe programs in a terminal write `isp:` lines to
/// (`TerminalControlCommand`) to control their pane's input source. A shell
/// builtin (`echo … 1<>…`) writes it in microseconds.
final class TerminalControlPipe {
    private let path: String
    private var ownership: (lockFD: Int32, fifo: stat)?
    private let source: DispatchSourceRead

    /// Listens on the per-user pipe and delivers complete lines on the main queue.
    convenience init?(onReceive: @escaping @MainActor (String) async -> Void) {
        guard let directory = try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Input Source Pro", isDirectory: true)
        else { return nil }
        self.init(directory: directory, onReceive: onReceive)
    }

    init?(directory: URL, onReceive: @escaping @MainActor (String) async -> Void) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("Terminal control directory unavailable: %@", error.localizedDescription)
            return nil
        }

        // All instances lock the same inode through startup and removal. Leave the
        // lock file in place so a new process cannot lock a replacement inode.
        let lockPath = directory.appendingPathComponent(".terminal-control.lock").path
        let lockFD = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { return nil }
        var info = stat()
        guard fstat(lockFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD)
            return nil
        }

        let url = directory.appendingPathComponent("terminal-control")
        let fd: Int32
        do {
            (fd, info) = try Self.openFIFO(at: url)
        } catch {
            close(lockFD)
            NSLog("Terminal control pipe unavailable: %@", error.localizedDescription)
            return nil
        }

        path = url.path
        ownership = (lockFD, info)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "dev.inputsourcepro.terminal-control"))
        var framer = TerminalControlFramer()
        source.setEventHandler { [weak self] in
            guard let source = self?.source else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return }
            let lines = framer.append(buffer.prefix(count))
            guard !lines.isEmpty else { return }
            // One delivery in flight. If the main queue falls behind, the
            // kernel FIFO provides backpressure while preserving command order.
            source.suspend()
            Task { @MainActor in
                defer { source.resume() }
                if !source.isCancelled { await onReceive(lines) }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    private static func openFIFO(at url: URL) throws -> (Int32, stat) {
        let path = url.path
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == geteuid() else { throw POSIXError(.EACCES) }
            switch info.st_mode & S_IFMT {
            case S_IFIFO:
                // A previous run may have crashed. Reuse its inode so writers
                // that are already opening it receive a reader.
                break
            case S_IFREG:
                // Shell redirection can create a file while ISP is closed.
                // Preserve its contents even if it came from another source.
                let saved = url.appendingPathExtension(UUID().uuidString)
                try FileManager.default.moveItem(at: url, to: saved)
                NSLog("Preserved existing terminal control file at %@", saved.path)
            default:
                throw POSIXError(.EEXIST)
            }
        } else if errno != ENOENT {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if mkfifo(path, 0o600) != 0 && errno != EEXIST {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let fd = open(path, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFIFO,
              info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & 0o777 == 0o600 else {
            close(fd)
            throw POSIXError(.EACCES)
        }
        return (fd, info)
    }

    func remove() {
        guard let ownership else { return }
        self.ownership = nil
        var current = stat()
        if lstat(path, &current) == 0,
           current.st_dev == ownership.fifo.st_dev, current.st_ino == ownership.fifo.st_ino {
            unlink(path)
        }
        source.cancel()
        close(ownership.lockFD)
    }

    deinit {
        remove()
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
