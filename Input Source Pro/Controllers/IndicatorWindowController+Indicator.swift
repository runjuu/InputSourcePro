import AppKit
import Foundation

extension IndicatorWindowController {
    func getAppSize() -> CGSize? {
        return indicatorVC.fittingSize.map { CGSize(width: ceil($0.width), height: ceil($0.height)) }
    }

    func updateIndicator(event: IndicatorVM.ActivateEvent, inputSource: InputSource) {
        let preferences = preferencesVM.preferences
        IndicatorDiagnostics.record("indicator.content event=\(event.diagnosticDescription) source=\(inputSource.persistentIdentifier) kind=\(preferences.indicatorKind) capsLock=\(indicatorVM.isCapsLockOn) showCapsLock=\(preferences.isShowCapsLockStatus) active=\(isActive)")

        if let badge = Self.statusBadge(for: event) {
            indicatorVC.prepare(config: IndicatorViewConfig(
                inputSource: inputSource,
                kind: preferences.indicatorKind,
                size: preferences.indicatorSize ?? .medium,
                bgColor: preferencesVM.defaultIndicatorBgNSColor,
                textColor: preferencesVM.defaultIndicatorTextNSColor,
                badge: badge
            ))

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
    }

    static func statusBadge(for event: IndicatorVM.ActivateEvent) -> IndicatorViewConfig.Badge? {
        guard case let .functionKeyModeChanges(mode) = event else { return nil }
        return .init(glyph: mode.badgeGlyph, title: mode.displayName)
    }

    func moveIndicator(
        position: PreferencesVM.IndicatorPositionInfo,
        displayMode: IndicatorViewController.DisplayMode = .normal
    ) {
        IndicatorDiagnostics.record("indicator.move kind=\(position.kind) point=\(position.point) before=\(String(describing: window?.frame)) fitting=\(String(describing: getAppSize()))")
        indicatorVC.refresh(at: position.point, displayMode: displayMode)
        IndicatorDiagnostics.record("indicator.moved frame=\(String(describing: window?.frame))")
        alwaysOnIndicator.defaultIndicatorFrame = isActive ? window?.frame : nil
    }
}
