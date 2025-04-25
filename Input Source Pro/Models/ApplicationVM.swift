import AppKit
import AXSwift
import Combine
import CombineExt
import os

@MainActor
final class ApplicationVM: ObservableObject {
    @Published private(set) var appKind: AppKind? = nil
    @Published private(set) var appsDiff: AppsDiff = .empty

    let logger = ISPLogger(category: String(describing: ApplicationVM.self))

    let cancelBag = CancelBag()
    let preferencesVM: PreferencesVM

    lazy var windowAXNotificationPublisher = ApplicationVM
        .createWindowAXNotificationPublisher(preferencesVM: preferencesVM)

    init(preferencesVM: PreferencesVM) {
        self.preferencesVM = preferencesVM
        appKind = .from(NSWorkspace.shared.frontmostApplication, preferencesVM: preferencesVM)

        activateAccessibilitiesForCurrentApp()
        watchApplicationChange()
        watchAppsDiffChange()
    }
}

extension ApplicationVM {
    private func watchApplicationChange() {
        let axNotification = windowAXNotificationPublisher.mapToVoid()

        let workspaceNotification = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared)
            .mapToVoid()

        Publishers
            .Merge(axNotification, workspaceNotification)
            .compactMap { [weak self] _ -> NSRunningApplication? in
                guard self?.preferencesVM.preferences.isEnhancedModeEnabled == true,
                      let elm: UIElement = try? systemWideElement.attribute(.focusedApplication),
                      let pid = try? elm.pid()
                else { return NSWorkspace.shared.frontmostApplication }
                return NSRunningApplication(processIdentifier: pid)
            }
            .removeDuplicates()
            .flatMapLatest { [weak self] (app: NSRunningApplication) -> AnyPublisher<AppKind, Never> in
                guard let preferencesVM = self?.preferencesVM
                else { return Empty().eraseToAnyPublisher() }

                guard NSApplication.isBrowser(app)
                else { return Just(.from(app, preferencesVM: preferencesVM)).eraseToAnyPublisher() }

                return Timer
                    .interval(seconds: 1)
                    .prepend(Date())
                    .compactMap { _ in app.focusedUIElement(preferencesVM: preferencesVM) }
                    .first()
                    .flatMapLatest { _ in
                        app.watchAX([
                            .focusedUIElementChanged,
                            .titleChanged,
                            .windowCreated,
                        ], [.application, .window])
                            .filter { $0.notification != .windowCreated }
                            .map { event in event.runningApp }
                    }
                    .prepend(app)
                    .compactMap { app -> AppKind? in .from(app, preferencesVM: preferencesVM) }
                    .eraseToAnyPublisher()
            }
            .removeDuplicates(by: { $0.isSameAppOrWebsite(with: $1, detectAddressBar: true) })
            .sink { [weak self] in self?.appKind = $0 }
            .store(in: cancelBag)
    }
}

extension ApplicationVM {
    private func watchAppsDiffChange() {
        AppsDiff
            .publisher(preferencesVM: preferencesVM)
            .assign(to: &$appsDiff)
    }

    private func activateAccessibilitiesForCurrentApp() {
        $appKind
            .compactMap { $0 }
            .filter { [weak self] _ in self?.preferencesVM.preferences.isEnhancedModeEnabled == true }
            .filter { [weak self] in self?.preferencesVM.isHideIndicator($0) != true }
            .sink { $0.getApp().activateAccessibilities() }
            .store(in: cancelBag)
    }
}
