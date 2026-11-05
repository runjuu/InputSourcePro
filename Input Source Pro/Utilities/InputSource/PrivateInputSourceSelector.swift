import Carbon
import Foundation

// Private HIToolbox protocol adapted from harukawu/MacIMEKit, commit 77b37a8.
// https://github.com/harukawu/MacIMEKit
//
// Copyright (c) 2026 Haruka. MIT license: Resources/MacIMEKit-LICENSE.txt

enum PrivateInputSourceSelector {
    enum Failure: Error, Equatable {
        case unavailable, noFocus, focusChanged, invalidSource, serialization
        case noPort, invalidReply, cancelled, timedOut
        case transport(Int32)
        case rejected(Int32)
    }

    // Only the immutable serialized payload crosses threads; Carbon source
    // lookup and flattening stay on the main thread. Cancellation is locked.
    final class Request: @unchecked Sendable {
        let pid: pid_t
        let data: Data
        let deadline: TimeInterval
        private let lock = NSLock()
        private var cancelled = false

        init(pid: pid_t, data: Data, deadline: TimeInterval) {
            self.pid = pid
            self.data = data
            self.deadline = deadline
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func perform<Port>(
            focusPID: () -> pid_t?,
            now: () -> TimeInterval,
            connect: (pid_t) -> Result<Port, Failure>,
            send: (Port, Data, TimeInterval) -> Result<Void, Failure>
        ) -> Result<Void, Failure> {
            if let error = validationFailure(focusPID: focusPID, now: now) { return .failure(error) }
            let connection = connect(pid)
            // Port lookup can block. Revalidate before sending anything and
            // charge lookup time to the same absolute request deadline.
            if let error = validationFailure(focusPID: focusPID, now: now) { return .failure(error) }
            let port: Port
            switch connection {
            case let .success(value): port = value
            case let .failure(error): return .failure(error)
            }
            let remaining = deadline - now()
            guard remaining > 0 else { return .failure(.timedOut) }
            let result = send(port, data, remaining)
            // An IPC already sent cannot be recalled. Never retry it in another
            // app or run follow-up work after cancellation or a focus change.
            if let error = validationFailure(focusPID: focusPID, now: now) { return .failure(error) }
            return result
        }

        func validationFailure(focusPID: () -> pid_t?, now: () -> TimeInterval) -> Failure? {
            if isCancelled { return .cancelled }
            if focusPID() != pid { return .focusChanged }
            if now() >= deadline { return .timedOut }
            return nil
        }
    }

    private typealias GetKeyFocusProcess = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
    ) -> Int32
    private typealias CreatePerProcessRemote = @convention(c) (
        CFAllocator?, CFString, pid_t
    ) -> Unmanaged<CFMessagePort>?
    private typealias CreateFlattenedInputSource = @convention(c) (
        TISInputSource, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>
    ) -> UInt8
    private typealias GetPID = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<pid_t>) -> OSStatus

    private struct API {
        let getKeyFocusProcess: GetKeyFocusProcess
        let createPerProcessRemote: CreatePerProcessRemote
        let createFlattenedInputSource: CreateFlattenedInputSource
        let getPID: GetPID

        init?() {
            let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
            guard let focus = dlsym(handle, "CPSGetKeyFocusProcess"),
                  let port = dlsym(handle, "CFMessagePortCreatePerProcessRemote"),
                  let flatten = dlsym(handle, "_CreateFlattenedInputSource"),
                  let getPID = dlsym(handle, "GetProcessPID")
            else { return nil }
            getKeyFocusProcess = unsafeBitCast(focus, to: GetKeyFocusProcess.self)
            createPerProcessRemote = unsafeBitCast(port, to: CreatePerProcessRemote.self)
            createFlattenedInputSource = unsafeBitCast(flatten, to: CreateFlattenedInputSource.self)
            self.getPID = unsafeBitCast(getPID, to: GetPID.self)
        }
    }

    private static let api = API()
    private static let queue = DispatchQueue(label: "dev.inputsourcepro.direct-activation", qos: .userInitiated)

    static func keyFocusPID() -> pid_t? {
        guard let api else { return nil }
        var process = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kNoProcess))
        var ignored: UInt8 = 0
        var pid: pid_t = 0
        guard api.getKeyFocusProcess(&process, &ignored) == 0,
              api.getPID(&process, &pid) == noErr, pid > 0
        else { return nil }
        return pid
    }

    @MainActor
    static func prepare(_ source: TISInputSource, expectedPID: pid_t?) -> Result<Request, Failure> {
        guard let api else { return .failure(.unavailable) }
        guard source.category == TISInputSource.Category.keyboardInputSource,
              source.isEnabled, source.isSelectable
        else { return .failure(.invalidSource) }
        guard let pid = keyFocusPID() else { return .failure(.noFocus) }
        guard expectedPID == nil || expectedPID == pid else { return .failure(.focusChanged) }

        var flattened: Unmanaged<CFTypeRef>?
        let didFlatten = api.createFlattenedInputSource(source, &flattened)
        let value = flattened?.takeRetainedValue()
        guard didFlatten != 0, let value else { return .failure(.serialization) }
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["tsmInputSourceSelectedInpSrcKey": value], format: .xml, options: 0
            )
            return .success(Request(pid: pid, data: data, deadline: ProcessInfo.processInfo.systemUptime + 0.3))
        } catch {
            return .failure(.serialization)
        }
    }

    static func select(_ request: Request, completion: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        queue.async {
            let result = request.perform(
                focusPID: keyFocusPID,
                now: { ProcessInfo.processInfo.systemUptime },
                connect: connect,
                send: send
            )
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func connect(_ pid: pid_t) -> Result<CFMessagePort, Failure> {
        guard let api else { return .failure(.unavailable) }
        guard let port = api.createPerProcessRemote(nil, "com.apple.tsm.portname" as CFString, pid)?.takeRetainedValue()
        else { return .failure(.noPort) }
        return .success(port)
    }

    private static func send(_ port: CFMessagePort, data: Data, timeout: TimeInterval) -> Result<Void, Failure> {
        var reply: Unmanaged<CFData>?
        let sendTimeout = min(0.05, timeout / 2)
        let status = CFMessagePortSendRequest(
            port, 7, data as CFData, sendTimeout, timeout - sendTimeout,
            CFRunLoopMode.defaultMode.rawValue, &reply
        )
        let replyData = reply?.takeRetainedValue()
        guard status == kCFMessagePortSuccess else { return .failure(.transport(status)) }
        return parseReply(replyData as Data?)
    }

    static func parseReply(_ data: Data?) -> Result<Void, Failure> {
        guard let data,
              let dictionary = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let number = dictionary["tsmInputModeReplyToServerErrorKey"] as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              NSNumber(value: number.int32Value) == number
        else { return .failure(.invalidReply) }
        return number.int32Value == noErr ? .success(()) : .failure(.rejected(number.int32Value))
    }
}
