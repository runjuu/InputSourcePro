import Foundation
import Security
import Darwin

struct CaretActivity: Codable, Equatable {
    let pid: Int32
    let uptime: TimeInterval
    let focusID: String
    let permitsTracking: Bool
    let isInputEvent: Bool

    func permitsQuery(pid: Int32, now: TimeInterval, secureInput: Bool) -> Bool {
        permitsTracking && !secureInput && self.pid == pid && uptime.isFinite
            && now >= uptime && now - uptime < 0.75
    }
}

struct CaretPosition: Codable, Equatable {
    let session: String
    let pid: Int32
    let uptime: TimeInterval
    let rect: String
    let pending: Bool
    let focusID: String
}

enum CaretMessage: Codable, Equatable {
    case ready
    case activity(CaretActivity)
    case position(CaretPosition)
}

/// A same-user socket with mutually authenticated code identities. No discovery or data broadcasts.
final class CaretChannel {
    enum Role {
        case application, helper

        var peerRequirement: String {
            let identifier = self == .application
                ? "com.runjuu.Input-Source-Pro.inputmethod.PaletteControl"
                : "com.runjuu.Input-Source-Pro"
            return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"468WY4C4MA\""
        }

        func accepts(_ message: CaretMessage) -> Bool {
            switch (self, message) {
            case (.application, .ready), (.application, .position), (.helper, .activity): return true
            default: return false
            }
        }
    }

    enum Failure: Error { case invalidRequirement, invalidDirectory, alreadyRunning, socket(Int32), invalidFrame }

    struct Decoder {
        static let maximumSize = 4096
        private var buffer = Data()

        mutating func append(_ bytes: Data) throws -> [CaretMessage] {
            buffer.append(bytes)
            var messages: [CaretMessage] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard length > 0, length <= Self.maximumSize else { throw Failure.invalidFrame }
                guard buffer.count >= length + 4 else { break }
                messages.append(try JSONDecoder().decode(CaretMessage.self, from: buffer.subdata(in: 4..<(length + 4))))
                buffer.removeFirst(length + 4)
                // Keep Data's indices zero-based after removing a prefix.
                buffer = Data(buffer)
            }
            return messages
        }

