import SwiftUI

struct TroubleshootingSettingsView: View {
    @EnvironmentObject var preferencesVM: PreferencesVM

    @State var isShowCJKVFixEnableFailedView = false
    @State private var cursorSettingStatus: CursorSettingStatus = .unknown
    @State private var isRunningCommand = false

    var body: some View {
        let isCJKVFixEnabledBinding = Binding(
            get: { preferencesVM.preferences.isCJKVFixEnabled },
            set: { onToggleCJKVFix($0) }
        )

        ScrollView {
            VStack(spacing: 18) {
                SettingsSection(title: "") {
                    VStack(alignment: .leading) {
                        HStack {
                            Toggle("", isOn: isCJKVFixEnabledBinding)
                                .disabled(!preferencesVM.preferences.isEnhancedModeEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()

                            Text("Enabled CJKV Fix".i18n())
                                .font(.headline)

                            Spacer()

                            EnhancedModeRequiredBadge()
                        }

                        Text(.init("Enabled CJKV Fix Description".i18n()))
                            .font(.system(size: 12))
                            .opacity(0.8)
                    }
                    .padding()
                }
                
                // Cursor Lag Fix Section
                SettingsSection(title: "") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Cursor Lag Fix".i18n())
                                .font(.headline)
                            
                            Spacer()
                            
                            Button(action: {}) {
                                Text("Reboot Required Notice".i18n())
                            }
                            .buttonStyle(EnhanceMoreRequiredButtonStyle())
                        }
                        
                        Text(.init("Cursor Lag Fix Description".i18n()))
                            .font(.system(size: 12))
                            .opacity(0.8)
                                      
                        // Status display
                        HStack {
                            Text("Cursor Setting Status".i18n())
                                .font(.system(size: 13))
                            
                            if isRunningCommand {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 16, height: 16)
                            } else {
                                switch cursorSettingStatus {
                                case .enabled:
                                    Label("Cursor Setting Enabled".i18n(), systemImage: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.system(size: 13))
                                case .disabled:
                                    Label("Cursor Setting Disabled".i18n(), systemImage: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                        .font(.system(size: 13))
                                case .undefined:
                                    Label("Cursor Setting Undefined".i18n(), systemImage: "checkmark.circle.badge.questionmark.fill")
                                        .foregroundColor(.gray)
                                        .font(.system(size: 13))
                                case .unknown:
                                    Button {
                                        checkCursorSetting()
                                    } label: {
                                        Label("Check Cursor Setting Now".i18n(), systemImage: "questionmark.circle.dashed")
                                            .font(.system(size: 13))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(.accentColor)
                                }
                            }
                        }
                        
                        
                        // Action buttons
                        HStack(spacing: 10) {
                            Button(action: disableCursorFeature) {
                                Text("Disable Cursor Feature".i18n())
                            }
                            .buttonStyle(BorderedButtonStyle())
                            .disabled(isRunningCommand)
                            
                            Button(action: enableCursorFeature) {
                                Text("Enable Cursor Feature".i18n())
                            }
                            .buttonStyle(BorderedButtonStyle())
                            .disabled(isRunningCommand)
                            
                            Spacer()
                            
                            Button(action: checkCursorSetting) {
                                Text("Check Cursor Setting".i18n())
                            }
                            .buttonStyle(BorderedButtonStyle())
                            .disabled(isRunningCommand)
                            
                            Button(action: removeCursorSetting) {
                                Text("Remove Cursor Setting".i18n())
                            }
                            .buttonStyle(BorderedButtonStyle())
                            .disabled(isRunningCommand)
                        }
                    }
                    .padding()
                }

                SettingsSection(title: "") {
                    FeedbackButton()
                }
            }
            .padding()
        }
        .background(NSColor.background1.color)
        .sheet(isPresented: $isShowCJKVFixEnableFailedView) {
            CJKVFixEnableFailedView(isPresented: $isShowCJKVFixEnableFailedView)
        }
        .onAppear {
            checkCursorSetting()
        }
    }

    func onToggleCJKVFix(_ isCJKVFixEnabled: Bool) {
        if isCJKVFixEnabled {
            if InputSource.getSelectPreviousShortcut() == nil {
                isShowCJKVFixEnableFailedView = true
            } else {
                preferencesVM.update {
                    $0.isCJKVFixEnabled = true
                }
            }
        } else {
            preferencesVM.update {
                $0.isCJKVFixEnabled = false
            }
        }
    }
    
    // Cursor Lag Fix Functions
    
    func disableCursorFeature() {
        isRunningCommand = true
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", "osascript -e 'do shell script \"sudo defaults write /Library/Preferences/FeatureFlags/Domain/UIKit.plist redesigned_text_cursor -dict-add Enabled -bool NO\" with administrator privileges'"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.terminationHandler = { _ in
            DispatchQueue.main.async {
                self.isRunningCommand = false
                self.checkCursorSetting()
            }
        }
        
        do {
            try task.run()
        } catch {
            isRunningCommand = false
        }
    }
    
    func enableCursorFeature() {
        isRunningCommand = true
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", "osascript -e 'do shell script \"sudo defaults write /Library/Preferences/FeatureFlags/Domain/UIKit.plist redesigned_text_cursor -dict-add Enabled -bool YES\" with administrator privileges'"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.terminationHandler = { _ in
            DispatchQueue.main.async {
                self.isRunningCommand = false
                self.checkCursorSetting()
            }
        }
        
        do {
            try task.run()
        } catch {
            isRunningCommand = false
        }
    }
    
    func checkCursorSetting() {
        isRunningCommand = true
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["read", "/Library/Preferences/FeatureFlags/Domain/UIKit.plist", "redesigned_text_cursor"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        task.terminationHandler = { _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            DispatchQueue.main.async {
                self.isRunningCommand = false
                
                if output.contains("does not exist") {
                    self.cursorSettingStatus = .undefined
                } else if output.contains("Enabled = 1") {
                    self.cursorSettingStatus = .enabled
                } else if output.contains("Enabled = 0") {
                    self.cursorSettingStatus = .disabled
                } else {
                    self.cursorSettingStatus = .undefined
                }
            }
        }
        
        do {
            try task.run()
        } catch {
            isRunningCommand = false
            cursorSettingStatus = .unknown
        }
    }
    
    func removeCursorSetting() {
        isRunningCommand = true
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", "osascript -e 'do shell script \"sudo defaults delete /Library/Preferences/FeatureFlags/Domain/UIKit.plist redesigned_text_cursor\" with administrator privileges'"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.terminationHandler = { _ in
            DispatchQueue.main.async {
                self.isRunningCommand = false
                self.checkCursorSetting()
            }
        }
        
        do {
            try task.run()
        } catch {
            isRunningCommand = false
        }
    }
}

enum CursorSettingStatus {
    case enabled
    case disabled
    case undefined
    case unknown
}
