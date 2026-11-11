import SwiftUI

struct TerminalRuleRow: View {
    @State var showModal = false

    @EnvironmentObject var preferencesVM: PreferencesVM

    let rule: TerminalRule

    let imgSize: CGFloat = 16

    var body: some View {
        HStack {
            Toggle("", isOn: isEnabled)
                .labelsHidden()

            Text(rule.program)

            Spacer()

            if let forcedKeyboard = rule.forcedKeyboard {
                SwiftUI.Image(nsImage: forcedKeyboard.icon ?? NSImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: imgSize, height: imgSize)
                    .opacity(0.7)
            }

            Button("Edit") {
                showModal = true
            }
        }
        .sheet(isPresented: $showModal, content: {
            TerminalRuleEditView(isPresented: $showModal, rule: rule)
        })
    }

    var isEnabled: Binding<Bool> {
        Binding(
            get: { !rule.disabled },
            set: { isEnabled in
                var rule = rule
                rule.disabled = !isEnabled
                preferencesVM.saveTerminalRule(rule)
            }
        )
    }
}
