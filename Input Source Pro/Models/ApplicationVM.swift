import AppKit
import AXSwift
import Combine
import CombineExt
import ApplicationServices
import os

@MainActor
final class ApplicationVM: ObservableObject {
    @Published private(set) var appKind: AppKind? = nil
    @Published private(set) var appsDiff: AppsDiff = .empty

    let logger = ISPLogger(category: String(describing: ApplicationVM.self))

    let cancelBag = CancelBag()
    let preferencesVM: PreferencesVM

    private var launchpadSessionActive = false
    private var launchpadSettleWork: DispatchWorkItem?
    private var launchpadReturnLayout: (bundleId: String, inputSourceId: String)?

    private let launchpadCloseSettleMilliseconds = 220

    lazy var windowAXNotificationPublisher = ApplicationVM
        .createWindowAXNotificationPublisher(preferencesVM: preferencesVM)

    init(preferencesVM: PreferencesVM) {
        self.preferencesVM = preferencesVM
        appKind = .from(NSWorkspace.shared.frontmostApplication, preferencesVM: preferencesVM)

        activateAccessibilitiesForCurrentApp()
        watchApplicationChange()
        watchLaunchpadOverlay()
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

        Publishers
            .MergeMany([
                axNotification.eraseToAnyPublisher(),
                didActivateAppNotification.eraseToAnyPublisher(),
                activeSpaceDidChangeNotification.eraseToAnyPublisher()
            ])
            .compactMap { [weak self] _ -> NSRunningApplication? in
                self?.resolveFocusApplication()
            }
            .filter { app in
                !InputSourceSwitcher.isTemporaryInputWindowApplicationActivation(app)
            }
            .compactMap { [weak self] app -> NSRunningApplication? in
                self?.normalizeFocusApplication(app)
            }
            .removeDuplicates()
            .flatMapLatest { [weak self] (app: NSRunningApplication) -> AnyPublisher<AppKind, Never> in
                guard let preferencesVM = self?.preferencesVM
                else { return Empty().eraseToAnyPublisher() }

                if NSApplication.isBrowser(app) {
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

                let pid = app.processIdentifier
                let poll = Timer
                    .interval(seconds: 0.25)
                    .map { _ in app }
                    .prepend(app)

                let ax: AnyPublisher<NSRunningApplication, Never> = {
                    guard AXIsProcessTrusted() else {
                        return Empty().eraseToAnyPublisher()
                    }
                    return app.watchAX(
                        [
                            .focusedWindowChanged,
                            .focusedUIElementChanged,
                            .windowCreated,
                        ],
                        [.application, .window]
                    )
                    .filter { $0.notification != .windowCreated }
                    .map { event in event.runningApp }
                    .eraseToAnyPublisher()
                }()

                return Publishers.Merge(poll, ax)
                    .filter { $0.processIdentifier == pid }
                    .compactMap { app -> AppKind? in .from(app, preferencesVM: preferencesVM) }
                    .eraseToAnyPublisher()
            }
            .removeDuplicates(by: { $0.isSameAppOrWebsite(with: $1, detectAddressBar: true) })
            .sink { [weak self] in
                let app = $0.getApp()
                let window = $0.windowCacheId() ?? "nil"
                ISPFileLog.event(
                    "focus",
                    "app=\(app.bundleIdentifier ?? "nil")#\(app.processIdentifier) name=\(app.localizedName ?? "?") cacheId=\($0.getId() ?? "nil") window=\(window)"
                )
                self?.appKind = $0
            }
            .store(in: cancelBag)
    }

    private func resolveFocusApplication() -> NSRunningApplication? {
        guard preferencesVM.preferences.isEnhancedModeEnabled == true,
              let elm: UIElement = try? systemWideElement.attribute(.focusedApplication),
              let pid = try? elm.pid()
        else { return NSWorkspace.shared.frontmostApplication }
        return NSRunningApplication(processIdentifier: pid)
    }

    private func normalizeFocusApplication(_ app: NSRunningApplication) -> NSRunningApplication? {
        let launchpadVisible = LaunchpadOverlayDetector.isLaunchpadVisible()

        if launchpadVisible {
            if let dock = SystemChrome.dockRunningApplication() {
                return dock
            }
            return app
        }

        if launchpadSessionActive {
            ISPFileLog.event(
                "focus-skip",
                "settle in progress, ignore \(app.bundleIdentifier ?? "nil")",
                includeSnapshot: false
            )
            return nil
        }

        if SystemChrome.isPointerChrome(app.bundleIdentifier) {
            ISPFileLog.event(
                "focus-skip",
                "pointer-chrome \(app.bundleIdentifier ?? "nil")",
                includeSnapshot: false
            )
            return nil
        }

        return app
    }

    private func watchLaunchpadOverlay() {
        Timer.interval(seconds: 0.3)
            .prepend(Date())
            .sink { [weak self] _ in
                self?.pollLaunchpadOverlay()
            }
            .store(in: cancelBag)
    }

    private func pollLaunchpadOverlay() {
        let visible = LaunchpadOverlayDetector.isLaunchpadVisible()

        if visible {
            launchpadSettleWork?.cancel()
            launchpadSettleWork = nil

            if !launchpadSessionActive {
                launchpadSessionActive = true
                captureTypingLayoutBeforeLaunchpad()
                ISPFileLog.event("launchpad", "OPENED")
                applyLaunchpadFocus()
            }
            return
        }

        guard launchpadSessionActive else { return }

        scheduleLaunchpadCloseSettle()
    }

    private func scheduleLaunchpadCloseSettle() {
        launchpadSettleWork?.cancel()
        ISPFileLog.event(
            "launchpad",
            "close detected, settle \(launchpadCloseSettleMilliseconds)ms",
            includeSnapshot: false
        )
        let work = DispatchWorkItem { [weak self] in
            self?.finishLaunchpadClose()
        }
        launchpadSettleWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(launchpadCloseSettleMilliseconds),
            execute: work
        )
    }

