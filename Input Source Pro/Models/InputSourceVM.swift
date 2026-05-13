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
        let allowShortcutFallback: Bool
    }

    let preferencesVM: PreferencesVM

    private var cancelBag = CancelBag()

    private let selectInputSourceSubject = PassthroughSubject<SelectionRequest, Never>()

    private let inputSourceChangesSubject = PassthroughSubject<Void, Never>()

    let inputSourceChangesPublisher: AnyPublisher<InputSource, Never>

    init(preferencesVM: PreferencesVM) {
        self.preferencesVM = preferencesVM

        inputSourceChangesPublisher = inputSourceChangesSubject
            .map { _ in InputSource.getCurrentInputSource() }
            .removeDuplicates()
            .eraseToAnyPublisher()

        watchSystemNotification()

        selectInputSourceSubject
            .tap { [weak self] in
                if let self {
                    $0.inputSource.select(
                        useCJKVFix: self.preferencesVM.isUseCJKVFix(),
                        allowShortcutFallback: $0.allowShortcutFallback
                    )
                }
            }
            .flatMapLatest({ _ in
                Publishers.MergeMany([
                    Just(())
                        .eraseToAnyPublisher(),
                    Timer
                        .delay(seconds: 0.05)
                        .mapToVoid()
                        .eraseToAnyPublisher(),
                    Timer
                        .delay(seconds: 0.15)
                        .mapToVoid()
                        .eraseToAnyPublisher(),
                    Timer
                        .delay(seconds: 0.3)
                        .mapToVoid()
                        .eraseToAnyPublisher()
                ])
                .eraseToAnyPublisher()
            })
            .sink { [weak self] _ in
                self?.inputSourceChangesSubject.send(())
            }
            .store(in: cancelBag)
    }

    func select(inputSource: InputSource, allowShortcutFallback: Bool = true) {
        selectInputSourceSubject.send(
            SelectionRequest(
                inputSource: inputSource,
                allowShortcutFallback: allowShortcutFallback
            )
        )
    }

    private func watchSystemNotification() {
        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.inputSourceChangesSubject.send(())
            }
            .store(in: cancelBag)
    }
}
