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

    private var currentFKeyMode: FKeyMode?

    @Published
    private(set) var state: State

    var actionSubject = PassthroughSubject<Action, Never>()

    var refreshShortcutSubject = PassthroughSubject<Void, Never>()

    private(set) lazy var activateEventPublisher = Publishers.MergeMany([
        longMouseDownPublisher(),
        stateChangesPublisher(),
    ])
    .share()

    private(set) lazy var screenIsLockedPublisher = Publishers.MergeMany([
        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name(rawValue: "com.apple.screenIsLocked"))
            .mapTo(true),

        DistributedNotificationCenter.default()
            .publisher(for: NSWorkspace.willSleepNotification)
            .mapTo(true),

        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name(rawValue: "com.apple.screenIsUnlocked"))
            .mapTo(false),

        DistributedNotificationCenter.default()
            .publisher(for: NSWorkspace.didWakeNotification)
            .mapTo(false),
    ])
    .receive(on: DispatchQueue.main)
    .prepend(false)
    .removeDuplicates()
    .share()

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

            guard lhs.inputSource.id == rhs.inputSource.id
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
                        inputSourceVM.select(inputSource: status.inputSource)

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
                    guard inputSource.id != state.inputSource.id else { return state }

                    return updateState(appKind: state.appKind, inputSource: inputSource, inputSourceChangeReason: .system)
                case let .switchInputSourceByShortcut(inputSource):
                    inputSourceVM.select(inputSource: inputSource)

                    return updateState(appKind: state.appKind, inputSource: inputSource, inputSourceChangeReason: .shortcut)
                }
            }
            .removeDuplicates(by: { $0.isSame(with: $1) })
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
            let modifierKey = preferencesVM.singleModifierKey(for: inputSource)

            bindings.append(
                ShortcutBinding(
                    id: inputSource.id,
                    mode: mode,
                    singleModifierKey: modifierKey,
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
            let modifierKey = preferencesVM.singleModifierKey(for: group)

            bindings.append(
                ShortcutBinding(
                    id: id,
                    mode: mode,
                    singleModifierKey: modifierKey,
                    singleModifierTrigger: trigger,
                    onTrigger: { [weak self] in
                        self?.triggerHotKeyGroup(group)
                    }
                )
            )
        }

        return bindings
    }

    private func triggerHotKeyGroup(_ group: HotKeyGroup) {
        guard group.inputSources.count > 0 else { return }

        let currentInputSource = InputSource.getCurrentInputSource()
        let nextIndex = (
            (group.inputSources.firstIndex(where: { currentInputSource.id == $0.id }) ?? -1) + 1
        ) % group.inputSources.count

        send(.switchInputSourceByShortcut(group.inputSources[nextIndex]))
    }
}
