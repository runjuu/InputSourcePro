import AppKit
import AXSwift
import Combine
import CombineExt
import os

@MainActor
final class IndicatorVM: ObservableObject {
    private var cancelBag = CancelBag()
    private lazy var shortcutTriggerManager = ShortcutTriggerManager(preferencesVM: preferencesVM)

    let applicationVM: ApplicationVM
    let preferencesVM: PreferencesVM
    let inputSourceVM: InputSourceVM
    let permissionsVM: PermissionsVM
    let punctuationService: PunctuationService

    let logger = ISPLogger(category: String(describing: IndicatorVM.self))

    /// The function-key mode currently enforced by the app (per-app rule, default,
    /// or shortcut override). Published so the Function Keys settings chip can mirror
    /// the live mode the indicator shows, instead of the stored global default.
    @Published private(set) var currentFKeyMode: FKeyMode?

    @Published private(set) var isCapsLockOn = NSEvent.modifierFlags.contains(.capsLock)

    /// Fires when the user toggles the function-key mode via the shortcut, so the
    /// indicator can show the new mode the same way it shows input-source changes.
    let functionKeyModeChangeSubject = PassthroughSubject<FKeyMode, Never>()

    @Published
    private(set) var state: State

    private let actionRelay = SourceReconciliationCore.SerializedActionRelay<Action>(
        onFault: { fault in
            NSLog("Input Source Pro: input-source action relay TERMINAL FAULT %@; subsequent actions rejected until restart", String(describing: fault))
        }
    )

    var refreshShortcutSubject = PassthroughSubject<Void, Never>()

    private(set) lazy var activateEventPublisher = Publishers.MergeMany([
        longMouseDownPublisher(),
        stateChangesPublisher(),
        functionKeyModeChangesPublisher(),
        capsLockChangesPublisher(),
    ])
    .handleEvents(receiveOutput: { IndicatorDiagnostics.record("activation.emitted event=\($0.diagnosticDescription)") })
    .share()

    private(set) lazy var indicatorIsSuspendedPublisher = Self.indicatorSuspensionPublisher(
        lockNotificationCenter: DistributedNotificationCenter.default(),
        workspaceNotificationCenter: NSWorkspace.shared.notificationCenter
    )

    static func indicatorSuspensionPublisher(
        lockNotificationCenter: NotificationCenter,
        workspaceNotificationCenter: NotificationCenter
    ) -> AnyPublisher<Bool, Never> {
        let isLocked = Publishers.Merge(
            lockNotificationCenter
                .publisher(for: Notification.Name(rawValue: "com.apple.screenIsLocked"))
                .mapTo(true),
            lockNotificationCenter
                .publisher(for: Notification.Name(rawValue: "com.apple.screenIsUnlocked"))
                .mapTo(false)
        )
        .receive(on: DispatchQueue.main)
        .prepend(false)

        let isSleeping = Publishers.Merge(
            workspaceNotificationCenter
                .publisher(for: NSWorkspace.willSleepNotification)
                .mapTo(true),
            workspaceNotificationCenter
                .publisher(for: NSWorkspace.didWakeNotification)
                .mapTo(false)
        )
        .receive(on: DispatchQueue.main)
        .prepend(false)

        // Waking the Mac must not resume the indicator while the screen is locked.
        return Publishers.CombineLatest(isLocked, isSleeping)
            .map { isLocked, isSleeping in isLocked || isSleeping }
            .removeDuplicates()
            .share(replay: 1)
            .eraseToAnyPublisher()
    }

    init(
        permissionsVM: PermissionsVM,
        preferencesVM: PreferencesVM,
        applicationVM: ApplicationVM,
        inputSourceVM: InputSourceVM
    ) {
        self.permissionsVM = permissionsVM
        self.preferencesVM = preferencesVM
        self.applicationVM = applicationVM
        self.inputSourceVM = inputSourceVM
        self.punctuationService = PunctuationService(preferencesVM: preferencesVM)
        state = .from(
            preferencesVM: preferencesVM,
            inputSourceChangeReason: .system,
            applicationVM.appKind,
            InputSource.getCurrentInputSource()
        )

        clearAppKeyboardCacheIfNeed()
        watchState()
        watchPunctuationRules()
        watchFunctionKeyMode()
        watchCapsLock()
    }

