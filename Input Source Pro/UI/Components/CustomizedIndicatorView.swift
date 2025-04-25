import SwiftUI

struct CustomizedIndicatorView: View {
    @EnvironmentObject var preferencesVM: PreferencesVM

    let inputSource: InputSource

    init(inputSource: InputSource) {
        self.inputSource = inputSource
    }

    var body: some View {
        return Group {
            DumpIndicatorView(config: IndicatorViewConfig(
                inputSource: inputSource,
                kind: preferencesVM.preferences.indicatorKind,
                size: preferencesVM.preferences.indicatorSize ?? .medium,
                bgColor: NSColor(preferencesVM.getBgColor(inputSource)),
                textColor: NSColor(preferencesVM.getTextColor(inputSource))
            ))
        }
    }
}
