import SwiftUI

// 新增 ToggleLabel 组件
struct ToggleLabel: View {
    let systemImageName: String
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImageName)
            Text(text)
        }
    }
}

struct ApplicationDetail: View {
    @Binding var selectedApp: Set<AppRule>

    @EnvironmentObject var preferencesVM: PreferencesVM

    @State var forceKeyboard: PickerItem?
    @State var doRestoreKeyboardState = NSToggleViewState.off
    @State var doNotRestoreKeyboardState = NSToggleViewState.off
    @State var hideIndicator = NSToggleViewState.off
    @State var forceAsciiPunctuation = NSToggleViewState.off

    var mixed: Bool {
        Set(selectedApp.map { $0.forcedKeyboard?.id }).count > 1
    }

    var items: [PickerItem] {
        [mixed ? PickerItem.mixed : nil, PickerItem.empty].compactMap { $0 }
            + InputSource.sources.map { PickerItem(id: $0.id, title: $0.name, toolTip: $0.id) }
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
                Text("Keyboard Restore Strategy".i18n())
                    .fontWeight(.medium)

                HStack {
                    Image(systemName: "d.circle.fill")
                        .foregroundColor(.green)
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
                    Image(systemName: "arrow.uturn.left.circle.fill")
                        .foregroundColor(.blue)
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
                    Image(systemName: "eye.slash.circle.fill")
                        .foregroundColor(.gray)
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
                Text("ASCII Punctuation".i18n())
                    .fontWeight(.medium)
                HStack {
                    Image(systemName: "textformat.abc")
                        .foregroundColor(.orange)
                    NSToggleView(
                        label: "Force ASCII Punctuation".i18n(),
                        state: forceAsciiPunctuation,
                        onStateUpdate: handleToggleForceAsciiPunctuation
                    )
                    .fixedSize()
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
            updateForceAsciiPunctuationState()
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

    func updateForceAsciiPunctuationState() {
        let stateSet = Set(selectedApp.map { $0.forceAsciiPunctuation })

        if stateSet.count > 1 {
            forceAsciiPunctuation = .mixed
        } else {
            forceAsciiPunctuation = stateSet.first == true ? .on : .off
        }
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

    func handleToggleForceAsciiPunctuation() -> NSControl.StateValue {
        switch forceAsciiPunctuation {
        case .on:
            selectedApp.forEach { preferencesVM.setForceAsciiPunctuation($0, false) }
            forceAsciiPunctuation = .off
            return .off
        case .off, .mixed:
            selectedApp.forEach { preferencesVM.setForceAsciiPunctuation($0, true) }
            forceAsciiPunctuation = .on
            return .on
        }
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
