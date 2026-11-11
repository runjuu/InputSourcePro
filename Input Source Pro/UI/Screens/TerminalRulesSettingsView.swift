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

                QuestionMark { programControlHelp }
                    .padding(.leading, 8)
            }
            .padding(10)
            .border(width: 1, edges: [.top], color: NSColor.gridColor.color)
            .sheet(isPresented: $isPresented, content: {
                TerminalRuleEditView(isPresented: $isPresented, rule: nil)
            })
        }
    }

    /// The `isp:` protocol, see `TerminalControlCommand`.
    var programControlHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A program can take over its own pane, so Terminal Rules and App rules no longer apply there, by writing a line to:".i18n())
            Text("~/Library/Application Support/Input Source Pro/terminal-control")
                .font(.system(.body, design: .monospaced))

            VStack(alignment: .leading, spacing: 4) {
                ForEach([
                    ("isp:<pid>:select:<id>", "Switch to the input source"),
                    ("isp:<pid>:push:<id>", "Remember the current input source, then switch"),
                    ("isp:<pid>:pop", "Switch back to the remembered input source"),
                    ("isp:<pid>:release", "Hand the pane back to the rules"),
                ], id: \.0) { command, meaning in
                    // Grid needs macOS 13; the deployment target is 12
                    HStack(spacing: 12) {
                        Text(command)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 190, alignment: .leading)
                        Text(meaning.i18n()).foregroundColor(.secondary)
                    }
                }
            }

            Text("<pid> is a process running in that pane; <id> is an input source ID such as com.apple.keylayout.ABC. Panes inside Zellij are not supported.".i18n())
                .foregroundColor(.secondary)
        }
        .textSelection(.enabled)
        .fixedSize()
        .padding()
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
