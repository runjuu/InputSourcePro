import AppKit

@MainActor
class BrowserRuleMenuItem: NSMenuItem {
    let url: URL
    let preferencesVM: PreferencesVM
    let inputSource: InputSource?

    var cancelBag = CancelBag()

    var browserRule: BrowserRule? {
        preferencesVM.getBrowserRule(url: url)
    }

    init(url: URL, preferencesVM: PreferencesVM, inputSource: InputSource?) {
        self.url = url
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

        inputSource?.select(useCJKVFix: preferencesVM.isUseCJKVFix())

        watchChanges()
    }

    func watchChanges() {
        cancelBag.cancel()

        browserRule?.publisher(for: \.inputSourceId)
            .sink { [weak self] _ in self?.updateState() }
            .store(in: cancelBag)
    }

    func updateState() {
        state = browserRule?.inputSourceId == inputSource?.id ? .on : .off
    }
}
