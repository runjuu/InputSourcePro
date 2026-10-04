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
        worker.enqueue { [worker] in worker.watch(pid: pid, generation: generation) }
    }

    private static func connect(pid: pid_t, changed: @escaping () -> Void) throws -> Connection {
        let application = UIElement(AXUIElementCreateApplication(pid))
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
            let element: UIElement? = try application.attribute(.focusedUIElement)
            return Focus(element: element, state: CaretPalette.TextFocus(role: try element?.role()))
        }, stop: { observer.stop() })
    }

    // AXSwift uses RunLoop.current for both attaching and removing its observer.
    // All connection state stays on this thread; only the mailbox uses the lock.
    private final class Worker {
        private let lock = NSLock()
        private var runLoop: CFRunLoop?
        private var pending: [() -> Void] = []
        private let connect: Connect
        private let onChange: (Update) -> Void
        private var connection: Connection?
        private var focus: Focus?
        private var pid: pid_t?
        private var generation = 0

        init(connect: @escaping Connect, onChange: @escaping (Update) -> Void) {
            self.connect = connect
            self.onChange = onChange
        }

        func enqueue(_ work: @escaping () -> Void) {
            lock.lock()
            if let runLoop = runLoop {
                CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
                CFRunLoopWakeUp(runLoop)
            } else {
                pending.append(work)
            }
            lock.unlock()
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
            connection?.stop()
            connection = nil
            focus = nil
            pid = nil
        }

        func watch(pid: pid_t?, generation: Int) {
            disconnect()
            self.generation = generation
            guard let pid = pid else { return }
            self.pid = pid
            do {
                connection = try connect(pid) { [weak self] in self?.refresh() }
                refresh()
            } catch {
                NSLog("Could not watch cursor focus for %d: %@", pid, String(describing: error))
            }
        }

        private func refresh() {
            guard let pid = pid, let connection = connection else { return }
            do {
                let current = try connection.read()
                guard current != focus else { return }
                focus = current
                onChange(Update(pid: pid, generation: generation, state: current.state,
                                uptime: ProcessInfo.processInfo.systemUptime))
            } catch {
                NSLog("Could not read cursor focus for %d: %@", pid, String(describing: error))
            }
        }
    }
}
