import Foundation

extension PreferencesVM {
    func shortcutMode(for inputSource: InputSource) -> ShortcutTriggerMode {
        if let mode = (preferences.shortcutModeInputSourceMapping ?? [:])[inputSource.id] {
            return mode
        }

        return preferences.shortcutTriggerMode ?? .keyboardShortcut
    }

    func shortcutMode(for group: HotKeyGroup) -> ShortcutTriggerMode {
        guard let id = group.id else { return .keyboardShortcut }

        if let mode = (preferences.shortcutModeGroupMapping ?? [:])[id] {
            return mode
        }

        return preferences.shortcutTriggerMode ?? .keyboardShortcut
    }

    func singleModifierTrigger(for inputSource: InputSource) -> SingleModifierTrigger {
        if let trigger = (preferences.singleModifierTriggerInputSourceMapping ?? [:])[inputSource.id] {
            return trigger
        }

        return preferences.singleModifierTrigger ?? .singlePress
    }

    func singleModifierTrigger(for group: HotKeyGroup) -> SingleModifierTrigger {
        guard let id = group.id else { return .singlePress }

        if let trigger = (preferences.singleModifierTriggerGroupMapping ?? [:])[id] {
            return trigger
        }

        return preferences.singleModifierTrigger ?? .singlePress
    }

    func singleModifierKey(for inputSource: InputSource) -> SingleModifierKey? {
        return (preferences.singleModifierInputSourceMapping ?? [:])[inputSource.id]
    }

    func singleModifierKey(for group: HotKeyGroup) -> SingleModifierKey? {
        guard let id = group.id else { return nil }
        return (preferences.singleModifierGroupMapping ?? [:])[id]
    }

    func updateShortcutMode(_ mode: ShortcutTriggerMode, for inputSource: InputSource) {
        update { preferences in
            var inputSourceModes = preferences.shortcutModeInputSourceMapping ?? [:]
            inputSourceModes[inputSource.id] = mode
            preferences.shortcutModeInputSourceMapping = inputSourceModes

            if mode != .singleModifier {
                var inputSourceMapping = preferences.singleModifierInputSourceMapping ?? [:]
                inputSourceMapping.removeValue(forKey: inputSource.id)
                preferences.singleModifierInputSourceMapping = inputSourceMapping
            }
        }
    }

    func updateShortcutMode(_ mode: ShortcutTriggerMode, for group: HotKeyGroup) {
        guard let id = group.id else { return }

        update { preferences in
            var groupModes = preferences.shortcutModeGroupMapping ?? [:]
            groupModes[id] = mode
            preferences.shortcutModeGroupMapping = groupModes

            if mode != .singleModifier {
                var groupMapping = preferences.singleModifierGroupMapping ?? [:]
                groupMapping.removeValue(forKey: id)
                preferences.singleModifierGroupMapping = groupMapping
            }
        }
    }

    func updateSingleModifierTrigger(_ trigger: SingleModifierTrigger, for inputSource: InputSource) {
        update { preferences in
            var triggerMapping = preferences.singleModifierTriggerInputSourceMapping ?? [:]
            triggerMapping[inputSource.id] = trigger
            preferences.singleModifierTriggerInputSourceMapping = triggerMapping
        }
    }

    func updateSingleModifierTrigger(_ trigger: SingleModifierTrigger, for group: HotKeyGroup) {
        guard let id = group.id else { return }

        update { preferences in
            var triggerMapping = preferences.singleModifierTriggerGroupMapping ?? [:]
            triggerMapping[id] = trigger
            preferences.singleModifierTriggerGroupMapping = triggerMapping
        }
    }

