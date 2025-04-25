import SwiftUI

struct CJKVFixEnableFailedView: View {
    @Binding var isPresented: Bool

    @State var isOpened = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Enabled CJKV Fix Failed Desc")

            Image("Enabled CJKV Fix Shortcut Img".i18n())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .shadow(color: .black.opacity(0.26), radius: 8)
                .padding(20)

            HStack {
                Spacer()

                if isOpened {
                    Button("Close", action: { isPresented = false })
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: { isPresented = false })
                        .keyboardShortcut(.cancelAction)

                    Button("Open Keyboard Settings", action: {
                        NSWorkspace.shared.openKeyboardPreferences()
                        isOpened = true
                    })
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .frame(width: 480)
    }
}
