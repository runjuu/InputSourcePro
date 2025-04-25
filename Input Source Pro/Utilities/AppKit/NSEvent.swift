import AppKit
import Combine

extension NSEvent {
    static func watch(matching: NSEvent.EventTypeMask) -> AnyPublisher<NSEvent, Never> {
        AnyPublisher<NSEvent, Never>
            .create { observer in
                let monitor = self.addGlobalMonitorForEvents(
                    matching: matching,
                    handler: { observer.send($0) }
                )

                return AnyCancellable { NSEvent.removeMonitor(monitor!) }
            }
    }
}