    private func finishLaunchpadClose() {
        launchpadSettleWork = nil

        if LaunchpadOverlayDetector.isLaunchpadVisible() {
            ISPFileLog.event("launchpad", "reappeared during settle — abort close")
            applyLaunchpadFocus()
            return
        }

        launchpadSessionActive = false

        let app = resolvePostLaunchpadApplication()
        ISPFileLog.event(
            "launchpad",
            "CLOSED → \(app?.localizedName ?? "?")[\(app?.bundleIdentifier ?? "nil")]"
        )

        guard let app else {
            launchpadReturnLayout = nil
            return
        }

        if let pending = launchpadReturnLayout,
           app.bundleIdentifier != pending.bundleId
        {
            ISPFileLog.event(
                "launchpad-restore-drop",
                "pending=\(pending.bundleId) actual=\(app.bundleIdentifier ?? "nil")",
                includeSnapshot: false
            )
            launchpadReturnLayout = nil
        }

        appKind = .from(app, preferencesVM: preferencesVM)
    }

    private func applyLaunchpadFocus() {
        guard let dock = SystemChrome.dockRunningApplication() else {
            ISPFileLog.event("launchpad", "OPENED but Dock process missing")
            return
        }
        appKind = .from(dock, preferencesVM: preferencesVM)
    }

    private func captureTypingLayoutBeforeLaunchpad() {
        let candidate = typingApplicationForLaunchpadCapture()
        guard let candidate,
              let bundleId = candidate.bundleIdentifier,
              !SystemChrome.isPointerChrome(bundleId),
              !SystemChrome.isLaunchpadRelated(bundleId)
        else {
            launchpadReturnLayout = nil
            ISPFileLog.event("launchpad-capture", "skipped — no typing app", includeSnapshot: false)
            return
        }

        let layout = InputSource.getCurrentInputSource()
        launchpadReturnLayout = (bundleId, layout.persistentIdentifier)
        ISPFileLog.event(
            "launchpad-capture",
            "\(bundleId) → \(layout.persistentIdentifier)"
        )
    }

    private func typingApplicationForLaunchpadCapture() -> NSRunningApplication? {
        if let current = appKind?.getApp(),
           let id = current.bundleIdentifier,
           !SystemChrome.isPointerChrome(id),
           !SystemChrome.isLaunchpadRelated(id)
        {
            return current
        }

        if let front = NSWorkspace.shared.frontmostApplication,
           front.activationPolicy == .regular,
           let id = front.bundleIdentifier,
           !SystemChrome.isPointerChrome(id)
        {
            return front
        }

        return nil
    }

    func consumeLaunchpadLayoutRestore(for appKind: AppKind) -> InputSource? {
        guard let pending = launchpadReturnLayout else { return nil }

        let bundleId = appKind.getApp().bundleIdentifier
        guard bundleId == pending.bundleId else { return nil }

        launchpadReturnLayout = nil

        if preferencesVM.getAppCustomization(app: appKind.getApp())?.forcedKeyboard != nil {
            ISPFileLog.event(
                "launchpad-restore-skip",
                "forced keyboard rule for \(bundleId ?? "?")",
                includeSnapshot: false
            )
            return nil
        }

        guard let source = InputSource.resolvePersistedIdentifier(pending.inputSourceId) else {
            ISPFileLog.event(
                "launchpad-restore-miss",
                "unresolved \(pending.inputSourceId)",
                includeSnapshot: false
            )
            return nil
        }

        ISPFileLog.event(
            "launchpad-restore",
            "\(bundleId ?? "?") → \(source.persistentIdentifier)"
        )
        return source
    }

    private func resolvePostLaunchpadApplication() -> NSRunningApplication? {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.activationPolicy == .regular,
           !SystemChrome.isPointerChrome(app.bundleIdentifier)
        {
            return app
        }

        if preferencesVM.preferences.isEnhancedModeEnabled,
           let elm: UIElement = try? systemWideElement.attribute(.focusedApplication),
           let pid = try? elm.pid(),
           let app = NSRunningApplication(processIdentifier: pid),
           app.activationPolicy == .regular,
           !SystemChrome.isPointerChrome(app.bundleIdentifier)
        {
            return app
        }

        return NSWorkspace.shared.frontmostApplication
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
