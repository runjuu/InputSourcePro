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
        GridItem(.fixed(160), spacing: 8, alignment: .trailing)
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
        // Check function keys toggle
        if preferencesVM.functionKeysToggleMode() == .singleModifier,
           preferencesVM.functionKeysToggleCombo() != nil {
            return true
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

                functionKeysToggleSection
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

    /// The function-key mode the indicator is currently enforcing (per-app rule,
    /// default, or shortcut override), falling back to the stored default before the
    /// VM has applied a mode. Mirrors what the indicator badge shows.
    private var currentFunctionKeyMode: FKeyMode {
        indicatorVM.currentFKeyMode ?? preferencesVM.preferences.functionKeyMode
    }

    var functionKeysToggleSection: some View {
        SettingsSection(title: "Function Keys") {
            HStack(alignment: .top) {
                HStack(spacing: 8) {
                    // Render the real indicator badge — the exact AppKit view the live
                    // indicator shows when toggling the mode (same config as
                    // IndicatorWindowController+Indicator) — so this chip can't drift from it.
                    DumpIndicatorView(config: IndicatorViewConfig(
                        inputSource: indicatorVM.state.inputSource,
                        kind: preferencesVM.preferences.indicatorKind,
                        size: preferencesVM.preferences.indicatorSize ?? .medium,
                        bgColor: nil,
                        textColor: preferencesVM.defaultIndicatorTextNSColor,
                        prefersTextInputSourceIcons: preferencesVM.preferences.prefersTextInputSourceIcons,
                        badge: .init(
                            glyph: currentFunctionKeyMode.badgeGlyph,
                            title: currentFunctionKeyMode.displayName
                        )
                    ))

                    QuestionMark {
                        Text("Toggle Function Keys Description".i18n())
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 220, alignment: .leading)
                            .padding(12)
                    }
                }

                Spacer()

                shortcutControls(
                    modeBinding: functionKeysToggleModeBinding(),
                    triggerBinding: functionKeysToggleTriggerBinding(),
                    modifierSelection: preferencesVM.functionKeysToggleCombo(),
                    onModifierSelect: { selection in
                        preferencesVM.updateFunctionKeysToggleCombo(selection)
                        if let selection, selection.keys.count > 1 {
                            preferencesVM.updateFunctionKeysToggleTrigger(.singlePress)
                        }
                        indicatorVM.refreshShortcut()
                    },
                    recorderId: PreferencesVM.functionKeysToggleShortcutId
                )
            }
            .padding()
        }
        .padding(.bottom)
    }

    var normalSection: some View {
        ForEach(Array(InputSource.sources.enumerated()), id: \.element.persistentIdentifier) { index, inputSource in
            SettingsSection(title: index == 0 ? "Input Sources" : "") {
                HStack(alignment: .top) {
                    CustomizedIndicatorView(inputSource: inputSource)
                        .help(inputSource.persistentIdentifier)

                    Spacer()

                    shortcutControls(
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
                        recorderId: inputSource.persistentIdentifier
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
                        ForEach(group.inputSources, id: \.persistentIdentifier) { inputSource in
                            CustomizedIndicatorView(inputSource: inputSource)
                                .help(inputSource.persistentIdentifier)
                        }
                    }

                    Spacer()

                    if let groupId = group.id {
                        VStack(alignment: .trailing, spacing: 8) {
                            shortcutControls(
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

    func functionKeysToggleModeBinding() -> Binding<ShortcutTriggerMode> {
        Binding(
            get: { preferencesVM.functionKeysToggleMode() },
            set: { newValue in
                preferencesVM.updateFunctionKeysToggleMode(newValue)
                indicatorVM.refreshShortcut()
            }
        )
    }

    func functionKeysToggleTriggerBinding() -> Binding<SingleModifierTrigger> {
        Binding(
            get: { preferencesVM.functionKeysToggleTrigger() },
            set: { newValue in
                preferencesVM.updateFunctionKeysToggleTrigger(newValue)
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
        modeBinding: Binding<ShortcutTriggerMode>,
        triggerBinding: Binding<SingleModifierTrigger>,
        modifierSelection: ModifierCombo?,
        onModifierSelect: @escaping (ModifierCombo?) -> Void,
        recorderId: String
    ) -> some View {
        ShortcutControlsRow(
            mode: modeBinding,
            trigger: triggerBinding,
            modifierSelection: modifierSelection,
            onModifierSelect: onModifierSelect,
            recorderId: recorderId,
            groups: Array(hotKeyGroups),
            needsAccessibilityPermission: needsAccessibilityPermission,
            needsInputMonitoringPermission: needsInputMonitoringPermission,
            shortcutControlColumns: shortcutControlColumns
        )
        .id(recorderId)
    }

    func deleteGroup(group: HotKeyGroup) {
        if let id = group.id, !id.isEmpty {
            KeyboardShortcuts.reset([.init(id)])
        }
        preferencesVM.deleteHotKeyGroup(group)
        indicatorVM.refreshShortcut()
    }
}

private struct ShortcutControlsRow: View {
    @EnvironmentObject var indicatorVM: IndicatorVM
    @EnvironmentObject var preferencesVM: PreferencesVM

    @Binding var mode: ShortcutTriggerMode
    @Binding var trigger: SingleModifierTrigger
    let modifierSelection: ModifierCombo?
    let onModifierSelect: (ModifierCombo?) -> Void
    let recorderId: String
    let groups: [HotKeyGroup]
    let needsAccessibilityPermission: Bool
    let needsInputMonitoringPermission: Bool
    let shortcutControlColumns: [GridItem]

    @State private var lastAcceptedKeyboardShortcut: KeyboardShortcuts.Shortcut?
    @State private var conflictOwnerName: String?

    var body: some View {
        let isComboSelection = (modifierSelection?.keys.count ?? 0) > 1
        let triggerOptions = isComboSelection
            ? [SingleModifierTrigger.singlePress]
            : SingleModifierTrigger.allCases

        VStack(alignment: .trailing, spacing: 8) {
            LazyVGrid(columns: shortcutControlColumns, alignment: .trailing, spacing: 6) {
                Text("Shortcut Type".i18n())
                Picker("Shortcut Type".i18n(), selection: validatedModeBinding) {
                    ForEach(ShortcutTriggerMode.allCases) { option in
                        Text(option.name).tag(option)
                    }
                }
                .labelsHidden()
                .flexibleButtonSizing()

                if mode == .keyboardShortcut {
                    Text("Shortcut".i18n())
                    LiveShortcutRecorder(name: .init(recorderId), onChange: handleKeyboardShortcutChange)
                } else {
                    Text("Shortcut".i18n())
                    ModifierComboPicker(
                        selection: Binding(
                            get: { modifierSelection },
                            set: { handleModifierSelect($0) }
                        )
                    )
                    .flexibleButtonSizing()

                    Text("Trigger".i18n())
                    Picker("Trigger".i18n(), selection: $trigger) {
                        ForEach(triggerOptions) { option in
                            Text(option.name).tag(option)
                        }
                    }
                    .labelsHidden()
                    .flexibleButtonSizing()
                    .disabled(isComboSelection)
                }
            }

            if let conflictOwnerName {
                Text(ShortcutConflict.message(with: conflictOwnerName))
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
            }

            if mode == .singleModifier && modifierSelection != nil && (needsAccessibilityPermission || needsInputMonitoringPermission) {
                Text("Disabled until permissions are granted".i18n())
                    .foregroundColor(.orange)
            }
        }
        .onAppear {
            reloadAcceptedKeyboardShortcut()
        }
        .onReceive(preferencesVM.runtimeRuleChanges) { _ in
            // Imports can replace shortcuts while this row remains on screen.
            // The notification arrives after all imported shortcuts are saved.
            reloadAcceptedKeyboardShortcut()
            conflictOwnerName = nil
        }
        .onChange(of: mode) { _ in
            conflictOwnerName = nil
        }
        .onChange(of: modifierSelection?.keys.count ?? 0) { newCount in
            if newCount > 1 && trigger != .singlePress {
                trigger = .singlePress
            }
        }
    }

    private func reloadAcceptedKeyboardShortcut() {
        lastAcceptedKeyboardShortcut = KeyboardShortcuts.getShortcut(for: .init(recorderId))
    }

    private var validatedModeBinding: Binding<ShortcutTriggerMode> {
        Binding(
            get: { mode },
            set: { newMode in
                conflictOwnerName = ShortcutConflict.updateMode(
                    newMode,
                    currentId: recorderId,
                    keyboardShortcut: KeyboardShortcuts.getShortcut(for: .init(recorderId)),
                    modifierCombo: modifierSelection,
                    keyboardAssignments: ShortcutConflict.keyboardAssignments(
                        preferencesVM: preferencesVM,
                        groups: groups
                    ),
                    modifierAssignments: ShortcutConflict.modifierAssignments(
                        preferencesVM: preferencesVM,
                        groups: groups
                    ),
                    apply: { mode = $0 }
                )
            }
        )
    }

    private func handleKeyboardShortcutChange(_ shortcut: KeyboardShortcuts.Shortcut?) {
        let assignments = ShortcutConflict.keyboardAssignments(
            preferencesVM: preferencesVM,
            groups: groups
        )
        let decision = ShortcutConflict.resolve(
            proposed: shortcut,
            currentId: recorderId,
            lastAccepted: lastAcceptedKeyboardShortcut,
            assignments: assignments
        )

        ShortcutConflict.persistKeyboardShortcut(
            proposed: shortcut,
            currentId: recorderId,
            decision: decision,
            assignments: assignments
        )

        if let ownerName = decision.conflictOwnerName {
            conflictOwnerName = ownerName
        } else {
            conflictOwnerName = nil
            lastAcceptedKeyboardShortcut = decision.accepted
        }

        indicatorVM.refreshShortcut()
    }

    private func handleModifierSelect(_ selection: ModifierCombo?) {
        let decision = ShortcutConflict.resolve(
            proposed: selection,
            currentId: recorderId,
            lastAccepted: modifierSelection,
            assignments: ShortcutConflict.modifierAssignments(
                preferencesVM: preferencesVM,
                groups: groups
            )
        )

        if let ownerName = decision.conflictOwnerName {
            conflictOwnerName = ownerName
            return
        }

        conflictOwnerName = nil
        onModifierSelect(decision.accepted)
    }
}

/// `KeyboardShortcuts.Recorder` only stores `onChange` in `makeNSView`.
/// Keep the callback on a class so later recordings see current assignments.
private struct LiveShortcutRecorder: NSViewRepresentable {
    let name: KeyboardShortcuts.Name
    let onChange: (KeyboardShortcuts.Shortcut?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> KeyboardShortcuts.RecorderCocoa {
        KeyboardShortcuts.RecorderCocoa(for: name) { shortcut in
            context.coordinator.onChange(shortcut)
        }
    }

    func updateNSView(_ nsView: KeyboardShortcuts.RecorderCocoa, context: Context) {
        nsView.shortcutName = name
        context.coordinator.onChange = onChange
    }

    final class Coordinator {
        var onChange: (KeyboardShortcuts.Shortcut?) -> Void

        init(onChange: @escaping (KeyboardShortcuts.Shortcut?) -> Void) {
            self.onChange = onChange
        }
    }
}
