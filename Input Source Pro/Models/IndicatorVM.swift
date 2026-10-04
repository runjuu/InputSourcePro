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

    var actionSubject = PassthroughSubject<Action, Never>()

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
            guard let appKind1 = lhs.appKind, let appKind2 = rhs.appKind
            else { return lhs.appKind == nil && rhs.appKind == nil }

            guard appKind1.isSameAppOrWebsite(with: appKind2, detectAddressBar: true)
            else { return false }

            guard lhs.inputSource.persistentIdentifier == rhs.inputSource.persistentIdentifier
            else { return false }

            return true
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
        actionSubject.send(action)
    }

    func refreshShortcut() {
        refreshShortcutSubject.send(())
    }

    func watchState() {
        actionSubject
            .scan(state) { [weak self] state, action -> State in
                guard let preferencesVM = self?.preferencesVM,
                      let inputSourceVM = self?.inputSourceVM
                else { return state }

                @MainActor
                func updateState(appKind: AppKind?, inputSource: InputSource, inputSourceChangeReason: InputSourceChangeReason) -> State {
                    // TODO: Move to outside
                    if let appKind = appKind {
                        preferencesVM.cacheKeyboardFor(appKind, keyboard: inputSource)
                    }

                    return .from(
                        preferencesVM: preferencesVM,
                        inputSourceChangeReason: inputSourceChangeReason,
                        appKind,
                        inputSource
                    )
                }

                switch action {
                case .start:
                    return state
                case let .appChanged(appKind):
                    if let status = preferencesVM.getAppAutoSwitchKeyboard(appKind) {
                        // The target keyboard is already active in macOS: skip the
                        // redundant TIS select (and CJKV fix) so nothing "switches",
                        // and mark the reason as .noChanges so the indicator won't
                        // announce it. Compare against the live system source rather
                        // than the reducer's optimistic `state.inputSource`, so a
                        // failed or delayed select is retried instead of skipped.
                        let liveInputSource = InputSource.getCurrentInputSource()
                        if status.inputSource.persistentIdentifier == liveInputSource.persistentIdentifier {
                            return updateState(
                                appKind: appKind,
                                inputSource: liveInputSource,
                                inputSourceChangeReason: .noChanges
                            )
                        }

                        inputSourceVM.select(inputSource: status.inputSource, app: appKind.getApp())

                        return updateState(
                            appKind: appKind,
                            inputSource: status.inputSource,
                            inputSourceChangeReason: .appSpecified(status)
                        )
                    } else {
                        return updateState(
                            appKind: appKind,
                            inputSource: state.inputSource,
                            inputSourceChangeReason: .noChanges
                        )
                    }
                case let .inputSourceChanged(inputSource):
                    guard inputSource.persistentIdentifier != state.inputSource.persistentIdentifier else { return state }

                    return updateState(appKind: state.appKind, inputSource: inputSource, inputSourceChangeReason: .system)
                case let .switchInputSourceByShortcut(inputSource):
                    inputSourceVM.select(inputSource: inputSource, app: state.appKind?.getApp())

                    return updateState(appKind: state.appKind, inputSource: inputSource, inputSourceChangeReason: .shortcut)
                }
            }
            .removeDuplicates(by: { $0.isSame(with: $1) })
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