    private func watchCapsLock() {
        let flags = Publishers.Merge(
            NSEvent.watch(matching: .flagsChanged),
            NSEvent.watchLocal(matching: .flagsChanged)
        )
        .map(\.modifierFlags)

        let resumed = Publishers.Merge(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).mapToVoid(),
            DistributedNotificationCenter.default()
                .publisher(for: Notification.Name("com.apple.screenIsUnlocked")).mapToVoid()
        )
        .receive(on: DispatchQueue.main)
        .map { NSEvent.modifierFlags }

        Self.confirmedCapsLockPublisher(
            states: Publishers.Merge(flags, resumed)
                .map { $0.contains(.capsLock) }
                .eraseToAnyPublisher(),
            initialState: isCapsLockOn
        )
        .handleEvents(receiveOutput: { IndicatorDiagnostics.record("capsLock.state on=\($0)") })
        .assign(to: &$isCapsLockOn)
    }

    static func confirmedCapsLockPublisher(
        states: AnyPublisher<Bool, Never>,
        initialState: Bool,
        confirmation: @escaping () -> AnyPublisher<Void, Never> = {
            Timer.delay(seconds: 0.1).mapToVoid().eraseToAnyPublisher()
        }
    ) -> AnyPublisher<Bool, Never> {
        states
            .removeDuplicates()
            .handleEvents(receiveOutput: { IndicatorDiagnostics.record("capsLock.raw on=\($0)") })
            .flatMapLatest { isOn -> AnyPublisher<Bool, Never> in
                // Input-source switching can briefly set the Caps Lock flag.
                // Confirm activation before publishing to either indicator; an off
                // event cancels the pending confirmation and clears the state now.
                isOn ? confirmation().first().mapTo(true).eraseToAnyPublisher()
                    : Just(false).eraseToAnyPublisher()
            }
            .prepend(initialState)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private func clearAppKeyboardCacheIfNeed() {
        applicationVM.$appsDiff
            .sink { [weak self] appsDiff in
                appsDiff.removed
                    .compactMap { $0.bundleIdentifier }
                    .forEach { bundleId in
                        self?.preferencesVM.removeKeyboardCacheFor(bundleId: bundleId)
                    }
            }
            .store(in: cancelBag)

        preferencesVM.$preferences
            .map(\.isRestorePreviouslyUsedInputSource)
            .filter { $0 == false }
            .sink { [weak self] _ in
                self?.preferencesVM.clearKeyboardCache()
            }
            .store(in: cancelBag)
    }

    private func watchPunctuationRules() {
        applicationVM.$appKind
            .compactMap { $0 }
            .sink { [weak self] appKind in
                guard let self = self else { return }
                
                let app = appKind.getApp()
                if self.punctuationService.shouldEnableForApp(app) {
                    self.logger.debug { "Enabling English punctuation for app: \(app.localizedName ?? app.bundleIdentifier ?? "Unknown")" }
                    self.punctuationService.enable()
                } else {
                    self.punctuationService.disable()
                }
            }
            .store(in: cancelBag)
    }

    private func watchFunctionKeyMode() {
        applicationVM.$appKind
            .compactMap { $0 }
            .sink { [weak self] appKind in
                self?.applyFunctionKeyMode(for: appKind)
            }
            .store(in: cancelBag)

        preferencesVM.$preferences
            .map(\.isFunctionKeysEnabled)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self = self,
                      let appKind = self.applicationVM.appKind
                else { return }

                self.applyFunctionKeyMode(for: appKind)
            }
            .store(in: cancelBag)
    }

    private func applyFunctionKeyMode(for appKind: AppKind) {
        let desiredMode = preferencesVM.functionKeyMode(for: appKind)

        guard desiredMode != currentFKeyMode else { return }

        do {
            try FKeyManager.setCurrentFKeyMode(desiredMode)
            currentFKeyMode = desiredMode
        } catch {
            logger.debug { "Failed to set function key mode: \(error.localizedDescription)" }
        }
    }
}

