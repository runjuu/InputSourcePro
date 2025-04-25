import AppKit
import Combine

extension Timer {
    static func delay(
        seconds: TimeInterval,
        tolerance _: TimeInterval? = nil,
        options _: RunLoop.SchedulerOptions? = nil
    ) -> AnyPublisher<Date, Never> {
        return Timer.interval(seconds: seconds)
            .first()
            .eraseToAnyPublisher()
    }

    static func interval(
        seconds: TimeInterval
    ) -> AnyPublisher<Date, Never> {
        return Timer.publish(every: seconds, on: .main, in: .common)
            .autoconnect()
            .ignoreFailure()
    }
}
