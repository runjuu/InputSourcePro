import Foundation

extension IndicatorWindowController {
    func getAppSize() -> CGSize? {
        return indicatorVC.fittingSize
    }

    func updateIndicator(event _: IndicatorVM.ActivateEvent, inputSource: InputSource) {
        let preferences = preferencesVM.preferences

        indicatorVC.prepare(config: IndicatorViewConfig(
            inputSource: inputSource,
            kind: preferences.indicatorKind,
            size: preferences.indicatorSize ?? .medium,
            bgColor: preferencesVM.getBgNSColor(inputSource),
            textColor: preferencesVM.getTextNSColor(inputSource)
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
