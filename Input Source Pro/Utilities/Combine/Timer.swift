import AppKit
import Combine

extension Timer {
    static func delay(
        seconds: TimeInterval,
        tolerance: TimeInterval? = nil,
        options _: RunLoop.SchedulerOptions? = nil
    ) -> AnyPublisher<Date, Never> {
        return Timer.interval(seconds: seconds, tolerance: tolerance)
            .first()
            .eraseToAnyPublisher()
    }

    static func interval(
        seconds: TimeInterval,
        tolerance: TimeInterval? = nil
    ) -> AnyPublisher<Date, Never> {
        return Timer.publish(every: seconds, tolerance: tolerance ?? (seconds * 0.1), on: .main, in: .common)
            .autoconnect()
            .ignoreFailure()
    }
}
