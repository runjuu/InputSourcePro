import AppKit
import AXSwift

final class CaretFocusObserver {
    struct Focus: Equatable {
        let element: UIElement?
        let state: CaretPalette.TextFocus
    }

    struct Update {
        let pid: pid_t
        let generation: Int
        let state: CaretPalette.TextFocus
        let uptime: TimeInterval

        func isCurrent(generation: Int, pid: pid_t?, since uptime: TimeInterval) -> Bool {
            self.generation == generation && self.pid == pid && self.uptime >= uptime
        }
    }

    struct Connection {
        let read: () throws -> Focus
        let stop: () -> Void
    }

    typealias Connect = (pid_t, @escaping () -> Void) throws -> Connection

    private let worker: Worker

    init(connect: @escaping Connect = CaretFocusObserver.connect,
         onChange: @escaping (Update) -> Void) {
        let worker = Worker(connect: connect, onChange: onChange)
        self.worker = worker
        let thread = Thread { worker.run() }
        thread.name = "Input Source Pro cursor accessibility"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit {
        worker.enqueue { [worker] in
            worker.disconnect()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    func watch(pid: pid_t?, generation: Int) {
        worker.requestWatch(pid: pid, generation: generation)
    }

    private static func connect(pid: pid_t, changed: @escaping () -> Void) throws -> Connection {
        let application = UIElement(AXUIElementCreateApplication(pid))
        application.messagingTimeout = 0.25
        let observer = try AXSwift.Observer(processID: pid) { _, _, _ in changed() }
        for notification: AXNotification in [.focusedUIElementChanged, .focusedWindowChanged] {
            do {
                try observer.addNotification(notification, forElement: application)
            } catch AXError.notificationUnsupported {
                // Some editors expose only one of these notifications.
                continue
            }
        }
        return Connection(read: {
            let element: UIElement?
            do {
                element = try application.attribute(.focusedUIElement)
            } catch AXError.attributeUnsupported {
                return Focus(element: nil, state: .unknown)
            } catch AXError.noValue {
                return Focus(element: nil, state: .unknown)
            }
            // Timeouts belong to individual AX objects, including the returned field.
            element?.messagingTimeout = 0.25
            let role: Role?
            do {
                role = try element?.role()
            } catch AXError.attributeUnsupported {
                role = nil
            } catch AXError.noValue {
                role = nil
            }
            let subrole: String?
            do { subrole = try element?.attribute(.subrole) }
            catch AXError.attributeUnsupported { subrole = nil }
            catch AXError.noValue { subrole = nil }
            return Focus(element: element, state: CaretPalette.TextFocus(role: role, subrole: subrole))
        }, stop: { observer.stop() })
    }

    // AXSwift uses RunLoop.current for both attaching and removing its observer.
    // All connection state stays on this thread; only the mailbox uses the lock.
    private final class Worker {
        private struct Request: Equatable {
            let pid: pid_t?
            let generation: Int
        }

        private let lock = NSLock()
        private var runLoop: CFRunLoop?
        private var pending: [() -> Void] = []
        private var requested = Request(pid: nil, generation: 0)
        private var watchScheduled = false
        private let connect: Connect
        private let onChange: (Update) -> Void
        private var connection: Connection?
        private var focus: Focus?
        private var active: Request?
        private var scheduledRefresh: Request?
        private var retryTimer: Timer?
        private var retryDelay: TimeInterval = 0.25

        init(connect: @escaping Connect, onChange: @escaping (Update) -> Void) {
            self.connect = connect
            self.onChange = onChange
        }

        func enqueue(_ work: @escaping () -> Void) {
            lock.lock()
            scheduleLocked(work)
            lock.unlock()
        }

        private func scheduleLocked(_ work: @escaping () -> Void) {
            if let runLoop = runLoop {
                CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
                CFRunLoopWakeUp(runLoop)
            } else {
                pending.append(work)
            }
        }

        func requestWatch(pid: pid_t?, generation: Int) {
            lock.lock()
            requested = Request(pid: pid, generation: generation)
            if !watchScheduled {
                watchScheduled = true
                scheduleLocked { [self] in watchLatest() }
            }
            lock.unlock()
        }

        private func isCurrent(_ request: Request) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return requested == request
        }

        func run() {
            let loop = CFRunLoopGetCurrent()
            var context = CFRunLoopSourceContext()
            context.perform = { _ in }
            let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)
            CFRunLoopAddSource(loop, keepAlive, .defaultMode)
            lock.lock()
            runLoop = loop
            for work in pending {
                CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, work)
            }
            pending.removeAll()
            lock.unlock()
            CFRunLoopRun()
            CFRunLoopRemoveSource(loop, keepAlive, .defaultMode)
        }

        func disconnect() {
            cancelRetry()
            connection?.stop()
            connection = nil
            focus = nil
            active = nil
            scheduledRefresh = nil
        }

        private func watchLatest() {
            lock.lock()
            let request = requested
            watchScheduled = false
            lock.unlock()
            disconnect()
            guard request.pid != nil, isCurrent(request) else { return }
            active = request
            connect(for: request)
        }

        private func connect(for request: Request) {
            guard isCurrent(request), active == request, let pid = request.pid else { return }
            do {
                connection = try connect(pid) { [weak self] in self?.scheduleRefresh(for: request) }
                guard isCurrent(request) else { disconnect(); return }
                refresh(for: request)
            } catch {
                if focus?.state != .unavailable {
                    NSLog("Could not watch cursor focus for %d: %@", pid, String(describing: error))
                }
                publishUnavailable(for: request)
                scheduleRetry(for: request)
            }
        }

        private func cancelRetry() {
            retryTimer?.invalidate()
            retryTimer = nil
            retryDelay = 0.25
        }

        private func scheduleRetry(for request: Request) {
            guard isCurrent(request), active == request, retryTimer == nil else { return }
            // A failed observer connection cannot send a notification to recover itself.
            // Retry on the AX worker, backing off while the foreground app is unavailable.
            let timer = Timer(timeInterval: retryDelay, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.retryTimer = nil
                guard self.isCurrent(request), self.active == request else { return }
                if self.connection == nil {
                    self.connect(for: request)
                } else {
                    self.refresh(for: request)
                }
            }
            retryDelay = min(retryDelay * 2, 2)
            retryTimer = timer
            RunLoop.current.add(timer, forMode: .default)
        }

        private func scheduleRefresh(for request: Request) {
            guard isCurrent(request), active == request, scheduledRefresh != request else { return }
            scheduledRefresh = request
            enqueue { [weak self] in
                guard let self = self, self.scheduledRefresh == request else { return }
                self.scheduledRefresh = nil
                self.refresh(for: request)
            }
        }

        private func refresh(for request: Request) {
            guard isCurrent(request), active == request,
                  let pid = request.pid, let connection = connection else { return }
            let startedAt = ProcessInfo.processInfo.systemUptime
            do {
                let current = try connection.read()
                guard isCurrent(request) else { return }
                cancelRetry()
                guard current != focus else { return }
                focus = current
                onChange(Update(pid: pid, generation: request.generation, state: current.state,
                                uptime: startedAt))
            } catch {
                if focus?.state != .unavailable {
                    NSLog("Could not read cursor focus for %d: %@", pid, String(describing: error))
                }
                publishUnavailable(for: request)
                scheduleRetry(for: request)
            }
        }

        private func publishUnavailable(for request: Request) {
            guard isCurrent(request), let pid = request.pid, focus?.state != .unavailable else { return }
            focus = Focus(element: nil, state: .unavailable)
            onChange(Update(pid: pid, generation: request.generation, state: .unavailable,
                            uptime: ProcessInfo.processInfo.systemUptime))
        }
    }
}
