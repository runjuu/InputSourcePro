import AppKit
import Foundation

extension IndicatorWindowController {
    func getAppSize() -> CGSize? {
        return indicatorVC.fittingSize
    }

    func updateIndicator(event: IndicatorVM.ActivateEvent, inputSource: InputSource) {
        let preferences = preferencesVM.preferences

        let badge: IndicatorViewConfig.Badge?
        switch event {
        case let .functionKeyModeChanges(mode):
            badge = .init(glyph: mode.badgeGlyph, title: mode.displayName)
        case let .capsLockChanges(isOn) where preferences.isShowCapsLockStatus:
            badge = .capsLock(isOn: isOn)
        default:
            badge = nil
        }

        if let badge {
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

    func moveIndicator(position: PreferencesVM.IndicatorPositionInfo) {
        indicatorVC.refresh()
        moveTo(point: position.point)
    }
}
