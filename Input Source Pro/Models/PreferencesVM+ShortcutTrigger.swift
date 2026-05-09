import Foundation

extension PreferencesVM {
    private func shortcutPreferenceKey(for inputSource: InputSource) -> String {
        return inputSource.persistentIdentifier
    }

    private func legacyShortcutPreferenceKey(for inputSource: InputSource) -> String? {
        let key = shortcutPreferenceKey(for: inputSource)
        return key == inputSource.id ? nil : inputSource.id
    }

    private func legacyShortcutPreferenceKeysByPersistentKey() -> [String: String] {
        return InputSource.sources.reduce(into: [:]) { result, inputSource in
            if let legacyKey = legacyShortcutPreferenceKey(for: inputSource) {
                result[shortcutPreferenceKey(for: inputSource)] = legacyKey
            }
        }
    }

    func shortcutMode(for inputSource: InputSource) -> ShortcutTriggerMode {
        let modes = preferences.shortcutModeInputSourceMapping ?? [:]

        if let mode = modes[shortcutPreferenceKey(for: inputSource)] {
            return mode
        }

        if let legacyKey = legacyShortcutPreferenceKey(for: inputSource),
           let mode = modes[legacyKey]
        {
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
        let triggers = preferences.singleModifierTriggerInputSourceMapping ?? [:]

        if let trigger = triggers[shortcutPreferenceKey(for: inputSource)] {
            return trigger
        }

        if let legacyKey = legacyShortcutPreferenceKey(for: inputSource),
           let trigger = triggers[legacyKey]
        {
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

    func modifierCombo(for inputSource: InputSource) -> ModifierCombo? {
        let mapping = preferences.singleModifierInputSourceMapping ?? [:]

        if let combo = mapping[shortcutPreferenceKey(for: inputSource)] {
            return combo
        }

        if let legacyKey = legacyShortcutPreferenceKey(for: inputSource) {
            return mapping[legacyKey]
        }

        return nil
    }

    func modifierCombo(for group: HotKeyGroup) -> ModifierCombo? {
        guard let id = group.id else { return nil }
        return (preferences.singleModifierGroupMapping ?? [:])[id]
    }

    func updateShortcutMode(_ mode: ShortcutTriggerMode, for inputSource: InputSource) {
        let key = shortcutPreferenceKey(for: inputSource)
        let legacyKey = legacyShortcutPreferenceKey(for: inputSource)

        update { preferences in
            var inputSourceModes = preferences.shortcutModeInputSourceMapping ?? [:]
            inputSourceModes[key] = mode
            if let legacyKey {
                inputSourceModes.removeValue(forKey: legacyKey)
            }
            preferences.shortcutModeInputSourceMapping = inputSourceModes

            if mode != .singleModifier {
                var inputSourceMapping = preferences.singleModifierInputSourceMapping ?? [:]
                inputSourceMapping.removeValue(forKey: key)
                if let legacyKey {
                    inputSourceMapping.removeValue(forKey: legacyKey)
                }
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
        let key = shortcutPreferenceKey(for: inputSource)
        let legacyKey = legacyShortcutPreferenceKey(for: inputSource)

        update { preferences in
            var triggerMapping = preferences.singleModifierTriggerInputSourceMapping ?? [:]
            triggerMapping[key] = trigger
            if let legacyKey {
                triggerMapping.removeValue(forKey: legacyKey)
            }
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

    func updateModifierCombo(_ combo: ModifierCombo?, for inputSource: InputSource) {
        let key = shortcutPreferenceKey(for: inputSource)
        let legacyKey = legacyShortcutPreferenceKey(for: inputSource)
        let legacyKeysByPersistentKey = legacyShortcutPreferenceKeysByPersistentKey()

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
                if let legacyKey = legacyKeysByPersistentKey[id],
                   let mode = inputSourceModes[legacyKey]
                {
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

            if let combo = combo {
                let duplicateInputSourceKeys = inputSourceMapping
                    .filter { $0.value == combo && usesSingleModifierInputSource($0.key) }
                    .map(\.key)
                let duplicateGroupKeys = groupMapping
                    .filter { $0.value == combo && usesSingleModifierGroup($0.key) }
                    .map(\.key)

                duplicateInputSourceKeys.forEach { inputSourceMapping.removeValue(forKey: $0) }
                duplicateGroupKeys.forEach { groupMapping.removeValue(forKey: $0) }

                inputSourceMapping[key] = combo
                if let legacyKey {
                    inputSourceMapping.removeValue(forKey: legacyKey)
                }
            } else {
                inputSourceMapping.removeValue(forKey: key)
                if let legacyKey {
                    inputSourceMapping.removeValue(forKey: legacyKey)
                }
            }

            preferences.singleModifierInputSourceMapping = inputSourceMapping
            preferences.singleModifierGroupMapping = groupMapping
        }
    }

    func updateModifierCombo(_ combo: ModifierCombo?, for group: HotKeyGroup) {
        guard let id = group.id else { return }
        let legacyKeysByPersistentKey = legacyShortcutPreferenceKeysByPersistentKey()

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
                if let legacyKey = legacyKeysByPersistentKey[id],
                   let mode = inputSourceModes[legacyKey]
                {
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

            if let combo = combo {
                let duplicateInputSourceKeys = inputSourceMapping
                    .filter { $0.value == combo && usesSingleModifierInputSource($0.key) }
                    .map(\.key)
                let duplicateGroupKeys = groupMapping
                    .filter { $0.value == combo && usesSingleModifierGroup($0.key) }
                    .map(\.key)

                duplicateInputSourceKeys.forEach { inputSourceMapping.removeValue(forKey: $0) }
                duplicateGroupKeys.forEach { groupMapping.removeValue(forKey: $0) }

                groupMapping[id] = combo
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
