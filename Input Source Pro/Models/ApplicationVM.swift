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
            .prepend(())
            .compactMap { [weak self] _ -> NSRunningApplication? in
                guard self?.preferencesVM.preferences.isEnhancedModeEnabled == true,
                      let elm: UIElement = try? systemWideElement.attribute(.focusedApplication),
                      let pid = try? elm.pid()
                else { return NSWorkspace.shared.frontmostApplication }
                return NSRunningApplication(processIdentifier: pid)
            }
            .filter { app in
                !InputSourceSwitcher.isTemporaryInputWindowApplicationActivation(app)
            }
            .removeDuplicates()
            .flatMapLatest { [weak self] (app: NSRunningApplication) -> AnyPublisher<AppKind, Never> in
                guard let preferencesVM = self?.preferencesVM
                else { return Empty().eraseToAnyPublisher() }

                let shouldWatchCodexTerminal = app.bundleIdentifier == CodexTerminalDetector.bundleIdentifier
                    && preferencesVM.preferences.isEnhancedModeEnabled
                    && preferencesVM.codexTerminalInputSource != nil

                guard NSApplication.isBrowser(app) || shouldWatchCodexTerminal
                else { return Just(.from(app, preferencesVM: preferencesVM)).eraseToAnyPublisher() }

                if shouldWatchCodexTerminal {
                    // Chromium/Electron only exposes the web content accessibility tree (where the
                    // xterm-helper-textarea lives) after `AXManualAccessibility` is set to true on
                    // the app's AX element. Without this, `focusedUIElement` returns kAXNoValue and
                    // `CodexTerminalDetector` can never see the terminal markers, so we'd fall back
                    // to the app's default input source instead of `codexTerminalInputSource`.
                    app.activateAccessibilities()

                    return Timer
                        .interval(seconds: 0.25)
                        .prepend(Date())
                        .map { _ in AppKind.from(app, preferencesVM: preferencesVM) }
                        .eraseToAnyPublisher()
                }

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
