import Foundation

struct CaretPollingSchedule {
    static let activeInterval: TimeInterval = 1.0 / 60.0
    static let idleInterval: TimeInterval = 0.25
    private var activeUntil: TimeInterval = 0

    mutating func noteActivity(at now: TimeInterval) {
        activeUntil = now + 0.35
    }

    func interval(at now: TimeInterval) -> TimeInterval {
        now < activeUntil ? Self.activeInterval : Self.idleInterval
    }
}
