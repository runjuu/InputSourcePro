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
        
        inputSourceChangesPublisher = inputSourceChangesSubject
            .map { _ in InputSource.getCurrentInputSource() }
            .removeDuplicates()
            .eraseToAnyPublisher()

        watchSystemNotification()

        selectInputSourceSubject
            .tap { [weak self] in
                if let self {
                    $0.inputSource.select(cJKVFixStrategy: self.preferencesVM.activeCJKVFixStrategy(for: $0.app))
                }
            }
            .flatMapLatest({ _ in
                Timer
                    .interval(seconds: 1)
                    .eraseToAnyPublisher()
            })
            .sink { [weak self] _ in
                self?.inputSourceChangesSubject.send(())
            }
            .store(in: cancelBag)
    }

    func select(inputSource: InputSource, app: NSRunningApplication? = nil) {
        selectInputSourceSubject.send(SelectionRequest(inputSource: inputSource, app: app))
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
