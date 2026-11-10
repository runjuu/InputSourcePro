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
        watchRuntimeRuleChange()
        watchAppsDiffChange()
    }
}

extension ApplicationVM {
    private func watchApplicationChange() {
        let axNotification = windowAXNotificationPublisher
            .mapToVoid()

        let didActivateAppNotification = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared)
            .mapToVoid()

        let activeSpaceDidChangeNotification = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
            .mapToVoid()

        // focusedApplication lags AX events, so re-read it a few times after each one.
        let axNotificationBurst = axNotification
            .flatMapLatest { _ in
                Timer.interval(seconds: 0.04)
                    .prepend(Date())
                    .prefix(21) // ~0.8 s
                    .mapToVoid()
            }

        Publishers
            .MergeMany([
                axNotificationBurst.eraseToAnyPublisher(),
                didActivateAppNotification.eraseToAnyPublisher(),
                activeSpaceDidChangeNotification.eraseToAnyPublisher()
            ])
            .compactMap { [weak self] _ -> NSRunningApplication? in
                let frontmost = NSWorkspace.shared.frontmostApplication
                if frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    return frontmost
                }
                guard self?.preferencesVM.preferences.isEnhancedModeEnabled == true,
                      let elm: UIElement = try? systemWideElement.attribute(.focusedApplication),
                      let pid = try? elm.pid()
                else { return frontmost }
                return NSRunningApplication(processIdentifier: pid)
            }
            .filter { app in
                !InputSourceSwitcher.isTemporaryInputWindowApplicationActivation(app)
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
                        // ⌘L right after switching to the browser moves focus into the address bar. Skip the
                        // default 0.5s attach delay (the browser already answers AX) and re-read once attached.
                        app.watchAX([
                            .focusedUIElementChanged,
                            .titleChanged,
                            .windowCreated,
                        ], [.application, .window], attachImmediately: true)
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
    private func watchRuntimeRuleChange() {
        preferencesVM.runtimeRuleChanges
            .compactMap { [weak self] _ -> AppKind? in
                guard let self = self else { return nil }
                let app = self.appKind?.getApp() ?? NSWorkspace.shared.frontmostApplication
                return AppKind.from(app, preferencesVM: self.preferencesVM)
            }
            .filter { appKind in
                !InputSourceSwitcher.isTemporaryInputWindowApplicationActivation(appKind.getApp())
            }
            .sink { [weak self] in self?.appKind = $0 }
            .store(in: cancelBag)
    }

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
