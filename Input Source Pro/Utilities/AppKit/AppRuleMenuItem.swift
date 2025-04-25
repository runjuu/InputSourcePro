import AppKit

@MainActor
class AppRuleMenuItem: NSMenuItem {
    let app: NSRunningApplication
    let preferencesVM: PreferencesVM
    let inputSource: InputSource?

    var cancelBag = CancelBag()

    var appCustomization: AppRule? {
        preferencesVM.getAppCustomization(app: app)
    }

    init(app: NSRunningApplication, preferencesVM: PreferencesVM, inputSource: InputSource?) {
        self.app = app
        self.preferencesVM = preferencesVM
        self.inputSource = inputSource

        super.init(title: inputSource?.name ?? "", action: #selector(forceKeyboard(_:)), keyEquivalent: "")

        target = self

        updateState()
        watchChanges()
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func forceKeyboard(_: Any) {
        let inputSourceId = inputSource?.id ?? ""

        if let appCustomization = appCustomization {
            preferencesVM.setForceKeyboard(appCustomization, inputSourceId)
        } else {
            preferencesVM.setForceKeyboard(
                preferencesVM.addAppCustomization(app),
                inputSourceId
            )
        }

        inputSource?.select(useCJKVFix: preferencesVM.isUseCJKVFix())

        watchChanges()
    }

    func watchChanges() {
        cancelBag.cancel()

        appCustomization?.publisher(for: \.inputSourceId)
            .sink { [weak self] _ in self?.updateState() }
            .store(in: cancelBag)
    }

    func updateState() {
        state = appCustomization?.inputSourceId == inputSource?.id ? .on : .off
    }
}
