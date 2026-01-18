import SwiftUI

struct ModifierComboPicker: View {
    @Binding var selection: ModifierCombo?

    @State private var isPresented = false
    @State private var draftKeys: Set<SingleModifierKey> = []

    private func modifierGroup(for key: SingleModifierKey) -> Int {
        switch key {
        case .leftShift, .rightShift:
            return 0
        case .leftControl, .rightControl:
            return 1
        case .leftOption, .rightOption:
            return 2
        case .leftCommand, .rightCommand:
            return 3
        }
    }

    private func counterpart(for key: SingleModifierKey) -> SingleModifierKey {
        switch key {
        case .leftShift:
            return .rightShift
        case .rightShift:
            return .leftShift
        case .leftControl:
            return .rightControl
        case .rightControl:
            return .leftControl
        case .leftOption:
            return .rightOption
        case .rightOption:
            return .leftOption
        case .leftCommand:
            return .rightCommand
        case .rightCommand:
            return .leftCommand
        }
    }

    private func normalizedKeys(_ keys: Set<SingleModifierKey>) -> Set<SingleModifierKey> {
        var normalized: Set<SingleModifierKey> = []

        for key in keys.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let group = modifierGroup(for: key)
            if !normalized.contains(where: { modifierGroup(for: $0) == group }) {
                normalized.insert(key)
            }
        }

        return normalized
    }

    private func isDisabled(_ key: SingleModifierKey) -> Bool {
        !draftKeys.contains(key) && draftKeys.contains(counterpart(for: key))
    }

    private var selectionLabel: String {
        selection?.displayName ?? "None".i18n()
    }

    var body: some View {
        Button(action: { isPresented.toggle() }) {
            HStack(spacing: 6) {
                Text(selectionLabel)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .flexibleButtonSizing()
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose modifier combination".i18n())
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(SingleModifierKey.allCases, id: \.self) { item in
                        Toggle(
                            item.name,
                            isOn: Binding(
                                get: { draftKeys.contains(item) },
                                set: { isOn in
                                    if isOn {
                                        draftKeys.remove(counterpart(for: item))
                                        draftKeys.insert(item)
                                    } else {
                                        draftKeys.remove(item)
                                    }
                                }
                            )
                        )
                        .disabled(isDisabled(item))
                    }
                }

                Divider()

                HStack {
                    Button("Reset".i18n()) {
                        draftKeys.removeAll()
                    }

                    Spacer()

                    Button("Save".i18n()) {
                        let normalized = normalizedKeys(draftKeys)
                        selection = normalized.isEmpty ? nil : ModifierCombo(keys: normalized)
                        isPresented = false
                    }
                }
            }
            .padding()
            .frame(minWidth: 220)
            .onAppear {
                draftKeys = normalizedKeys(selection?.keys ?? [])
            }
        }
        .onChange(of: isPresented) { newValue in
            if newValue {
                draftKeys = normalizedKeys(selection?.keys ?? [])
            }
        }
    }
}