    func updateSingleModifierKey(_ key: SingleModifierKey?, for inputSource: InputSource) {
        update { preferences in
            var inputSourceMapping = preferences.singleModifierInputSourceMapping ?? [:]
            var groupMapping = preferences.singleModifierGroupMapping ?? [:]
            let inputSourceModes = preferences.shortcutModeInputSourceMapping ?? [:]
            let groupModes = preferences.shortcutModeGroupMapping ?? [:]
            let fallbackMode = preferences.shortcutTriggerMode ?? .keyboardShortcut

            func usesSingleModifierInputSource(_ id: String) -> Bool {
                if let mode = inputSourceModes[id] {
                    return mode == .singleModifier
                }
                return fallbackMode == .singleModifier
            }

            func usesSingleModifierGroup(_ id: String) -> Bool {
                if let mode = groupModes[id] {
                    return mode == .singleModifier
                }
                return fallbackMode == .singleModifier
            }

            if let key = key {
                let duplicateInputSourceKeys = inputSourceMapping
                    .filter { $0.value == key && usesSingleModifierInputSource($0.key) }
                    .map(\.key)
                let duplicateGroupKeys = groupMapping
                    .filter { $0.value == key && usesSingleModifierGroup($0.key) }
                    .map(\.key)

                duplicateInputSourceKeys.forEach { inputSourceMapping.removeValue(forKey: $0) }
                duplicateGroupKeys.forEach { groupMapping.removeValue(forKey: $0) }

                inputSourceMapping[inputSource.id] = key
            } else {
                inputSourceMapping.removeValue(forKey: inputSource.id)
            }

            preferences.singleModifierInputSourceMapping = inputSourceMapping
            preferences.singleModifierGroupMapping = groupMapping
        }
    }

    func updateSingleModifierKey(_ key: SingleModifierKey?, for group: HotKeyGroup) {
        guard let id = group.id else { return }

        update { preferences in
            var inputSourceMapping = preferences.singleModifierInputSourceMapping ?? [:]
            var groupMapping = preferences.singleModifierGroupMapping ?? [:]
            let inputSourceModes = preferences.shortcutModeInputSourceMapping ?? [:]
            let groupModes = preferences.shortcutModeGroupMapping ?? [:]
            let fallbackMode = preferences.shortcutTriggerMode ?? .keyboardShortcut

            func usesSingleModifierInputSource(_ id: String) -> Bool {
                if let mode = inputSourceModes[id] {
                    return mode == .singleModifier
                }
                return fallbackMode == .singleModifier
            }

            func usesSingleModifierGroup(_ id: String) -> Bool {
                if let mode = groupModes[id] {
                    return mode == .singleModifier
                }
                return fallbackMode == .singleModifier
            }

            if let key = key {
                let duplicateInputSourceKeys = inputSourceMapping
                    .filter { $0.value == key && usesSingleModifierInputSource($0.key) }
                    .map(\.key)
                let duplicateGroupKeys = groupMapping
                    .filter { $0.value == key && usesSingleModifierGroup($0.key) }
                    .map(\.key)

                duplicateInputSourceKeys.forEach { inputSourceMapping.removeValue(forKey: $0) }
                duplicateGroupKeys.forEach { groupMapping.removeValue(forKey: $0) }

                groupMapping[id] = key
            } else {
                groupMapping.removeValue(forKey: id)
            }

            preferences.singleModifierInputSourceMapping = inputSourceMapping
            preferences.singleModifierGroupMapping = groupMapping
        }
    }

    func removeShortcutConfig(for group: HotKeyGroup) {
        guard let id = group.id else { return }

        update { preferences in
            var groupModes = preferences.shortcutModeGroupMapping ?? [:]
            var groupTriggers = preferences.singleModifierTriggerGroupMapping ?? [:]
            var groupMapping = preferences.singleModifierGroupMapping ?? [:]

            groupModes.removeValue(forKey: id)
            groupTriggers.removeValue(forKey: id)
            groupMapping.removeValue(forKey: id)

            preferences.shortcutModeGroupMapping = groupModes
            preferences.singleModifierTriggerGroupMapping = groupTriggers
            preferences.singleModifierGroupMapping = groupMapping
        }
    }
}
