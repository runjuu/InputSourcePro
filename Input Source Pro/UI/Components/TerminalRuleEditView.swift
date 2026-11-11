import SwiftUI

struct TerminalRuleEditView: View {
    @State var program: String = ""
    @State var inputSourceItem = PickerItem.empty

    @State private var width = CGFloat.zero

    @Binding var isPresented: Bool

    @EnvironmentObject var preferencesVM: PreferencesVM

    let rule: TerminalRule?

    var inputSourceItems: [PickerItem] {
        [PickerItem.empty]
            + InputSource.sources.map {
                PickerItem(id: $0.persistentIdentifier, title: $0.name, toolTip: $0.persistentIdentifier)
            }
    }

    var trimmedProgram: String {
        program.trimmingCharacters(in: .whitespacesAndNewlines)
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
                        Text("Program Name".i18n() + ":")
                            .alignedView(width: $width, alignment: .trailing)
                        TextField("claude", text: $program)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.bottom)
            }

            HStack {
                Spacer()

                Button("Cancel".i18n(), action: cancel)
                    .keyboardShortcut(.cancelAction)

                Button("\(rule == nil ? "Add" : "Save")".i18n(), action: save)
                    .disabled(trimmedProgram.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding()
        .frame(width: 480)
        .onAppear {
            program = rule?.program ?? ""

            if let inputSource = rule?.forcedKeyboard {
                inputSourceItem = PickerItem(
                    id: inputSource.persistentIdentifier,
                    title: inputSource.name,
                    toolTip: inputSource.persistentIdentifier
                )
            }
        }
    }

    func handleSelectInputSource(_ index: Int) {
        inputSourceItem = inputSourceItems[index]
    }

    func cancel() {
        isPresented = false
    }

    func save() {
        guard !trimmedProgram.isEmpty else { return }

        var savedRule = rule ?? TerminalRule(program: trimmedProgram)
        savedRule.program = trimmedProgram
        savedRule.inputSourceId = inputSourceItem == .empty ? nil : inputSourceItem.id
        preferencesVM.saveTerminalRule(savedRule)

        isPresented = false
    }
}
