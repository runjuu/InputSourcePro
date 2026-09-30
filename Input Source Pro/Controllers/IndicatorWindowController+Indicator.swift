import AppKit
import Foundation

extension IndicatorWindowController {
    func getAppSize() -> CGSize? {
        return indicatorVC.fittingSize
    }

    func updateIndicator(event: IndicatorVM.ActivateEvent, inputSource: InputSource) {
        let preferences = preferencesVM.preferences

        // Function-key mode badge: not backed by an input source, so render a glyph
        // (SF Symbol or text) + title using the default indicator theme colors
        // (ignoring any per-input-source color override).
        if case let .functionKeyModeChanges(mode) = event {
            indicatorVC.prepare(config: IndicatorViewConfig(
                inputSource: inputSource,
                kind: preferences.indicatorKind,
                size: preferences.indicatorSize ?? .medium,
                bgColor: preferencesVM.defaultIndicatorBgNSColor,
                textColor: preferencesVM.defaultIndicatorTextNSColor,
                prefersTextInputSourceIcons: preferences.prefersTextInputSourceIcons,
                badge: .init(glyph: mode.badgeGlyph, title: mode.displayName)
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
            prefersTextInputSourceIcons: preferences.prefersTextInputSourceIcons
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