        static func frame(_ message: CaretMessage) throws -> Data {
            let payload = try JSONEncoder().encode(message)
            guard payload.count <= maximumSize else { throw Failure.invalidFrame }
            var length = UInt32(payload.count).bigEndian
            return withUnsafeBytes(of: &length) { Data($0) } + payload
        }
    }

    static let socketURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("isp-caret", isDirectory: true).appendingPathComponent("channel")

    private let role: Role
    private let socketURL: URL
    private let requirement: SecRequirement
    private let onMessage: (CaretMessage) -> Void
    private let onConnectionChange: (Bool) -> Void
    private let queue = DispatchQueue(label: "com.runjuu.Input-Source-Pro.caret-channel")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var listener: DispatchSourceRead?
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var reconnect: DispatchSourceTimer?
    private var lockFD: Int32 = -1
    private var peerFD: Int32 = -1
    private var decoder = Decoder()
    private var outgoing = Data()
    private var running = false

    init(role: Role, socketURL: URL = CaretChannel.socketURL, requirement: String? = nil,
         onMessage: @escaping (CaretMessage) -> Void, onConnectionChange: @escaping (Bool) -> Void) throws {
        self.role = role
        self.socketURL = socketURL
        self.onMessage = onMessage
        self.onConnectionChange = onConnectionChange
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString((requirement ?? role.peerRequirement) as CFString, [], &parsed) == errSecSuccess,
              let parsed = parsed else { throw Failure.invalidRequirement }
        self.requirement = parsed
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    func start() throws {
        try queue.sync {
            guard !running else { return }
            if role == .application { try listen() }
            running = true
            if role == .helper {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: 1)
                timer.setEventHandler { [weak self] in self?.connect() }
                reconnect = timer
                timer.resume()
            }
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            stopOnQueue()
        } else {
            queue.sync { stopOnQueue() }
        }
    }

    private func stopOnQueue() {
        running = false
        reconnect?.cancel()
        reconnect = nil
        disconnect()
        listener?.cancel()
        listener = nil
        if lockFD >= 0 {
            unlink(socketURL.path)
            close(lockFD)
            lockFD = -1
        }
    }

    func send(_ message: CaretMessage) {
        queue.async { [weak self] in
            guard let self = self, self.running, self.peerFD >= 0 else { return }
            do {
                let frame = try Decoder.frame(message)
                guard self.outgoing.count + frame.count <= 32768 else { self.disconnect(); return }
                self.outgoing.append(frame)
                self.flush()
            } catch {
                self.disconnect()
            }
        }
    }

    static func authenticate(_ socket: Int32, requirement: SecRequirement) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(socket, &uid, &gid) == 0, uid == geteuid() else { return false }
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout.size(ofValue: token))
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
              size == MemoryLayout.size(ofValue: token) else { return false }
        let audit = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        // The kernel's audit token binds verification to this peer, avoiding PID reuse races.
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: audit] as CFDictionary, [], &code) == errSecSuccess,
              let code = code else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    private func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }
        var enabled: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            let error = errno
            close(fd)
            throw Failure.socket(error)
        }
        return fd
    }

    private func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketURL.path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.invalidDirectory }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let length = socklen_t(address.sun_len)
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) }
        }
    }

    private func listen() throws {
        let directory = socketURL.deletingLastPathComponent().path
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw Failure.socket(errno) }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else { throw Failure.invalidDirectory }
        let fd = open(directory + "/lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.socket(errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw Failure.alreadyRunning }
        lockFD = fd
        do {
            let socket = try makeSocket()
            do {
                unlink(socketURL.path)
                guard try withAddress({ Darwin.bind(socket, $0, $1) }) == 0,
                      chmod(socketURL.path, 0o600) == 0,
                      Darwin.listen(socket, 4) == 0 else { throw Failure.socket(errno) }
            } catch { close(socket); throw error }
            let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
            source.setEventHandler { [weak self] in self?.accept(socket) }
            source.setCancelHandler { close(socket) }
            listener = source
            source.resume()
        } catch {
            unlink(socketURL.path)
            close(lockFD)
            lockFD = -1
            throw error
        }
    }

    private func connect() {
        guard running, peerFD < 0 else { return }
        do {
            let fd = try makeSocket()
            do {
                guard try withAddress({ Darwin.connect(fd, $0, $1) }) == 0 else { close(fd); return }
            } catch { close(fd); throw error }
            attach(fd)
        } catch {
            NSLog("Cursor helper connection failed: %@", String(describing: error))
        }
    }

    private func accept(_ socket: Int32) {
        let fd = Darwin.accept(socket, nil, nil)
        guard fd >= 0 else { return }
        guard running, peerFD < 0 else { close(fd); return }
        attach(fd)
    }

    private func attach(_ fd: Int32) {
        var enabled: Int32 = 1
        guard Self.authenticate(fd, requirement: requirement),
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            close(fd)
            return
        }
        peerFD = fd
        decoder = Decoder()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.read(fd) }
        source.setCancelHandler { close(fd) }
        reader = source
        source.resume()
        DispatchQueue.main.async { [onConnectionChange] in onConnectionChange(true) }
    }

    private func read(_ fd: Int32) {
        guard peerFD == fd else { return }
        var bytes = [UInt8](repeating: 0, count: Decoder.maximumSize)
        let count = recv(fd, &bytes, bytes.count, 0)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard count > 0 else { disconnect(); return }
        do {
            for message in try decoder.append(Data(bytes.prefix(count))) {
                guard role.accepts(message) else { disconnect(); return }
                DispatchQueue.main.async { [onMessage] in onMessage(message) }
            }
        } catch { disconnect() }
    }

    private func flush() {
        guard peerFD >= 0 else { return }
        while !outgoing.isEmpty {
            let count = outgoing.withUnsafeBytes { Darwin.send(peerFD, $0.baseAddress, $0.count, 0) }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN {
                if writer == nil {
                    let writeFD = dup(peerFD)
                    guard writeFD >= 0 else { disconnect(); return }
                    guard fcntl(writeFD, F_SETFD, FD_CLOEXEC) == 0 else {
                        close(writeFD)
                        disconnect()
                        return
                    }
                    let source = DispatchSource.makeWriteSource(fileDescriptor: writeFD, queue: queue)
                    source.setCancelHandler { close(writeFD) }
                    source.setEventHandler { [weak self] in self?.flush() }
                    writer = source
                    source.resume()
                }
                return
            }
            guard count > 0 else { disconnect(); return }
            outgoing.removeFirst(count)
        }
        writer?.cancel()
        writer = nil
    }

    private func disconnect() {
        guard peerFD >= 0 else { return }
        shutdown(peerFD, SHUT_RDWR)
        writer?.cancel()
        writer = nil
        reader?.cancel()
        reader = nil
        peerFD = -1
        outgoing.removeAll()
        decoder = Decoder()
        DispatchQueue.main.async { [onConnectionChange] in onConnectionChange(false) }
    }
}
