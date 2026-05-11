import AppKit

@MainActor
class BrowserRuleMenuItem: NSMenuItem {
    let app: NSRunningApplication
    let url: URL
    let preferencesVM: PreferencesVM
    let inputSourceVM: InputSourceVM
    let inputSource: InputSource?

    var cancelBag = CancelBag()

    var browserRule: BrowserRule? {
        preferencesVM.getBrowserRule(url: url)
    }

    init(
        app: NSRunningApplication,
        url: URL,
        preferencesVM: PreferencesVM,
        inputSourceVM: InputSourceVM,
        inputSource: InputSource?
    ) {
        self.app = app
        self.url = url
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
        let host = url.host ?? ""

        if let browserRule = browserRule {
            preferencesVM.updateBrowserRule(
                browserRule,
                type: .domain,
                value: host,
                sample: url.absoluteString,
                inputSourceId: inputSourceId,
                hideIndicator: browserRule.hideIndicator,
                keyboardRestoreStrategy: browserRule.keyboardRestoreStrategy
            )
        } else {
            preferencesVM.addBrowserRule(
                type: .domain,
                value: host,
                sample: url.absoluteString,
                inputSourceId: inputSourceId,
                hideIndicator: false,
                keyboardRestoreStrategy: nil
            )
        }

        if let inputSource {
            inputSourceVM.select(inputSource: inputSource, app: app)
        }

        watchChanges()
    }

    func watchChanges() {
        cancelBag.cancel()

        browserRule?.publisher(for: \.inputSourceId)
            .sink { [weak self] _ in self?.updateState() }
            .store(in: cancelBag)
    }

    func updateState() {
        state = browserRule?.forcedKeyboard?.persistentIdentifier == inputSource?.persistentIdentifier ? .on : .off
    }
}
