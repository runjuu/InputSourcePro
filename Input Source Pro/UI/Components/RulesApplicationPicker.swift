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
                        SwiftUI.Image(systemName: "eye.slash")
                            .foregroundColor(.gray)
                    }

                    if preferencesVM.needDisplayEnhancedModePrompt(bundleIdentifier: app.bundleId) {
                        SwiftUI.Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Color(red: 1.0, green: 0.84, blue: 0.0))
                    }

                    if preferencesVM.preferences.isRestorePreviouslyUsedInputSource {
                        if app.doNotRestoreKeyboard {
                            SwiftUI.Image(systemName: "d.circle")
                                .foregroundColor(.green)
                                .offset(x: 0, y: -1.5)
                        }
                    } else {
                        if app.doRestoreKeyboard {
                            SwiftUI.Image(systemName: "arrow.counterclockwise")
                                .foregroundColor(.blue)
                                .offset(x: 0, y: -1)
                        }
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
            .listRowInsets(EdgeInsets())
        }
        .onAppear {
            if let app = appCustomizations.first {
                selectedApp.update(with: app)
            }
        }
    }
}
