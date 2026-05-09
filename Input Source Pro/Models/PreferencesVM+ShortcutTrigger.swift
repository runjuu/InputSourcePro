import Foundation
import KeyboardShortcuts

extension PreferencesVM {
    private func shortcutPreferenceKey(for inputSource: InputSource) -> String {
        return inputSource.persistentIdentifier
    }

    private func legacyShortcutPreferenceKey(for inputSource: InputSource) -> String? {
        let key = shortcutPreferenceKey(for: inputSource)
        return key == inputSource.id ? nil : inputSource.id
    }

    private func inputSourceShortcutPreferenceKeyNormalizer() -> (String) -> String {
        let inputSources = InputSource.sources
        let persistentKeys = Set(inputSources.map(\.persistentIdentifier))
        var targetByLegacyKey = [String: String]()

        for inputSource in inputSources {
            guard inputSource.persistentIdentifier != inputSource.id else { continue }

            // If the source id is still a current persistent key, keep it bound to
            // that source instead of migrating it to one of the mode-specific rows.
            if !persistentKeys.contains(inputSource.id), targetByLegacyKey[inputSource.id] == nil {
                targetByLegacyKey[inputSource.id] = inputSource.persistentIdentifier
            }

            if let inputModeID = inputSource.inputModeID,
               !persistentKeys.contains(inputModeID),
               targetByLegacyKey[inputModeID] == nil
            {
                targetByLegacyKey[inputModeID] = inputSource.persistentIdentifier
            }
        }

        return { key in
            if persistentKeys.contains(key) {
                return key
            }

            return targetByLegacyKey[key] ?? key
        }
    }

    private func normalizedInputSourceShortcutMapping<Value>(
        _ mapping: [String: Value],
        normalizeKey: (String) -> String
    ) -> [String: Value] {
        mapping.reduce(into: [:]) { result, entry in
            let normalizedKey = normalizeKey(entry.key)

            if result[normalizedKey] == nil || normalizedKey == entry.key {
                result[normalizedKey] = entry.value
            }
        }
    }

    func migrateShortcutPreferencesIfNeed() {
        let normalizeKey = inputSourceShortcutPreferenceKeyNormalizer()
        migrateKeyboardShortcutNames(normalizeKey: normalizeKey)

        update { preferences in
            preferences.shortcutModeInputSourceMapping = normalizedInputSourceShortcutMapping(
                preferences.shortcutModeInputSourceMapping ?? [:],
                normalizeKey: normalizeKey
            )
            preferences.singleModifierTriggerInputSourceMapping = normalizedInputSourceShortcutMapping(
                preferences.singleModifierTriggerInputSourceMapping ?? [:],
                normalizeKey: normalizeKey
            )
            preferences.singleModifierInputSourceMapping = normalizedInputSourceShortcutMapping(
                preferences.singleModifierInputSourceMapping ?? [:],
                normalizeKey: normalizeKey
            )
        }
    }

    private func migrateKeyboardShortcutNames(normalizeKey: (String) -> String) {
        let inputSources = InputSource.sources
        let persistentKeys = Set(inputSources.map(\.persistentIdentifier))
        let legacyKeys = Set(inputSources.map(\.id)).subtracting(persistentKeys)

        for legacyKey in legacyKeys {
            let targetKey = normalizeKey(legacyKey)
            guard targetKey != legacyKey else { continue }

            let legacyName = KeyboardShortcuts.Name(legacyKey)
            let targetName = KeyboardShortcuts.Name(targetKey)

            guard let legacyShortcut = KeyboardShortcuts.getShortcut(for: legacyName)
            else { continue }

            if KeyboardShortcuts.getShortcut(for: targetName) == nil {
                KeyboardShortcuts.setShortcut(legacyShortcut, for: targetName)
            }
            KeyboardShortcuts.setShortcut(nil, for: legacyName)
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
        let normalizeInputSourceKey = inputSourceShortcutPreferenceKeyNormalizer()

        update { preferences in
            var inputSourceMapping = preferences.singleModifierInputSourceMapping ?? [:]
            var groupMapping = preferences.singleModifierGroupMapping ?? [:]
            let inputSourceModes = preferences.shortcutModeInputSourceMapping ?? [:]
            let normalizedInputSourceModes = normalizedInputSourceShortcutMapping(
                inputSourceModes,
                normalizeKey: normalizeInputSourceKey
            )
            let groupModes = preferences.shortcutModeGroupMapping ?? [:]
            let fallbackMode = preferences.shortcutTriggerMode ?? .keyboardShortcut

            func usesSingleModifierInputSource(_ id: String) -> Bool {
                let normalizedID = normalizeInputSourceKey(id)

                if let mode = normalizedInputSourceModes[normalizedID] {
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
        let normalizeInputSourceKey = inputSourceShortcutPreferenceKeyNormalizer()

        update { preferences in
            var inputSourceMapping = preferences.singleModifierInputSourceMapping ?? [:]
            var groupMapping = preferences.singleModifierGroupMapping ?? [:]
            let inputSourceModes = preferences.shortcutModeInputSourceMapping ?? [:]
            let normalizedInputSourceModes = normalizedInputSourceShortcutMapping(
                inputSourceModes,
                normalizeKey: normalizeInputSourceKey
            )
            let groupModes = preferences.shortcutModeGroupMapping ?? [:]
            let fallbackMode = preferences.shortcutTriggerMode ?? .keyboardShortcut

            func usesSingleModifierInputSource(_ id: String) -> Bool {
                let normalizedID = normalizeInputSourceKey(id)

                if let mode = normalizedInputSourceModes[normalizedID] {
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
