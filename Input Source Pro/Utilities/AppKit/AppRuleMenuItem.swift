import AppKit

@MainActor
class AppRuleMenuItem: NSMenuItem {
    let app: NSRunningApplication
    let preferencesVM: PreferencesVM
    let inputSourceVM: InputSourceVM
    let inputSource: InputSource?

    var cancelBag = CancelBag()

    var appCustomization: AppRule? {
        preferencesVM.getAppCustomization(app: app)
    }

    init(
        app: NSRunningApplication,
        preferencesVM: PreferencesVM,
        inputSourceVM: InputSourceVM,
        inputSource: InputSource?
    ) {
        self.app = app
        self.preferencesVM = preferencesVM
        self.inputSourceVM = inputSourceVM
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
        let inputSourceId = inputSource?.persistentIdentifier ?? ""

        if let appCustomization = appCustomization {
            preferencesVM.setForceKeyboard(appCustomization, inputSourceId)
        } else {
            preferencesVM.setForceKeyboard(
                preferencesVM.addAppCustomization(app),
                inputSourceId
            )
        }

        if let inputSource {
            inputSourceVM.select(inputSource: inputSource, app: app)
        }

        watchChanges()
    }

    func watchChanges() {
        cancelBag.cancel()

        appCustomization?.publisher(for: \.inputSourceId)
            .sink { [weak self] _ in self?.updateState() }
            .store(in: cancelBag)
    }

    func updateState() {
        state = appCustomization?.forcedKeyboard?.persistentIdentifier == inputSource?.persistentIdentifier ? .on : .off
    }
}
