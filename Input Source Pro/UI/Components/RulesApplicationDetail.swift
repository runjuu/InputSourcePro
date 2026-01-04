import SwiftUI

// 新增 ToggleLabel 组件
private enum RulesApplicationDetailIconStyle {
    static let size: CGFloat = 16
    static var imageFont: Font { .system(size: size) }
    static var textFont: Font { .system(size: size, weight: .regular, design: .rounded) }
}

private struct RulesApplicationDetailIcon: View {
    enum Content {
        case system(String)
        case text(String)
    }

    let content: Content
    let color: Color

    init(systemName: String, color: Color = .primary) {
        content = .system(systemName)
        self.color = color
    }

    init(text: String, color: Color = .primary) {
        content = .text(text)
        self.color = color
    }

    var body: some View {
        Group {
            switch content {
            case .system(let name):
                Image(systemName: name)
                    .font(RulesApplicationDetailIconStyle.imageFont)
            case .text(let value):
                Text(value)
                    .font(RulesApplicationDetailIconStyle.textFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .foregroundColor(color)
        .frame(
            width: RulesApplicationDetailIconStyle.size,
            height: RulesApplicationDetailIconStyle.size,
            alignment: .center
        )
    }
}

struct ToggleLabel: View {
    let systemImageName: String
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            RulesApplicationDetailIcon(systemName: systemImageName)
            Text(text)
        }
    }
}

struct ApplicationDetail: View {
    @Binding var selectedApp: Set<AppRule>

    @EnvironmentObject var preferencesVM: PreferencesVM
    @EnvironmentObject var permissionsVM: PermissionsVM

    @State var forceKeyboard: PickerItem?
    @State var doRestoreKeyboardState = NSToggleViewState.off
    @State var doNotRestoreKeyboardState = NSToggleViewState.off
    @State var hideIndicator = NSToggleViewState.off
    @State var forceEnglishPunctuation = NSToggleViewState.off
    @State var functionKeyModeItem: PickerItem?

    var mixed: Bool {
        Set(selectedApp.map { $0.forcedKeyboard?.id }).count > 1
    }

    var isFunctionKeyModeMixed: Bool {
        Set(selectedApp.map { $0.functionKeyMode }).count > 1
    }

    var items: [PickerItem] {
        [mixed ? PickerItem.mixed : nil, PickerItem.empty].compactMap { $0 }
            + InputSource.sources.map { PickerItem(id: $0.id, title: $0.name, toolTip: $0.id) }
    }

    var functionKeyItems: [PickerItem] {
        [isFunctionKeyModeMixed ? PickerItem.mixed : nil, functionKeyDefaultItem].compactMap { $0 }
            + functionKeyOptionItems
    }

    var functionKeyDefaultItem: PickerItem {
        PickerItem(id: "default", title: "Use Global Setting".i18n(), toolTip: nil)
    }

