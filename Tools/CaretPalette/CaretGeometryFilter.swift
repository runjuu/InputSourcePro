import Foundation
import CoreGraphics

struct CaretGeometryFilter {
    private var accepted: CGRect?
    private var pending: (rect: CGRect, since: TimeInterval, observedAt: TimeInterval)?

    mutating func accept(
        _ rect: CGRect, at now: TimeInterval,
        confirmEveryChange: Bool = false, activityAt: TimeInterval = 0
    ) -> CGRect? {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width >= 0, rect.width <= 10, rect.height > 0, rect.height <= 200
        else {
            // Let the receiver hide invalid geometry rather than retaining an old caret.
            self = Self()
            return rect
        }
        var needsConfirmation = confirmEveryChange && rect != accepted
        if let accepted = accepted {
            let lineHeight = max(accepted.height, rect.height)
            let isLargeJump = abs(rect.minX - accepted.minX) > lineHeight * 2 ||
                abs(rect.minY - accepted.minY) > lineHeight * 0.5
            needsConfirmation = needsConfirmation || isLargeJump
        }
        if needsConfirmation {
            if let pending = pending {
                let elapsed = now - pending.since
                if confirmEveryChange && pending.observedAt < activityAt {
                    // Samples separated by new input cannot confirm each other.
                    self.pending = (rect, now, now)
                    return nil
                }
                let isConfirmed = pending.rect == rect && now - pending.observedAt >= CaretPollingSchedule.activeInterval
                // Codex must never publish an unconfirmed position just because time elapsed.
                let allowsUnconfirmedMovement = !confirmEveryChange && elapsed >= 0.05
                if !isConfirmed && !allowsUnconfirmedMovement {
                    self.pending = (rect, pending.since, pending.rect == rect ? pending.observedAt : now)
                    return nil
                }
            } else {
                pending = (rect, now, now)
                return nil
            }
        }
        pending = nil
        accepted = rect
        return rect
    }
}
