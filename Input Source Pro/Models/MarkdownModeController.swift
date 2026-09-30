import Combine

@MainActor
final class MarkdownModeController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var failure: PunctuationService.Failure?

    var onPreferenceChange: ((Bool) -> Void)?

    private let service: PunctuationService
    private var shouldEnableAppEnglish: Bool
    private var requestedEnabled = false
    private var isStoppedForSafety = false
    private var isUpdatingPreference = false

    init(service: PunctuationService, shouldEnableAppEnglish: Bool) {
        self.service = service
        self.shouldEnableAppEnglish = shouldEnableAppEnglish
        service.onSafetyShutdown = { [weak self] shutdown in
            guard shutdown.mode == .markdown else { return }
            self?.recordSafetyShutdown(shutdown.failure)
        }
    }

    func bindPreference(
        values: AnyPublisher<Bool, Never>,
        currentValue: @escaping () -> Bool,
        update: @escaping (Bool) -> Void
    ) -> AnyCancellable {
        onPreferenceChange = { [weak self] enabled in
            guard let self = self, currentValue() != enabled else { return }
            self.isUpdatingPreference = true
            update(enabled)
            self.isUpdatingPreference = false
        }
        var didReceivePreference = false
        return values.sink { [weak self] enabled in
            guard let self = self, !self.isUpdatingPreference else { return }
            guard !didReceivePreference || enabled != self.isEnabled else { return }
            didReceivePreference = true
            self.setEnabled(enabled)
        }
    }

    func setEnabled(_ enabled: Bool) {
        requestedEnabled = enabled
        isStoppedForSafety = false
        reconcile()
    }

    func appContextChanged(shouldEnableAppEnglish: Bool) {
        self.shouldEnableAppEnglish = shouldEnableAppEnglish
        reconcile()
    }

    func revalidateMarkdown() {
        guard requestedEnabled else { return }
        reconcile()
    }

    private func reconcile() {
        if requestedEnabled {
            let wasMarkdownActive = service.activeMode == .markdown
            switch service.enable(mode: .markdown) {
            case .success:
                isEnabled = true
                failure = nil
                onPreferenceChange?(true)
            case .failure(let failure):
                self.failure = failure
                requestedEnabled = false
                isEnabled = false
                isStoppedForSafety = wasMarkdownActive
                applyAppEnglishRule()
                onPreferenceChange?(false)
            }
        } else {
            isEnabled = false
            applyAppEnglishRule()
            onPreferenceChange?(false)
        }
    }

    private func applyAppEnglishRule() {
        if !isStoppedForSafety && shouldEnableAppEnglish {
            service.enable(mode: .appEnglish)
        } else {
            service.disable()
        }
    }

    private func recordSafetyShutdown(_ failure: PunctuationService.Failure) {
        isStoppedForSafety = true
        requestedEnabled = false
        isEnabled = false
        self.failure = failure
        onPreferenceChange?(false)
    }
}