extension IndicatorVM {
    enum InputSourceChangeReason {
        case noChanges, system, shortcut, appSpecified(PreferencesVM.AppAutoSwitchKeyboardStatus)
    }

    @MainActor
    struct State {
        let appKind: AppKind?
        let inputSource: InputSource
        let inputSourceChangeReason: InputSourceChangeReason

        func isSame(with other: State) -> Bool {
            return State.isSame(self, other)
        }

        static func isSame(_ lhs: IndicatorVM.State, _ rhs: IndicatorVM.State) -> Bool {
            return SourceReconciliationCore.same(
                .init(appKind: lhs.appKind, inputSource: lhs.inputSource, inputSourceChangeReason: lhs.inputSourceChangeReason),
                .init(appKind: rhs.appKind, inputSource: rhs.inputSource, inputSourceChangeReason: rhs.inputSourceChangeReason),
                sameContext: { $0.isSameAppOrWebsite(with: $1, detectAddressBar: true) }
            )
        }

        static func from(
            preferencesVM _: PreferencesVM,
            inputSourceChangeReason: InputSourceChangeReason,
            _ appKind: AppKind?,
            _ inputSource: InputSource
        ) -> State {
            return .init(
                appKind: appKind,
                inputSource: inputSource,
                inputSourceChangeReason: inputSourceChangeReason
            )
        }
    }

    enum Action {
        case start
        case appChanged(AppKind)
        case switchInputSourceByShortcut(InputSource)
        case inputSourceChanged(InputSource)
    }

    func send(_ action: Action) {
        actionRelay.send(action)
    }

    func refreshShortcut() {
        refreshShortcutSubject.send(())
    }

    func watchState() {
        let initial = SourceReconciliationCore.Snapshot(
            appKind: state.appKind,
            inputSource: state.inputSource,
            inputSourceChangeReason: state.inputSourceChangeReason
        )
        // R3 ownership contract: do not retain the VM's collaborators for the
        // lifetime of the scan. Promote weak owner to strong only for one action.
        let dependencies: () -> SourceReconciliationCore.Dependencies<AppKind, InputSource, InputSourceChangeReason>? = { [weak self] in
            guard let self else { return nil }
            let preferencesVM = self.preferencesVM
            let inputSourceVM = self.inputSourceVM
            return SourceReconciliationCore.Dependencies(
                readActual: { InputSourceSwitcher.inputSourceForReconciliation() },
                rule: { app in
                    guard let status = preferencesVM.getAppAutoSwitchKeyboard(app) else { return nil }
                    return (status.inputSource, .appSpecified(status))
                },
                select: { source, app in inputSourceVM.select(inputSource: source, app: app?.getApp()) },
                cache: { app, source in preferencesVM.cacheKeyboardFor(app, keyboard: source) },
                noChanges: .noChanges,
                system: .system,
                shortcut: .shortcut
            )
        }
        let coreActions = actionRelay.publisher.map { action -> SourceReconciliationCore.Action<AppKind, InputSource> in
            switch action {
            case .start: return .start
            case let .appChanged(app): return .appChanged(app)
            case let .switchInputSourceByShortcut(source): return .switchInputSourceByShortcut(source)
            case let .inputSourceChanged(source): return .inputSourceChanged(source)
            }
        }
        .eraseToAnyPublisher()
        SourceReconciliationCore.states(
            actions: coreActions,
            initial: initial,
            dependencies: dependencies,
            sameContext: { $0.isSameAppOrWebsite(with: $1, detectAddressBar: true) }
        )
        .map { snapshot in
            State(
                appKind: snapshot.appKind,
                inputSource: snapshot.inputSource,
                inputSourceChangeReason: snapshot.inputSourceChangeReason
            )
        }
            .handleEvents(receiveOutput: {
                IndicatorDiagnostics.record("state.published source=\($0.inputSource.persistentIdentifier) reason=\($0.inputSourceChangeReason.diagnosticDescription) pid=\($0.appKind?.getApp().processIdentifier ?? 0)")
            })
            .assign(to: &$state)

        applicationVM.$appKind
            .compactMap { $0 }
            .sink(receiveValue: { [weak self] in self?.send(.appChanged($0)) })
            .store(in: cancelBag)

        inputSourceVM.inputSourceChangesPublisher
            .sink(receiveValue: { [weak self] in self?.send(.inputSourceChanged($0)) })
            .store(in: cancelBag)

        refreshShortcutSubject
            .sink { [weak self] _ in
                guard let self = self else { return }

                self.shortcutTriggerManager.updateBindings(self.shortcutBindings())
            }
            .store(in: cancelBag)

        refreshShortcut()
        send(.start)
    }

