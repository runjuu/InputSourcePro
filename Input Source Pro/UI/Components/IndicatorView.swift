import SwiftUI

struct IndicatorView: NSViewControllerRepresentable {
    @EnvironmentObject var preferencesVM: PreferencesVM
    @EnvironmentObject var indicatorVM: IndicatorVM
    @EnvironmentObject var inputSourceVM: InputSourceVM

    func makeNSViewController(context _: Context) -> IndicatorViewController {
        return IndicatorViewController(layout: .preview)
    }

    func updateNSViewController(_ indicatorViewController: IndicatorViewController, context _: Context) {
        indicatorViewController.prepare(config: IndicatorViewConfig(
            inputSource: indicatorVM.state.inputSource,
            kind: preferencesVM.preferences.indicatorKind,
            size: preferencesVM.preferences.indicatorSize ?? .medium,
            bgColor: NSColor(preferencesVM.preferences.indicatorBackgroundColor),
            textColor: NSColor(preferencesVM.preferences.indicatorForgegroundColor),
            showsCapsLock: preferencesVM.preferences.isShowCapsLockStatus && indicatorVM.isCapsLockOn
        ))

        indicatorViewController.refresh()
    }
}

struct DumpIndicatorView: NSViewControllerRepresentable {
    let config: IndicatorViewConfig

    init(config: IndicatorViewConfig) {
        self.config = config
    }

    func makeNSViewController(context _: Context) -> IndicatorViewController {
        return IndicatorViewController(layout: .preview)
    }

    func updateNSViewController(_ indicatorViewController: IndicatorViewController, context _: Context) {
        indicatorViewController.prepare(config: config)
        indicatorViewController.refresh()
    }
}
