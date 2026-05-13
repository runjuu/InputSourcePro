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
    private var lastResolvedBrowserAppKinds = [String: AppKind]()

    lazy var windowAXNotificationPublisher = ApplicationVM
        .createWindowAXNotificationPublisher(preferencesVM: preferencesVM)

    init(preferencesVM: PreferencesVM) {
        self.preferencesVM = preferencesVM
        appKind = resolveAppKind(for: NSWorkspace.shared.frontmostApplication)

        activateAccessibilitiesForCurrentApp()
        watchApplicationChange()
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

        Publishers
            .MergeMany([
                axNotification.eraseToAnyPublisher(),
                didActivateAppNotification.eraseToAnyPublisher(),
                activeSpaceDidChangeNotification.eraseToAnyPublisher()
            ])
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
                else {
                    return Just(app)
                        .compactMap { [weak self] in self?.resolveAppKind(for: $0) }
                        .eraseToAnyPublisher()
                }

                return Timer
                    .interval(seconds: 0.05)
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
                    .compactMap { [weak self] in self?.resolveAppKind(for: $0) }
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

    private func resolveAppKind(for app: NSRunningApplication?) -> AppKind? {
        guard let app else { return nil }

        let resolved = AppKind.from(app, preferencesVM: preferencesVM)

        if let browserInfo = resolved.getBrowserInfo(),
           !browserInfo.isFocusedOnAddressBar,
           browserInfo.url != .newtab,
           let bundleIdentifier = app.bundleIdentifier
        {
            lastResolvedBrowserAppKinds[bundleIdentifier] = resolved
            return resolved
        }

        guard preferencesVM.isBrowserAndEnabled(app),
              let bundleIdentifier = app.bundleIdentifier,
              case .normal = resolved,
              let fallback = lastResolvedBrowserAppKinds[bundleIdentifier]
        else {
            return resolved
        }

        logger.debug { "Reusing cached browser context for \(bundleIdentifier) while waiting for the focused tab to resolve." }
        return fallback
    }
}
