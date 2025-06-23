import SwiftUI

struct BrowserRuleRow: View {
    @State var showModal = false
    
    var isSelected: Bool = false
    
    @ObservedObject var rule: BrowserRule

    let imgSize: CGFloat = 16

    var body: some View {
        HStack {
            Text(rule.value ?? "")

            Spacer()

            if rule.hideIndicator == true {
                Image(systemName: "eye.slash.circle.fill")
                    .opacity(0.7)
                    .frame(width: imgSize, height: imgSize)
            }

            if let keyboardRestoreStrategy = rule.keyboardRestoreStrategy {
                let symbolName = keyboardRestoreStrategy.systemImageName
                let color: Color = {
                    switch symbolName {
                    case "d.circle.fill", "d.square.fill":
                        return isSelected ? .primary.opacity(0.7) : .green
                    case "arrow.uturn.left.circle.fill":
                        return isSelected ? .primary.opacity(0.7) : .blue
                    default:
                        return .primary
                    }
                }()
                Image(systemName: symbolName)
                    .foregroundColor(color)
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
