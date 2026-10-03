import AppKit
import Foundation

extension IndicatorWindowController {
    func getAppSize() -> CGSize? {
        return indicatorVC.fittingSize
    }

    func updateIndicator(event: IndicatorVM.ActivateEvent, inputSource: InputSource) {
        let preferences = preferencesVM.preferences

        if let badge = Self.statusBadge(for: event) {
            indicatorVC.prepare(config: IndicatorViewConfig(
                inputSource: inputSource,
                kind: preferences.indicatorKind,
                size: preferences.indicatorSize ?? .medium,
                bgColor: preferencesVM.defaultIndicatorBgNSColor,
                textColor: preferencesVM.defaultIndicatorTextNSColor,
                badge: badge
            ))

            if isActive {
                indicatorVC.refresh()
            }

            return
        }

        indicatorVC.prepare(config: IndicatorViewConfig(
            inputSource: inputSource,
            kind: preferences.indicatorKind,
            size: preferences.indicatorSize ?? .medium,
            bgColor: preferencesVM.getBgNSColor(inputSource),
            textColor: preferencesVM.getTextNSColor(inputSource),
            showsCapsLock: preferences.isShowCapsLockStatus && indicatorVM.isCapsLockOn
        ))

        if isActive {
            indicatorVC.refresh()
        }
    }

    static func statusBadge(for event: IndicatorVM.ActivateEvent) -> IndicatorViewConfig.Badge? {
        guard case let .functionKeyModeChanges(mode) = event else { return nil }
        return .init(glyph: mode.badgeGlyph, title: mode.displayName)
    }

    func moveIndicator(position: PreferencesVM.IndicatorPositionInfo) {
        indicatorVC.refresh()
        moveTo(point: position.point)
        alwaysOnIndicator.defaultIndicatorFrame = isActive ? window?.frame : nil
    }
}