    var functionKeyOptionItems: [PickerItem] {
        [
            PickerItem(id: FKeyMode.functionKeys.rawValue, title: "Use Function Keys".i18n(), toolTip: nil),
            PickerItem(id: FKeyMode.mediaKeys.rawValue, title: "Use Media Keys".i18n(), toolTip: nil),
        ]
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(String(format: "%@ App(s) Selected".i18n(), "\(selectedApp.count)"))
                .font(.subheadline.monospacedDigit())
                .opacity(0.5)
                .padding(.bottom, 5)

            VStack(alignment: .leading) {
                Text("Default Keyboard".i18n())
                    .fontWeight(.medium)

                PopUpButtonPicker<PickerItem?>(
                    items: items,
                    isItemEnabled: { $0?.id != "mixed" },
                    isItemSelected: { $0 == forceKeyboard },
                    getTitle: { $0?.title ?? "" },
                    getToolTip: { $0?.toolTip },
                    onSelect: handleSelect
                )
            }

            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading) {
                Text("Function Keys".i18n())
                    .fontWeight(.medium)

                PopUpButtonPicker<PickerItem?>(
                    items: functionKeyItems,
                    isItemEnabled: { $0?.id != "mixed" },
                    isItemSelected: { $0 == functionKeyModeItem },
                    getTitle: { $0?.title ?? "" },
                    getToolTip: { $0?.toolTip },
                    onSelect: handleSelectFunctionKeyMode
                )
            }

            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading) {
                Text("Keyboard Restore Strategy".i18n())
                    .fontWeight(.medium)

                HStack {
                    RulesApplicationDetailIcon(systemName: "d.circle.fill", color: .green)
                    NSToggleView(
                        label: restoreStrategyName(strategy: .UseDefaultKeyboardInstead),
                        state: preferencesVM.preferences.isRestorePreviouslyUsedInputSource
                            ? doNotRestoreKeyboardState
                            : .on,
                        onStateUpdate: handleToggleDoNotRestoreKeyboard
                    )
                    .fixedSize()
                    .disabled(!preferencesVM.preferences.isRestorePreviouslyUsedInputSource)
                }

                HStack {
                    RulesApplicationDetailIcon(systemName: "arrow.uturn.left.circle.fill", color: .blue)
                    NSToggleView(
                        label: restoreStrategyName(strategy: .RestorePreviouslyUsedOne),
                        state: preferencesVM.preferences.isRestorePreviouslyUsedInputSource
                            ? .on
                            : doRestoreKeyboardState,
                        onStateUpdate: handleToggleDoRestoreKeyboard
                    )
                    .fixedSize()
                    .disabled(preferencesVM.preferences.isRestorePreviouslyUsedInputSource)
                }
            }

            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading) {
                Text("Indicator".i18n())
                    .fontWeight(.medium)
                HStack {
                    RulesApplicationDetailIcon(systemName: "eye.slash.circle.fill", color: .gray)
                    NSToggleView(
                        label: "Hide Indicator".i18n(),
                        state: hideIndicator,
                        onStateUpdate: handleToggleHideIndicator
                    )
                    .fixedSize()
                }
            }

            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading) {
                HStack {
                    Text("Punctuation".i18n())
                        .fontWeight(.medium)
                    Spacer()
                    EnhancedModeRequiredBadge()
                }
                
                HStack {
                    RulesApplicationDetailIcon(text: "Aa", color: .orange)
                    NSToggleView(
                        label: "Force English Punctuation".i18n(),
                        state: forceEnglishPunctuation,
                        onStateUpdate: handleToggleForceEnglishPunctuation
                    )
                    .fixedSize()
                    .disabled(!preferencesVM.preferences.isEnhancedModeEnabled)
                }
                
                if selectedApp.contains(where: { $0.forceEnglishPunctuation }) && !PermissionsVM.checkInputMonitoring(prompt: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This feature requires input monitoring permission to work".i18n())

                        HStack {
                            Spacer()
                            Button("Open Permission Settings".i18n()) {
                                NSWorkspace.shared.openInputMonitoringPreferences()
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(NSColor.background1.color)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.top)
                }
            }

            if selectedApp.contains(where: { preferencesVM.needDisplayEnhancedModePrompt(bundleIdentifier: $0.bundleId) }) {
                Divider().padding(.vertical, 4)

                EnhancedModeRequiredBadge()
            }

            Spacer()
        }
        .disabled(selectedApp.isEmpty)
        .onChange(of: selectedApp) { _ in
            updateForceKeyboardId()
            updateDoRestoreKeyboardState()
            updateDoNotRestoreKeyboardState()
            updateHideIndicatorState()
            updateForceEnglishPunctuationState()
            updateFunctionKeyModeItem()
        }
    }

    func updateForceKeyboardId() {
        if mixed {
            forceKeyboard = PickerItem.mixed
        } else if let keyboard = selectedApp.first?.forcedKeyboard {
            forceKeyboard = PickerItem(id: keyboard.id, title: keyboard.name, toolTip: keyboard.id)
        } else {
            forceKeyboard = PickerItem.empty
        }
    }

    func updateDoRestoreKeyboardState() {
        let stateSet = Set(selectedApp.map { $0.doRestoreKeyboard })

        if stateSet.count > 1 {
            doRestoreKeyboardState = .mixed
        } else {
            doRestoreKeyboardState = stateSet.first == true ? .on : .off
        }
    }

    func updateDoNotRestoreKeyboardState() {
        let stateSet = Set(selectedApp.map { $0.doNotRestoreKeyboard })

        if stateSet.count > 1 {
            doNotRestoreKeyboardState = .mixed
        } else {
            doNotRestoreKeyboardState = stateSet.first == true ? .on : .off
        }
    }

    func updateHideIndicatorState() {
        let stateSet = Set(selectedApp.map { $0.hideIndicator })

        if stateSet.count > 1 {
            hideIndicator = .mixed
        } else {
            hideIndicator = stateSet.first == true ? .on : .off
        }
    }

    func updateForceEnglishPunctuationState() {
        let stateSet = Set(selectedApp.map { $0.forceEnglishPunctuation })

        if stateSet.count > 1 {
            forceEnglishPunctuation = .mixed
        } else {
            forceEnglishPunctuation = stateSet.first == true ? .on : .off
        }
    }

    func updateFunctionKeyModeItem() {
        let modeSet = Set(selectedApp.map { $0.functionKeyMode })

        if modeSet.count > 1 {
            functionKeyModeItem = PickerItem.mixed
            return
        }

        guard let mode = modeSet.first ?? nil else {
            functionKeyModeItem = functionKeyDefaultItem
            return
        }

        functionKeyModeItem = functionKeyItem(for: mode)
    }

    func handleSelect(_ index: Int) {
        forceKeyboard = items[index]

        for app in selectedApp {
            preferencesVM.setForceKeyboard(app, forceKeyboard?.id)
        }
    }

    func handleToggleDoNotRestoreKeyboard() -> NSControl.StateValue {
        switch doNotRestoreKeyboardState {
        case .on:
            selectedApp.forEach { preferencesVM.setDoNotRestoreKeyboard($0, false) }
            doNotRestoreKeyboardState = .off
            return .off
        case .off, .mixed:
            selectedApp.forEach { preferencesVM.setDoNotRestoreKeyboard($0, true) }
            doNotRestoreKeyboardState = .on
            return .on
        }
    }

    func handleToggleDoRestoreKeyboard() -> NSControl.StateValue {
        switch doRestoreKeyboardState {
        case .on:
            selectedApp.forEach { preferencesVM.setDoRestoreKeyboard($0, false) }
            doRestoreKeyboardState = .off
            return .off
        case .off, .mixed:
            selectedApp.forEach { preferencesVM.setDoRestoreKeyboard($0, true) }
            doRestoreKeyboardState = .on
            return .on
        }
    }

    func handleToggleHideIndicator() -> NSControl.StateValue {
        switch hideIndicator {
        case .on:
            selectedApp.forEach { preferencesVM.setHideIndicator($0, false) }
            hideIndicator = .off
            return .off
        case .off, .mixed:
            selectedApp.forEach { preferencesVM.setHideIndicator($0, true) }
            hideIndicator = .on
            return .on
        }
    }

    func handleToggleForceEnglishPunctuation() -> NSControl.StateValue {
        switch forceEnglishPunctuation {
        case .on:
            selectedApp.forEach { preferencesVM.setForceEnglishPunctuation($0, false) }
            forceEnglishPunctuation = .off
            return .off
        case .off, .mixed:
            selectedApp.forEach { preferencesVM.setForceEnglishPunctuation($0, true) }
            forceEnglishPunctuation = .on
            
            if !PermissionsVM.checkInputMonitoring(prompt: false) {
                PermissionsVM.checkInputMonitoring(prompt: true)
            }
            return .on
        }
    }

    func handleSelectFunctionKeyMode(_ index: Int) {
        let selection = functionKeyItems[index]
        functionKeyModeItem = selection

        let mode: FKeyMode?

        switch selection.id {
        case functionKeyDefaultItem.id:
            mode = nil
        case FKeyMode.functionKeys.rawValue:
            mode = .functionKeys
        case FKeyMode.mediaKeys.rawValue:
            mode = .mediaKeys
        default:
            mode = nil
        }

        selectedApp.forEach { preferencesVM.setFunctionKeyMode($0, mode) }
    }

    func functionKeyItem(for mode: FKeyMode) -> PickerItem {
        functionKeyOptionItems.first(where: { $0.id == mode.rawValue }) ?? functionKeyDefaultItem
    }

    func restoreStrategyName(strategy: KeyboardRestoreStrategy) -> String {
        strategy.name + restoreStrategyTips(strategy: strategy)
    }

    func restoreStrategyTips(strategy: KeyboardRestoreStrategy) -> String {
        switch strategy {
        case .RestorePreviouslyUsedOne:
            return preferencesVM.preferences.isRestorePreviouslyUsedInputSource ? " (\("Default".i18n()))" : ""
        case .UseDefaultKeyboardInstead:
            return !preferencesVM.preferences.isRestorePreviouslyUsedInputSource ? " (\("Default".i18n()))" : ""
        }
    }
}
