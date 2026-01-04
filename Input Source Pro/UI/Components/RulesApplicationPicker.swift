import SwiftUI

struct ApplicationPicker: View {
    @Binding var selectedApp: Set<AppRule>

    @EnvironmentObject var preferencesVM: PreferencesVM

    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "bundleName", ascending: true)])
    var appCustomizations: FetchedResults<AppRule>

    let appIconSize: CGFloat = 18
    let keyboardIconSize: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            List(appCustomizations, id: \.self, selection: $selectedApp) { app in
                ApplicationPickerRow(
                    app: app,
                    isSelected: selectedApp.contains(app),
                    appIconSize: appIconSize,
                    keyboardIconSize: keyboardIconSize
                )
            }
            .listRowInsets(EdgeInsets())
        }
        .onAppear {
            if let app = appCustomizations.first {
                selectedApp.update(with: app)
            }
        }
    }
}

private struct ApplicationPickerRow: View {
    @ObservedObject var app: AppRule

    @EnvironmentObject var preferencesVM: PreferencesVM

    let isSelected: Bool
    let appIconSize: CGFloat
    let keyboardIconSize: CGFloat

    var body: some View {
        HStack {
            if let image = app.image {
                SwiftUI.Image(nsImage: image)
                    .resizable()
                    .frame(width: appIconSize, height: appIconSize)
            } else {
                SwiftUI.Image(systemName: "app.dashed")
                    .resizable()
                    .frame(width: appIconSize, height: appIconSize)
            }

            Text(app.bundleName ?? "(unknown)")
                .lineLimit(1)

            Spacer()

            if app.hideIndicator {
                RuleSettingIcon(systemName: "eye.slash.circle.fill", color: .gray)
                    .opacity(0.7)
            }

            if app.forceEnglishPunctuation {
                RuleSettingIcon(text: "Aa", color: .orange)
                    .opacity(0.7)
            }

            if preferencesVM.needDisplayEnhancedModePrompt(bundleIdentifier: app.bundleId) {
                RuleSettingIcon(
                    systemName: "exclamationmark.triangle.fill",
                    color: Color(red: 1.0, green: 0.84, blue: 0.0)
                )
            }

            if preferencesVM.preferences.isRestorePreviouslyUsedInputSource {
                if app.doNotRestoreKeyboard {
                    RuleSettingIcon(systemName: "d.circle.fill", color: isSelected ? .primary : .green)
                        .opacity(isSelected ? 0.7 : 1.0)
                }
            } else {
                if app.doRestoreKeyboard {
                    RuleSettingIcon(systemName: "arrow.uturn.left.circle.fill", color: isSelected ? .primary : .blue)
                        .opacity(isSelected ? 0.7 : 1.0)
                }
            }

            if let functionKeyMode = app.functionKeyMode {
                let systemName = functionKeyMode == .functionKeys ? "keyboard" : "sun.max"
                RuleSettingIcon(systemName: systemName)
                    .opacity(0.7)
            }

            if let icon = app.forcedKeyboard?.icon {
                SwiftUI.Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: keyboardIconSize, height: keyboardIconSize)
                    .opacity(0.7)
            }
        }
        .help(app.bundleName ?? app.url?.path ?? "(unknown)")
    }
}