    private func shortcutBindings() -> [ShortcutBinding] {
        var bindings: [ShortcutBinding] = []

        for inputSource in InputSource.sources {
            let mode = preferencesVM.shortcutMode(for: inputSource)
            let trigger = preferencesVM.singleModifierTrigger(for: inputSource)
            let modifierCombo = preferencesVM.modifierCombo(for: inputSource)

            bindings.append(
                ShortcutBinding(
                    id: inputSource.persistentIdentifier,
                    mode: mode,
                    modifierCombo: modifierCombo,
                    singleModifierTrigger: trigger,
                    onTrigger: { [weak self] in
                        self?.send(.switchInputSourceByShortcut(inputSource))
                    }
                )
            )
        }

        for group in preferencesVM.getHotKeyGroups() {
            guard let id = group.id else { continue }

            let mode = preferencesVM.shortcutMode(for: group)
            let trigger = preferencesVM.singleModifierTrigger(for: group)
            let modifierCombo = preferencesVM.modifierCombo(for: group)

            bindings.append(
                ShortcutBinding(
                    id: id,
                    mode: mode,
                    modifierCombo: modifierCombo,
                    singleModifierTrigger: trigger,
                    onTrigger: { [weak self] in
                        self?.triggerHotKeyGroup(group)
                    }
                )
            )
        }

        bindings.append(
            ShortcutBinding(
                id: PreferencesVM.functionKeysToggleShortcutId,
                mode: preferencesVM.functionKeysToggleMode(),
                modifierCombo: preferencesVM.functionKeysToggleCombo(),
                singleModifierTrigger: preferencesVM.functionKeysToggleTrigger(),
                onTrigger: { [weak self] in
                    self?.toggleFunctionKeyMode()
                }
            )
        )

        return bindings
    }

    private func toggleFunctionKeyMode() {
        let current = currentFKeyMode
            ?? (try? FKeyManager.getCurrentFKeyMode().get())
            ?? preferencesVM.preferences.functionKeyMode
        let toggled: FKeyMode = current == .functionKeys ? .mediaKeys : .functionKeys

        // Persist as the new global default. This keeps the change for apps without a
        // per-app rule and keeps the General → "Default Function Keys" toggle in sync.
        // The synchronous `watchFunctionKeyMode` sink may re-apply a per-app rule here.
        preferencesVM.update { $0.functionKeyMode = toggled }

        // Force the live system mode afterwards so the toggle takes effect immediately,
        // even when the frontmost app has a per-app Function Keys rule. The rule
        // re-asserts on the next app switch.
        do {
            try FKeyManager.setCurrentFKeyMode(toggled)
            currentFKeyMode = toggled
            functionKeyModeChangeSubject.send(toggled)
        } catch {
            logger.debug { "Failed to toggle function key mode: \(error.localizedDescription)" }
        }
    }

    private func triggerHotKeyGroup(_ group: HotKeyGroup) {
        let inputSources = group.inputSources
        guard inputSources.count > 0 else { return }

        let currentInputSource = InputSource.getCurrentInputSource()
        let nextIndex = (
            (inputSources.firstIndex {
                currentInputSource.persistentIdentifier == $0.persistentIdentifier
            } ?? -1) + 1
        ) % inputSources.count

        send(.switchInputSourceByShortcut(inputSources[nextIndex]))
    }
}
