import AppKit
import AXSwift
import Carbon
import Combine
import Foundation

@MainActor
class InputSourceVM: ObservableObject {
    let preferencesVM: PreferencesVM

    private var _isProgrammaticChange = false

    private var cancelBag = CancelBag()

    private let selectInputSourceSubject = PassthroughSubject<InputSource, Never>()

    private let inputSourceChangesSubject = PassthroughSubject<InputSource, Never>()

    let inputSourceChangesPublisher: AnyPublisher<InputSource, Never>

    init(preferencesVM: PreferencesVM) {
        self.preferencesVM = preferencesVM
        inputSourceChangesPublisher = inputSourceChangesSubject.eraseToAnyPublisher()

        watchSystemNotification()

        selectInputSourceSubject
            .tap { [weak self] inputSource in
                guard let preferencesVM = self?.preferencesVM
                else { return }

                inputSource.select(useCJKVFix: preferencesVM.isUseCJKVFix())
            }
            .flatMapLatest { _ in
                Timer.interval(seconds: 0.2)
                    .map { _ in InputSource.getCurrentInputSource() }
                    .withPrevious()
                    .filter { previous, current in
                        guard let previous = previous else { return false }
                        return previous.id == current.id
                    }
                    .map { _, current in current }
                    .prefix(1)
            }
            .sink { [weak self] in
                self?.inputSourceChangesSubject.send($0)
                self?._isProgrammaticChange = false
            }
            .store(in: cancelBag)
    }

    func select(inputSource: InputSource) {
        _isProgrammaticChange = true
        selectInputSourceSubject.send(inputSource)
    }

    private func watchSystemNotification() {
        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String))
            .receive(on: DispatchQueue.main)
            .filter { [weak self] _ in self?._isProgrammaticChange == false }
            .map { _ in InputSource.getCurrentInputSource() }
            .sink { [weak self] in self?.inputSourceChangesSubject.send($0) }
            .store(in: cancelBag)
    }

    private func getInputSourceFromMenu() -> InputSource? {
        for app in NSWorkspace.shared.runningApplications {
            if app.bundleIdentifier == "com.apple.TextInputMenuAgent" {
                if let application = app.getApplication(preferencesVM: preferencesVM),
                   let menuBar: UIElement = try? application.attribute(.extrasMenuBar)
                {
                    for child in menuBar.children() ?? [] {
                        if let description: String = try? child.attribute(.description),
                           let inputSource = InputSource.sources.first(where: { $0.name == description })
                        {
                            return inputSource
                        }
                    }
                }

                return nil
            }
        }

        return nil
    }
}
