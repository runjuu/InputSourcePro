import KeyboardShortcuts
import SwiftUI

struct KeyboardsSettingsView: View {
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "createdAt", ascending: true)])
    var hotKeyGroups: FetchedResults<HotKeyGroup>

    @EnvironmentObject var preferencesVM: PreferencesVM
    @EnvironmentObject var indicatorVM: IndicatorVM
    @EnvironmentObject var permissionsVM: PermissionsVM

    let imgSize: CGFloat = 16
    let shortcutControlColumns: [GridItem] = [
        GridItem(.fixed(120), spacing: 8, alignment: .trailing),
        GridItem(.fixed(160), spacing: 8, alignment: .leading)
    ]
    
    /// Check if any single modifier shortcuts are configured
    private var hasSingleModifierShortcuts: Bool {
        // Check input sources
        for inputSource in InputSource.sources {
            if preferencesVM.shortcutMode(for: inputSource) == .singleModifier,
               preferencesVM.modifierCombo(for: inputSource) != nil {
                return true
            }
        }
        // Check hot key groups
        for group in hotKeyGroups {
            if preferencesVM.shortcutMode(for: group) == .singleModifier,
               preferencesVM.modifierCombo(for: group) != nil {
                return true
            }
        }
        return false
    }
    
    /// Check if accessibility permission is missing
    private var needsAccessibilityPermission: Bool {
        !permissionsVM.isAccessibilityEnabled
    }
    
    /// Check if input monitoring permission is missing
    private var needsInputMonitoringPermission: Bool {
        !permissionsVM.isInputMonitoringEnabled
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Show permission warning if single modifier shortcuts are enabled but permissions are missing
                if hasSingleModifierShortcuts && (needsAccessibilityPermission || needsInputMonitoringPermission) {
                    permissionWarningSection
                }
                
                normalSection
                groupSection
                AddSwitchingGroupButton(onSelect: preferencesVM.addHotKeyGroup)
            }
            .padding()
        }
        .background(NSColor.background1.color)
    }
    
    @ViewBuilder
    var permissionWarningSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    Text("Modifier shortcuts require additional permissions to work reliably.".i18n())
            }
            
            VStack(alignment: .leading, spacing: 12) {
                if needsAccessibilityPermission {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center) {
                            Text("Accessibility".i18n())
                                .fontWeight(.medium)
                            Spacer()
                            Button("Open Accessibility Settings".i18n()) {
                                NSWorkspace.shared.openAccessibilityPreferences()
                            }
                        }
                        Text("Open Accessibility Settings, find \"Input Source Pro\" in the list and enable the toggle.".i18n())
                            .foregroundColor(.secondary)
                    }
                }
                
                if needsInputMonitoringPermission {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center) {
                            Text("Input Monitoring".i18n())
                                .fontWeight(.medium)
                            Spacer()
                            Button("Open Input Monitoring Settings".i18n()) {
                                NSWorkspace.shared.openInputMonitoringPreferences()
                            }
                        }
                        Text("Open Input Monitoring Settings, click the \"+\" button and add \"Input Source Pro\" to the list.".i18n())
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .padding(.bottom)
    }

    var normalSection: some View {
        ForEach(InputSource.sources, id: \.id) { inputSource in
            SettingsSection(title: "") {
                HStack(alignment: .top) {
                    CustomizedIndicatorView(inputSource: inputSource)
                        .help(inputSource.id)

                    Spacer()

                    shortcutControls(
                        mode: preferencesVM.shortcutMode(for: inputSource),
                        modeBinding: shortcutModeBinding(for: inputSource),
                        triggerBinding: singleModifierTriggerBinding(for: inputSource),
                        modifierSelection: preferencesVM.modifierCombo(for: inputSource),
                        onModifierSelect: { selection in
                            preferencesVM.updateModifierCombo(selection, for: inputSource)
                            if let selection, selection.keys.count > 1 {
                                preferencesVM.updateSingleModifierTrigger(.singlePress, for: inputSource)
                            }
                            indicatorVM.refreshShortcut()
                        },
                        recorderId: inputSource.id
                    )
                }
                .padding()
            }
            .padding(.bottom)
        }
    }

    var groupSection: some View {
        ForEach(hotKeyGroups, id: \.self) { group in
            SettingsSection(title: "") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        ForEach(group.inputSources, id: \.id) { inputSource in
                            CustomizedIndicatorView(inputSource: inputSource)
                                .help(inputSource.id)
                        }
                    }

                    Spacer()

                    if let groupId = group.id {
                        VStack(alignment: .trailing, spacing: 8) {
                            shortcutControls(
                                mode: preferencesVM.shortcutMode(for: group),
                                modeBinding: shortcutModeBinding(for: group),
                                triggerBinding: singleModifierTriggerBinding(for: group),
                                modifierSelection: preferencesVM.modifierCombo(for: group),
                                onModifierSelect: { selection in
                                    preferencesVM.updateModifierCombo(selection, for: group)
                                    if let selection, selection.keys.count > 1 {
                                        preferencesVM.updateSingleModifierTrigger(.singlePress, for: group)
                                    }
                                    indicatorVM.refreshShortcut()
                                },
                                recorderId: groupId
                            )
                        }
                    }
                }
                .padding()
                
                Divider()
                
                HStack {
                    Spacer()
                    
                    Button("Delete".i18n()) {
                        deleteGroup(group: group)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .padding(.bottom)
        }
    }

    func modifierComboPicker(
        selection: ModifierCombo?,
        onSelect: @escaping (ModifierCombo?) -> Void
    ) -> some View {
        ModifierComboPicker(
            selection: Binding(
                get: { selection },
                set: { onSelect($0) }
            )
        )
    }

    func shortcutModeBinding(for inputSource: InputSource) -> Binding<ShortcutTriggerMode> {
        Binding(
            get: { preferencesVM.shortcutMode(for: inputSource) },
            set: { newValue in
                preferencesVM.updateShortcutMode(newValue, for: inputSource)
                indicatorVM.refreshShortcut()
            }
        )
    }

    func shortcutModeBinding(for group: HotKeyGroup) -> Binding<ShortcutTriggerMode> {
        Binding(
            get: { preferencesVM.shortcutMode(for: group) },
            set: { newValue in
                preferencesVM.updateShortcutMode(newValue, for: group)
                indicatorVM.refreshShortcut()
            }
        )
    }

    func singleModifierTriggerBinding(for inputSource: InputSource) -> Binding<SingleModifierTrigger> {
        Binding(
            get: { preferencesVM.singleModifierTrigger(for: inputSource) },
            set: { newValue in
                preferencesVM.updateSingleModifierTrigger(newValue, for: inputSource)
                indicatorVM.refreshShortcut()
            }
        )
    }

    func singleModifierTriggerBinding(for group: HotKeyGroup) -> Binding<SingleModifierTrigger> {
        Binding(
            get: { preferencesVM.singleModifierTrigger(for: group) },
            set: { newValue in
                preferencesVM.updateSingleModifierTrigger(newValue, for: group)
                indicatorVM.refreshShortcut()
            }
        )
    }

    @ViewBuilder
    func shortcutControls(
        mode: ShortcutTriggerMode,
        modeBinding: Binding<ShortcutTriggerMode>,
        triggerBinding: Binding<SingleModifierTrigger>,
        modifierSelection: ModifierCombo?,
        onModifierSelect: @escaping (ModifierCombo?) -> Void,
        recorderId: String
    ) -> some View {
        let isComboSelection = (modifierSelection?.keys.count ?? 0) > 1
        let triggerOptions = isComboSelection
            ? [SingleModifierTrigger.singlePress]
            : SingleModifierTrigger.allCases

        VStack(alignment: .trailing, spacing: 8) {
            LazyVGrid(columns: shortcutControlColumns, alignment: .leading, spacing: 6) {
                Text("Shortcut Type".i18n())
                Picker("Shortcut Type".i18n(), selection: modeBinding) {
                    ForEach(ShortcutTriggerMode.allCases) { option in
                        Text(option.name).tag(option)
                    }
                }
                .labelsHidden()
                .flexibleButtonSizing()

                if mode == .keyboardShortcut {
                    Text("Shortcut".i18n())
                    KeyboardShortcuts.Recorder(for: .init(recorderId), onChange: { _ in
                        indicatorVM.refreshShortcut()
                    })
                } else {
                    Text("Shortcut".i18n())
                    modifierComboPicker(
                        selection: modifierSelection,
                        onSelect: onModifierSelect
                    )
                    .flexibleButtonSizing()

                    Text("Trigger".i18n())
                    Picker("Trigger".i18n(), selection: triggerBinding) {
                        ForEach(triggerOptions) { option in
                            Text(option.name).tag(option)
                        }
                    }
                    .labelsHidden()
                    .flexibleButtonSizing()
                    .disabled(isComboSelection)
                }
            }
            
            // Show warning outside the grid so it spans full width
            if mode == .singleModifier && modifierSelection != nil && (needsAccessibilityPermission || needsInputMonitoringPermission) {
                Text("Disabled until permissions are granted".i18n())
                                        .foregroundColor(.orange)
            }
        }
        .onChange(of: modifierSelection?.keys.count ?? 0) { newCount in
            if newCount > 1 && triggerBinding.wrappedValue != .singlePress {
                triggerBinding.wrappedValue = .singlePress
            }
        }
    }

    func deleteGroup(group: HotKeyGroup) {
        KeyboardShortcuts.reset([.init(group.id!)])
        preferencesVM.deleteHotKeyGroup(group)
        indicatorVM.refreshShortcut()
    }
}
