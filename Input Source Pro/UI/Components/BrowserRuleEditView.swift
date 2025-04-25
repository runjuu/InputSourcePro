import SwiftUI

struct BrowserRuleEditView: View {
    @State var value: String = ""
    @State var sampleValue: String = ""
    @State var ruleType = BrowserRuleType.domainSuffix
    @State var inputSourceItem = PickerItem.empty
    @State var restoreStrategyItem = PickerItem.empty
    @State var hideIndicator = false

    @State var isPopover = false

    @State private var width = CGFloat.zero

    @Binding var isPresented: Bool

    @EnvironmentObject var preferencesVM: PreferencesVM

    let rule: BrowserRule?

    var ruleTypes: [BrowserRuleType] {
        BrowserRuleType.allCases
    }

    var inputSourceItems: [PickerItem] {
        [PickerItem.empty]
            + InputSource.sources.map { PickerItem(id: $0.id, title: $0.name, toolTip: $0.id) }
    }

    var restoreStrategyItems: [PickerItem] {
        [PickerItem.empty]
            + KeyboardRestoreStrategy.allCases.map { PickerItem(id: $0.rawValue, title: $0.name, toolTip: nil) }
    }

    var sampleURL: URL? {
        guard !sampleValue.isEmpty else { return nil }

        if sampleValue.starts(with: "http://") || sampleValue.starts(with: "https://") {
            return URL(string: sampleValue)
        } else {
            return URL(string: "http://\(sampleValue)")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Match".i18n().uppercased())
                    .font(.footnote)
                    .fontWeight(.medium)
                    .opacity(0.5)

                VStack {
                    HStack {
                        Text("Sample URL".i18n() + ":")
                            .alignedView(width: $width, alignment: .trailing)
                        TextField("https://www.twitter.com/runjuuu", text: $sampleValue)
                    }

                    HStack {
                        Text("Rule Type".i18n() + ":")
                            .alignedView(width: $width, alignment: .trailing)
                        HStack {
                            PopUpButtonPicker<BrowserRuleType>(
                                items: ruleTypes,
                                isItemSelected: { $0 == ruleType },
                                getTitle: { $0.name },
                                getToolTip: { $0.explanation },
                                onSelect: handleSelectRule
                            )

                            Button(action: { isPopover.toggle() }) {
                                SwiftUI.Image(systemName: "questionmark")
                            }
                            .font(.system(size: 10).weight(.bold))
                            .frame(width: 18, height: 18)
                            .cornerRadius(99)
                            .popover(
                                isPresented: self.$isPopover,
                                arrowEdge: .bottom
                            ) {
                                VStack {
                                    Text(.init(ruleType.explanation))
                                        .lineSpacing(3)
                                }
                                .frame(width: 280)
                                .padding()
                            }
                        }
                    }

                    HStack {
                        Text("Domain".i18n() + ":")
                            .alignedView(width: $width, alignment: .trailing)
                        HStack {
                            TextField("twitter.com", text: $value)
                            if let url = sampleURL, !value.isEmpty {
                                if BrowserRule.validate(type: ruleType, url: url, value: value) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .frame(width: 18, height: 18)
                                } else {
                                    Image(systemName: "x.circle.fill")
                                        .foregroundColor(.red)
                                        .frame(width: 18, height: 18)
                                }
                            }
                        }
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
                .padding(.bottom)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Keyboard".i18n().uppercased())
                    .font(.footnote)
                    .fontWeight(.medium)
                    .opacity(0.5)

                VStack {
                    HStack {
                        Text("Default Keyboard".i18n() + ":")
                            .alignedView(width: $width, alignment: .trailing)
                        PopUpButtonPicker<PickerItem?>(
                            items: inputSourceItems,
                            isItemSelected: { $0 == inputSourceItem },
                            getTitle: { $0?.title ?? "" },
                            getToolTip: { $0?.toolTip },
                            onSelect: handleSelectInputSource
                        )
                    }

                    HStack {
                        Text("Restore Strategy".i18n() + ":")
                            .alignedView(width: $width, alignment: .trailing)
                        PopUpButtonPicker<PickerItem?>(
                            items: restoreStrategyItems,
                            isItemSelected: { $0 == restoreStrategyItem },
                            getTitle: { $0?.title ?? "" },
                            getToolTip: { $0?.toolTip },
                            onSelect: handleRestoreStrategy
                        )
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
                .padding(.bottom)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Tooltip".i18n().uppercased())
                    .font(.footnote)
                    .fontWeight(.medium)
                    .opacity(0.5)

                VStack {
                    HStack {
                        Text("🫥 " + "Hide Indicator".i18n() + ":")
                            .alignedView(width: $width, alignment: .trailing)

                        Toggle("", isOn: $hideIndicator)
                            .toggleStyle(.switch)

                        Spacer()
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
                .padding(.bottom)
            }

            HStack {
                Spacer()

                Button("Cancel".i18n(), action: cancel)
                    .keyboardShortcut(.cancelAction)

                Button("\(rule == nil ? "Add" : "Save")".i18n(), action: save)
                    .disabled(value.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding()
        .frame(width: 480)
        .onAppear {
            value = rule?.value ?? ""
            sampleValue = rule?.sample ?? ""
            ruleType = rule?.type ?? .domainSuffix
            hideIndicator = rule?.hideIndicator ?? false

            if let inputSource = rule?.forcedKeyboard {
                inputSourceItem = PickerItem(id: inputSource.id, title: inputSource.name, toolTip: inputSource.id)
            }

            if let keyboardRestoreStrategy = rule?.keyboardRestoreStrategy {
                restoreStrategyItem = PickerItem(
                    id: keyboardRestoreStrategy.rawValue,
                    title: keyboardRestoreStrategy.name,
                    toolTip: nil
                )
            }
        }
    }

    func handleSelectInputSource(_ index: Int) {
        inputSourceItem = inputSourceItems[index]
    }

    func handleRestoreStrategy(_ index: Int) {
        restoreStrategyItem = restoreStrategyItems[index]
    }

    func handleSelectRule(_ index: Int) {
        ruleType = ruleTypes[index]
    }

    func cancel() {
        isPresented = false
    }

    func save() {
        guard !value.isEmpty else { return }

        let keyboardRestoreStrategy = restoreStrategyItem == .empty ? nil : KeyboardRestoreStrategy(rawValue: restoreStrategyItem.id)

        if let rule = rule {
            preferencesVM.updateBrowserRule(
                rule,
                type: ruleType,
                value: value,
                sample: sampleValue,
                inputSourceId: inputSourceItem.id,
                hideIndicator: hideIndicator,
                keyboardRestoreStrategy: keyboardRestoreStrategy
            )
        } else {
            preferencesVM.addBrowserRule(
                type: ruleType,
                value: value,
                sample: sampleValue,
                inputSourceId: inputSourceItem.id,
                hideIndicator: hideIndicator,
                keyboardRestoreStrategy: keyboardRestoreStrategy
            )
        }

        isPresented = false
    }
}
