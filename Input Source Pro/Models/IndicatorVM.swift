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

    /// Fires when the user toggles the function-key mode via the shortcut, so the
    /// indicator can show the new mode the same way it shows input-source changes.
    let functionKeyModeChangeSubject = PassthroughSubject<FKeyMode, Never>()

    @Published
    private(set) var state: State

    var actionSubject = PassthroughSubject<Action, Never>()

    var refreshShortcutSubject = PassthroughSubject<Void, Never>()

    private var committedLayoutIdByCacheId: [String: String] = [:]
    private var pendingUserAcceptLayoutId: String?
    private var pendingUserAcceptCacheId: String?
    private var userAcceptWorkItem: DispatchWorkItem?
    private let userAcceptDelay: TimeInterval = 1.5
    private var isApplyingLayout = false
    private var applyDebounceWorkItem: DispatchWorkItem?
    private var applyGeneration = 0
    private let applyDebounceMilliseconds = 60
    private let applyReselectMilliseconds = 120

    private(set) lazy var activateEventPublisher = Publishers.MergeMany([
        longMouseDownPublisher(),
        stateChangesPublisher(),
        functionKeyModeChangesPublisher(),
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
        preferencesVM.$preferences
            .map(\.isRestorePreviouslyUsedInputSource)
            .removeDuplicates()
            .dropFirst()
            .filter { $0 == false }
            .sink { [weak self] _ in
                self?.preferencesVM.clearKeyboardCache()
                ISPFileLog.event("cache-clear", "restore-previously-used turned off", includeSnapshot: false)
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
                func updateState(
                    appKind: AppKind?,
                    inputSource: InputSource,
                    inputSourceChangeReason: InputSourceChangeReason,
                    shouldCache: Bool
                ) -> State {
                    if shouldCache, let appKind = appKind {
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
                    let previous = state.appKind

                    if Self.shouldSkipSameContextAppChange(previous: previous, next: appKind) {
                        ISPFileLog.event(
                            "multi-inst",
                            "skip same-context \(Self.appLogId(appKind)) keep live=\(InputSource.getCurrentInputSource().persistentIdentifier) pendingAccept=\(self?.userAcceptWorkItem != nil)",
                            includeSnapshot: false
                        )
                        return state
                    }

                    let isSameBundleDifferentProcess = Self.isSameBundleDifferentProcess(
                        previous: previous,
                        next: appKind
                    )
                    let isSameProcessWindowChange = Self.isSameProcessWindowChange(
                        previous: previous,
                        next: appKind
                    )
                    let liveBefore = InputSource.getCurrentInputSource()
                    let nextCacheId = appKind.getId() ?? "nil"
                    let nextDisk = {
                        if isSameProcessWindowChange {
                            return preferencesVM.appKeyboardCache.retrieveExact(appKind)?.persistentIdentifier ?? "nil"
                        }
                        return preferencesVM.appKeyboardCache.retrieve(appKind)?.persistentIdentifier ?? "nil"
                    }()

                    ISPFileLog.event(
                        "multi-inst",
                        "focus-change from=\(previous.map(Self.appLogId) ?? "nil") to=\(Self.appLogId(appKind)) sameBundleDiffPid=\(isSameBundleDifferentProcess) windowChange=\(isSameProcessWindowChange) cacheId=\(nextCacheId) disk=\(nextDisk) live=\(liveBefore.persistentIdentifier) stateWas=\(state.inputSource.persistentIdentifier)",
                        includeSnapshot: false
                    )

                    if let previous {
                        let leftProcess = previous.getApp().processIdentifier
                            != appKind.getApp().processIdentifier
                        let leftWindow = isSameProcessWindowChange
                        if (leftProcess || leftWindow),
                           !SystemChrome.isLaunchpadRelated(previous.getApp().bundleIdentifier)
                        {
                            let committedId = self?.committedLayoutIdByCacheId[previous.getId() ?? ""]
                            let exactDiskId = preferencesVM.appKeyboardCache.retrieveExact(previous)?
                                .persistentIdentifier
                            if leftWindow {
                                let decision = Self.windowLeaveSaveDecision(
                                    liveId: liveBefore.persistentIdentifier,
                                    committedId: committedId,
                                    pendingAcceptLayoutId: self?.pendingUserAcceptLayoutId,
                                    pendingAcceptCacheId: self?.pendingUserAcceptCacheId,
                                    previousCacheId: previous.getId(),
                                    exactDiskId: exactDiskId
                                )
                                self?.cancelUserAccept()
                                let toSave: InputSource
                                if decision.layoutId == liveBefore.persistentIdentifier {
                                    toSave = liveBefore
                                } else {
                                    toSave = InputSource.resolvePersistedIdentifier(decision.layoutId)
                                        ?? liveBefore
                                }
                                preferencesVM.rememberKeyboardOnLeave(
                                    for: previous,
                                    keyboard: toSave
                                )
                                self?.markCommitted(previous, toSave)
                                ISPFileLog.event(
                                    "cache-leave-window",
                                    "\(Self.appLogId(previous)) → \(toSave.persistentIdentifier) (\(decision.reason); live=\(liveBefore.persistentIdentifier))",
                                    includeSnapshot: false
                                )
                            } else if let decision = Self.processLeaveSaveDecision(
                                liveId: liveBefore.persistentIdentifier,
                                committedId: committedId,
                                pendingAcceptLayoutId: self?.pendingUserAcceptLayoutId,
                                pendingAcceptCacheId: self?.pendingUserAcceptCacheId,
                                previousCacheId: previous.getId(),
                                isApplyingLayout: self?.isApplyingLayout == true
                            ) {
                                self?.cancelUserAccept()
                                let toSave: InputSource
                                if decision.layoutId == liveBefore.persistentIdentifier {
                                    toSave = liveBefore
                                } else {
                                    toSave = InputSource.resolvePersistedIdentifier(decision.layoutId)
                                        ?? liveBefore
                                }
                                preferencesVM.rememberKeyboardOnLeave(
                                    for: previous,
                                    keyboard: toSave
                                )
                                self?.markCommitted(previous, toSave)
                                ISPFileLog.event(
                                    "cache-leave-process",
                                    "\(Self.appLogId(previous)) → \(toSave.persistentIdentifier) (\(decision.reason); live=\(liveBefore.persistentIdentifier))",
                                    includeSnapshot: false
                                )
                            } else {
                                self?.cancelUserAccept()
                                let disk = exactDiskId
                                    ?? preferencesVM.appKeyboardCache.retrieve(previous)?.persistentIdentifier
                                    ?? "nil"
                                ISPFileLog.event(
                                    "cache-leave-skip",
                                    "\(Self.appLogId(previous)) no auto-save keep disk=\(disk) live=\(liveBefore.persistentIdentifier) committed=\(committedId ?? "nil") reason=process",
                                    includeSnapshot: false
                                )
                            }
                        }
                    }

                    self?.cancelUserAccept()
                    self?.cancelPendingApply()

                    if let restored = self?.applicationVM.consumeLaunchpadLayoutRestore(for: appKind) {
                        ISPFileLog.event(
                            "switch",
                            "app=\(Self.appLogId(appKind)) via=launchpad-restore → \(restored.persistentIdentifier)"
                        )
                        self?.applyLayoutOnce(restored, appKind: appKind, liveBefore: liveBefore)
                        return updateState(
                            appKind: appKind,
                            inputSource: restored,
                            inputSourceChangeReason: .appSpecified(.cached(restored)),
                            shouldCache: false
                        )
                    }

                    if isSameProcessWindowChange {
                        if let exact = preferencesVM.appKeyboardCache.retrieveExact(appKind),
                           preferencesVM.appNeedCacheKeyboard(appKind)
                        {
                            ISPFileLog.event(
                                "switch",
                                "app=\(Self.appLogId(appKind)) via=window-cached → \(exact.persistentIdentifier) | current=\(liveBefore.persistentIdentifier) cacheId=\(nextCacheId)"
                            )
                            self?.applyLayoutOnce(exact, appKind: appKind, liveBefore: liveBefore)
                            return updateState(
                                appKind: appKind,
                                inputSource: exact,
                                inputSourceChangeReason: .appSpecified(.cached(exact)),
                                shouldCache: false
                            )
                        }

                        let current = InputSource.getCurrentInputSource()
                        self?.markCommitted(appKind, current)
                        ISPFileLog.event(
                            "switch-skip",
                            "app=\(Self.appLogId(appKind)) window keep-live → \(current.persistentIdentifier)"
                        )
                        return updateState(
                            appKind: appKind,
                            inputSource: current,
                            inputSourceChangeReason: .noChanges,
                            shouldCache: false
                        )
                    }

                    if let status = preferencesVM.getAppAutoSwitchKeyboard(appKind) {
                        // The target keyboard is already active in macOS: skip the
                        // redundant TIS select (and CJKV fix) so nothing "switches",
                        // and mark the reason as .noChanges so the indicator won't
                        // announce it. Compare against the live system source rather
                        // than the reducer's optimistic `state.inputSource`, so a
                        // failed or delayed select is retried instead of skipped.
                        let liveInputSource = InputSource.getCurrentInputSource()
                        if status.inputSource.persistentIdentifier == liveInputSource.persistentIdentifier {
                            self?.markCommitted(appKind, liveInputSource)
                            return updateState(
                                appKind: appKind,
                                inputSource: liveInputSource,
                                inputSourceChangeReason: .noChanges,
                                shouldCache: false
                            )
                        }

                        let forced = preferencesVM.forcedKeyboard(for: appKind)
                        let isAddressBar = appKind.getBrowserInfo()?.isFocusedOnAddressBar == true
                        let applyAcrossInstances = Self.shouldApplyAutoSwitchAcrossSameBundleInstances(
                            status: status,
                            forced: forced,
                            isAddressBar: isAddressBar
                        )
                        let statusKind: String = {
                            switch status {
                            case .cached: return "cached"
                            case .specified: return "specified"
                            }
                        }()

                        if isSameBundleDifferentProcess, !applyAcrossInstances {
                            let current = InputSource.getCurrentInputSource()
                            self?.markCommitted(appKind, current)
                            ISPFileLog.event(
                                "multi-inst",
                                "decision=keep-live app=\(Self.appLogId(appKind)) status=\(statusKind) target=\(status.inputSource.persistentIdentifier) forced=\(forced?.persistentIdentifier ?? "nil") addressBar=\(isAddressBar) → live \(current.persistentIdentifier)",
                                includeSnapshot: false
                            )
                            ISPFileLog.event(
                                "switch-skip",
                                "app=\(Self.appLogId(appKind)) same-bundle multi-instance keep-live → \(current.persistentIdentifier)"
                            )
                            return updateState(
                                appKind: appKind,
                                inputSource: current,
                                inputSourceChangeReason: .noChanges,
                                shouldCache: false
                            )
                        }

                        if isSameBundleDifferentProcess {
                            ISPFileLog.event(
                                "multi-inst",
                                "decision=apply app=\(Self.appLogId(appKind)) status=\(statusKind) → \(status.inputSource.persistentIdentifier) forced=\(forced?.persistentIdentifier ?? "nil") addressBar=\(isAddressBar) disk=\(nextDisk)",
                                includeSnapshot: false
                            )
                        }

                        let via = statusKind
                        let current = InputSource.getCurrentInputSource().persistentIdentifier
                        ISPFileLog.event(
                            "switch",
                            "app=\(Self.appLogId(appKind)) via=\(via) → \(status.inputSource.persistentIdentifier) | current=\(current) disk=\(nextDisk) cacheId=\(nextCacheId)"
                        )
                        self?.applyLayoutOnce(status.inputSource, appKind: appKind, liveBefore: liveBefore)

                        return updateState(
                            appKind: appKind,
                            inputSource: status.inputSource,
                            inputSourceChangeReason: .appSpecified(status),
                            shouldCache: false
                        )
                    } else {
                        let current = InputSource.getCurrentInputSource()
                        self?.markCommitted(appKind, current)
                        ISPFileLog.event(
                            "multi-inst",
                            "decision=no-rule keep-live app=\(Self.appLogId(appKind)) cacheId=\(nextCacheId) → \(current.persistentIdentifier)",
                            includeSnapshot: false
                        )
                        ISPFileLog.event(
                            "switch-skip",
                            "app=\(Self.appLogId(appKind)) no rule/cache → live \(current.persistentIdentifier)"
                        )
                        return updateState(
                            appKind: appKind,
                            inputSource: current,
                            inputSourceChangeReason: .noChanges,
                            shouldCache: false
                        )
                    }
                case let .inputSourceChanged(inputSource):
                    guard inputSource.persistentIdentifier != state.inputSource.persistentIdentifier else {
                        return state
                    }

                    ISPFileLog.event(
                        "tis-system",
                        "\(state.inputSource.persistentIdentifier) → \(inputSource.persistentIdentifier) app=\(state.appKind.map(Self.appLogId) ?? "nil")"
                    )

                    if let appKind = state.appKind,
                       let forced = preferencesVM.forcedKeyboard(for: appKind),
                       forced.persistentIdentifier != inputSource.persistentIdentifier
                    {
                        ISPFileLog.event(
                            "forced-repin",
                            "\(Self.appLogId(appKind)) \(inputSource.persistentIdentifier) → \(forced.persistentIdentifier)"
                        )
                        self?.applyLayoutOnce(forced, appKind: appKind, liveBefore: inputSource)
                        return updateState(
                            appKind: appKind,
                            inputSource: forced,
                            inputSourceChangeReason: .appSpecified(.specified(forced)),
                            shouldCache: false
                        )
                    }

                    if let appKind = state.appKind {
                        self?.scheduleUserAcceptIfNeeded(appKind: appKind, candidate: inputSource)
                    }

                    return updateState(
                        appKind: state.appKind,
                        inputSource: inputSource,
                        inputSourceChangeReason: .system,
                        shouldCache: false
                    )
                case let .switchInputSourceByShortcut(inputSource):
                    inputSourceVM.select(inputSource: inputSource, app: state.appKind?.getApp())
                    if let appKind = state.appKind {
                        self?.rememberShortcutLayout(appKind, inputSource)
                    }

                    return updateState(
                        appKind: state.appKind,
                        inputSource: inputSource,
                        inputSourceChangeReason: .shortcut,
                        shouldCache: false
                    )
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

    private func applyLayoutOnce(_ inputSource: InputSource, appKind: AppKind, liveBefore: InputSource) {
        markCommitted(appKind, inputSource)
        let alreadyLive = liveBefore.persistentIdentifier == inputSource.persistentIdentifier
        if alreadyLive {
            ISPFileLog.event(
                "apply",
                "\(Self.appLogId(appKind)) already-live \(inputSource.persistentIdentifier)",
                includeSnapshot: false
            )
            return
        }

        applyDebounceWorkItem?.cancel()
        applyGeneration += 1
        let generation = applyGeneration
        let targetId = inputSource.persistentIdentifier
        ISPFileLog.event(
            "apply",
            "\(Self.appLogId(appKind)) schedule select \(targetId) in \(applyDebounceMilliseconds)ms",
            includeSnapshot: false
        )
        let work = DispatchWorkItem { [weak self] in
            self?.performSelect(
                inputSource,
                appKind: appKind,
                generation: generation
            )
        }
        applyDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(applyDebounceMilliseconds),
            execute: work
        )
    }

    private func performSelect(_ inputSource: InputSource, appKind: AppKind, generation: Int) {
        guard generation == applyGeneration else { return }
        isApplyingLayout = true
        ISPFileLog.event(
            "apply",
            "\(Self.appLogId(appKind)) select \(inputSource.persistentIdentifier)",
            includeSnapshot: false
        )
        inputSourceVM.select(inputSource: inputSource, app: appKind.getApp())

        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(applyReselectMilliseconds)
        ) { [weak self] in
            guard let self, generation == self.applyGeneration else { return }
            let live = InputSource.getCurrentInputSource().persistentIdentifier
            let wanted = inputSource.persistentIdentifier
            if live != wanted {
                ISPFileLog.event(
                    "apply",
                    "\(Self.appLogId(appKind)) one-shot re-select \(wanted) (was \(live))",
                    includeSnapshot: false
                )
                self.inputSourceVM.select(inputSource: inputSource, app: appKind.getApp())
            } else {
                ISPFileLog.event(
                    "apply",
                    "\(Self.appLogId(appKind)) confirmed \(wanted)",
                    includeSnapshot: false
                )
            }
            self.isApplyingLayout = false
        }
    }

    private func markCommitted(_ appKind: AppKind, _ inputSource: InputSource) {
        guard let id = appKind.getId() else { return }
        committedLayoutIdByCacheId[id] = inputSource.persistentIdentifier
    }

    private func committedLayout(for appKind: AppKind) -> InputSource? {
        guard let id = appKind.getId(),
              let layoutId = committedLayoutIdByCacheId[id]
        else { return nil }
        return InputSource.resolvePersistedIdentifier(layoutId)
    }

    private func cancelUserAccept() {
        userAcceptWorkItem?.cancel()
        userAcceptWorkItem = nil
        pendingUserAcceptLayoutId = nil
        pendingUserAcceptCacheId = nil
    }

    private func cancelPendingApply() {
        applyDebounceWorkItem?.cancel()
        applyDebounceWorkItem = nil
        applyGeneration += 1
        isApplyingLayout = false
    }

    private func scheduleUserAcceptIfNeeded(appKind: AppKind, candidate: InputSource) {
        if isApplyingLayout {
            ISPFileLog.event(
                "memory",
                "skip applying-echo \(candidate.persistentIdentifier)",
                includeSnapshot: false
            )
            return
        }

        if let id = appKind.getId(),
           committedLayoutIdByCacheId[id] == candidate.persistentIdentifier
        {
            ISPFileLog.event(
                "memory",
                "skip committed-echo \(candidate.persistentIdentifier)",
                includeSnapshot: false
            )
            return
        }

        cancelUserAccept()
        let tokenPid = appKind.getApp().processIdentifier
        let tokenLayout = candidate.persistentIdentifier
        let tokenCacheId = appKind.getId()
        pendingUserAcceptLayoutId = tokenLayout
        pendingUserAcceptCacheId = tokenCacheId
        ISPFileLog.event(
            "memory",
            "candidate \(tokenLayout) for \(Self.appLogId(appKind)) — accept in \(userAcceptDelay)s if stable",
            includeSnapshot: false
        )
        let work = DispatchWorkItem { [weak self] in
            self?.confirmUserLayout(
                appKind: appKind,
                candidateId: tokenLayout,
                tokenPid: tokenPid,
                tokenCacheId: tokenCacheId
            )
        }
        userAcceptWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + userAcceptDelay, execute: work)
    }

    private func confirmUserLayout(
        appKind: AppKind,
        candidateId: String,
        tokenPid: pid_t,
        tokenCacheId: String?
    ) {
        userAcceptWorkItem = nil
        guard state.appKind?.getApp().processIdentifier == tokenPid,
              state.appKind?.getId() == tokenCacheId
        else {
            ISPFileLog.event("memory", "skip left-app \(candidateId)", includeSnapshot: false)
            return
        }
        let live = InputSource.getCurrentInputSource()
        guard live.persistentIdentifier == candidateId else {
            ISPFileLog.event(
                "memory",
                "skip unstable wanted=\(candidateId) live=\(live.persistentIdentifier)",
                includeSnapshot: false
            )
            return
        }
        preferencesVM.cacheKeyboardFor(appKind, keyboard: live)
        markCommitted(appKind, live)
        pendingUserAcceptLayoutId = nil
        pendingUserAcceptCacheId = nil
        ISPFileLog.event(
            "memory",
            "USER stable \(candidateId) for \(Self.appLogId(appKind))",
            includeSnapshot: false
        )
    }

    private func rememberShortcutLayout(_ appKind: AppKind, _ inputSource: InputSource) {
        cancelUserAccept()
        markCommitted(appKind, inputSource)
        preferencesVM.cacheKeyboardFor(appKind, keyboard: inputSource)
        ISPFileLog.event(
            "user-layout",
            "\(Self.appLogId(appKind)) → \(inputSource.persistentIdentifier) (shortcut)",
            includeSnapshot: false
        )
    }

    static func shouldSkipSameContextAppChange(previous: AppKind?, next: AppKind) -> Bool {
        guard let previous else { return false }
        return next.isSameAppOrWebsite(with: previous, detectAddressBar: true)
    }

    static func isSameProcessWindowChange(previous: AppKind?, next: AppKind) -> Bool {
        guard let previous else { return false }
        guard previous.getApp().processIdentifier == next.getApp().processIdentifier else {
            return false
        }
        return previous.getId() != next.getId()
    }

    static func windowLeaveSaveDecision(
        liveId: String,
        committedId: String?,
        pendingAcceptLayoutId: String?,
        pendingAcceptCacheId: String?,
        previousCacheId: String?,
        exactDiskId: String?
    ) -> (layoutId: String, reason: String) {
        if let pendingAcceptLayoutId,
           pendingAcceptLayoutId == liveId,
           pendingAcceptCacheId == previousCacheId
        {
            return (pendingAcceptLayoutId, "pending-user")
        }
        if let committedId {
            return (committedId, "committed")
        }
        if let exactDiskId {
            return (exactDiskId, "disk")
        }
        return (liveId, "live")
    }

    static func processLeaveSaveDecision(
        liveId: String,
        committedId: String?,
        pendingAcceptLayoutId: String?,
        pendingAcceptCacheId: String?,
        previousCacheId: String?,
        isApplyingLayout: Bool
    ) -> (layoutId: String, reason: String)? {
        if let pendingAcceptLayoutId,
           pendingAcceptLayoutId == liveId,
           pendingAcceptCacheId == previousCacheId
        {
            return (pendingAcceptLayoutId, "pending-user")
        }
        if !isApplyingLayout,
           let committedId,
           liveId != committedId
        {
            return (liveId, "live-ahead")
        }
        return nil
    }

    static func isSameBundleDifferentProcess(previous: AppKind?, next: AppKind) -> Bool {
        guard let previous else { return false }
        let prevApp = previous.getApp()
        let nextApp = next.getApp()
        guard let prevBundle = prevApp.bundleIdentifier,
              let nextBundle = nextApp.bundleIdentifier,
              prevBundle == nextBundle
        else { return false }
        return prevApp.processIdentifier != nextApp.processIdentifier
    }

    static func shouldAcceptStableUserLayout(
        stillSameProcess: Bool,
        liveMatchesCandidate: Bool,
        isEchoOfSessionApply: Bool
    ) -> Bool {
        stillSameProcess && liveMatchesCandidate && !isEchoOfSessionApply
    }

    static func shouldApplyAutoSwitchAcrossSameBundleInstances(
        status: PreferencesVM.AppAutoSwitchKeyboardStatus,
        forced: InputSource?,
        isAddressBar: Bool
    ) -> Bool {
        if isAddressBar { return true }
        if forced != nil { return true }
        if case .cached = status { return true }
        return false
    }

    static func appLogId(_ appKind: AppKind) -> String {
        let app = appKind.getApp()
        let base = "\(app.bundleIdentifier ?? "?")#\(app.processIdentifier)"
        if let windowId = appKind.windowCacheId() {
            return "\(base)#\(windowId)"
        }
        return base
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
