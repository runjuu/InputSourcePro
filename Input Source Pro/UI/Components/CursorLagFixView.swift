import SwiftUI

struct CursorLagFixView: View {
    @State private var isCursorLagFixEnabled = false
    @State private var isRunningCommand = false
    @State private var isRebootRequired = false
    
    var body: some View {
        let toggleBinding = Binding(
            get: { isCursorLagFixEnabled },
            set: {
                isCursorLagFixEnabled = $0
                toggleRedesignedTextCursor(disable: $0)
            }
        )
        
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("", isOn: toggleBinding)
                    .disabled(isRunningCommand)
                    .toggleStyle(.switch)
                    .labelsHidden()
                
                Text("Cursor Lag Fix".i18n())
                    .font(.headline)
                
                Spacer()
                
                RebootRequiredBadge(isRequired: !isRebootRequired)
            }
            
            Text(.init("Cursor Lag Fix Description".i18n()))
                .font(.system(size: 12))
                .opacity(0.8)
        }
        .padding()
        .onAppear(perform: checkCursorSetting)
    }
    
    func toggleRedesignedTextCursor(disable: Bool) {
        guard !isRunningCommand else { return }
        
        let command = "sudo defaults write /Library/Preferences/FeatureFlags/Domain/UIKit.plist redesigned_text_cursor -dict-add Enabled -bool \(disable ? "NO" : "YES")"
        
        isRunningCommand = true
        
        command.runCommand(
            requireSudo: true,
            completion: { _, _, _ in
                isRunningCommand = false
                isRebootRequired = true
                checkCursorSetting()
            }
        )
    }
    
    func checkCursorSetting() {
        guard !isRunningCommand else { return }
        
        let command = "defaults read /Library/Preferences/FeatureFlags/Domain/UIKit.plist redesigned_text_cursor"
        
        isRunningCommand = true
        
        command.runCommand(
            requireSudo: false,
            completion: { output, _, _ in
                isRunningCommand = false
                isCursorLagFixEnabled = output.contains("Enabled = 0")
            }
        )
    }
}
