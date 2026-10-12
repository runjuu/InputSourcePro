import AppKit
import AXSwift
import Carbon
import Combine
import Foundation
import CombineExt

@MainActor
class InputSourceVM: ObservableObject {
    private struct SelectionRequest {
        let inputSource: InputSource
        let app: NSRunningApplication?
    }

    let preferencesVM: PreferencesVM

    private var cancelBag = CancelBag()

    private let selectInputSourceSubject = PassthroughSubject<SelectionRequest, Never>()

    private let inputSourceChangesSubject = PassthroughSubject<Void, Never>()

    let inputSourceChangesPublisher: AnyPublisher<InputSource, Never>

    init(preferencesVM: PreferencesVM) {
        self.preferencesVM = preferencesVM
        
        inputSourceChangesPublisher = SourceReconciliationCore.observations(
            tokens: inputSourceChangesSubject.eraseToAnyPublisher(),
            readActual: { InputSourceSwitcher.inputSourceForReconciliation() },
            observed: { IndicatorDiagnostics.record("inputSource.observed source=\($0.persistentIdentifier)") }
        )

        watchSystemNotification()

        // Requests perform selection; they never reset the read-only heartbeat.
        selectInputSourceSubject
            .sink { [weak self] request in
                guard let self else { return }
                request.inputSource.select(cJKVFixStrategy: self.preferencesVM.activeCJKVFixStrategy(for: request.app))
            }
            .store(in: cancelBag)

        SourceReconciliationCore.connectHeartbeat(
            tokens: Timer.interval(seconds: 1).map { _ in () }.eraseToAnyPublisher(),
            deliver: { [weak self] in
                IndicatorDiagnostics.record("inputSource.trigger reason=poll")
                self?.inputSourceChangesSubject.send(())
            }
        )
        .store(in: cancelBag)

    }

    func select(inputSource: InputSource, app: NSRunningApplication? = nil) {
        IndicatorDiagnostics.record("inputSource.select source=\(inputSource.persistentIdentifier) pid=\(app?.processIdentifier ?? 0)")
        selectInputSourceSubject.send(SelectionRequest(inputSource: inputSource, app: app))
    }

    private func watchSystemNotification() {
        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                IndicatorDiagnostics.record("inputSource.trigger reason=TIS-notification")
                self?.inputSourceChangesSubject.send(())
            }
            .store(in: cancelBag)
    }
}
