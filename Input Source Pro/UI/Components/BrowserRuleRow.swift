import SwiftUI

struct BrowserRuleRow: View {
    @State var showModal = false

    @ObservedObject var rule: BrowserRule

    let imgSize: CGFloat = 16

    var body: some View {
        HStack {
            Text(rule.value ?? "")

            Spacer()

            if rule.hideIndicator == true {
                VStack {
                    Text("􀋯")
                }
                .frame(width: imgSize, height: imgSize)
            }

            if let keyboardRestoreStrategy = rule.keyboardRestoreStrategy {
                VStack {
                    Text(keyboardRestoreStrategy.SFSymbol)
                        .font(.system(size: imgSize - 4))
                }
                .frame(width: imgSize, height: imgSize)
            }

            if let forcedKeyboard = rule.forcedKeyboard {
                SwiftUI.Image(nsImage: forcedKeyboard.icon ?? NSImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: imgSize, height: imgSize)
                    .opacity(0.7)
            }

            Text(rule.type.name)
                .font(.footnote)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .foregroundColor(.white)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 2))

            Button("Edit") {
                showModal = true
            }
        }
        .sheet(isPresented: $showModal, content: {
            BrowserRuleEditView(isPresented: $showModal, rule: rule)
        })
    }
}
