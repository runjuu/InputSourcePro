import SwiftUI

struct TerminalRulesSettingsView: View {
    @State var isPresented = false

    @State var selectedRuleIds = Set<UUID>()

    @EnvironmentObject var preferencesVM: PreferencesVM

    var body: some View {
        VStack(spacing: 0) {
            List(preferencesVM.terminalRules, selection: $selectedRuleIds) { rule in
                TerminalRuleRow(rule: rule)
            }

            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    Button(action: addRule) {
                        SwiftUI.Image(systemName: "plus")
                            .frame(width: 14, height: 14)
                    }

                    Button(action: removeRules) {
                        SwiftUI.Image(systemName: "minus")
                            .frame(width: 14, height: 14)
                    }
                    .disabled(selectedRuleIds.isEmpty)
                }

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Terminal.allCases.filter(\.isInstalled), id: \.rawValue) { terminal in
                            Toggle(isOn: isEnableFor(terminal)) {
                                Text(terminal.displayName)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .border(width: 1, edges: [.top], color: NSColor.gridColor.color)
            .sheet(isPresented: $isPresented, content: {
                TerminalRuleEditView(isPresented: $isPresented, rule: nil)
            })
        }
    }

    func addRule() {
        isPresented = true
    }

    func removeRules() {
        preferencesVM.deleteTerminalRules(ids: selectedRuleIds)
        selectedRuleIds.removeAll()
    }

    func isEnableFor(_ terminal: Terminal) -> Binding<Bool> {
        Binding(
            get: { preferencesVM.isTerminalEnabled(terminal) },
            set: { preferencesVM.setTerminal(terminal, enabled: $0) }
        )
    }
}
