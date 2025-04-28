import Combine
import SwiftUI

struct BrowserPermissionRequestView: View {
    @EnvironmentObject var permissionsVM: PermissionsVM
    @EnvironmentObject var preferencesVM: PreferencesVM

    @Binding var isPresented: Bool

    @State var isDisableTips: Bool = true

    var onSuccess: () -> Void

    let timer = Timer
        .interval(seconds: 1)
        .mapToVoid()
        .ignoreFailure()
        .eraseToAnyPublisher()

    let fakeTimer = Empty(outputType: Void.self, failureType: Never.self)
        .eraseToAnyPublisher()

    var body: some View {
        VStack {
            Text("Permission Required")
                .font(.title)
                .fontWeight(.medium)
                .padding(.vertical, 10)

            VStack(alignment: .leading) {
                Text("Browser Rules Accessibility Permission Description")

                HStack {
                    Spacer()

                    if permissionsVM.isAccessibilityEnabled {
                        SwiftUI.Image(systemName: "checkmark.circle.fill")
                            .resizable()
                            .frame(width: 16, height: 16)
                            .foregroundColor(.green)

                        Button("Authorized", action: openAccessibilityPreferences)
                            .disabled(true)
                    } else {
                        Button("Open Accessibility Preferences", action: openAccessibilityPreferences)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.top, 5)
            }

            Divider()
                .padding(.vertical, 10)

            HStack {
                Button(action: URL.howToEnableBrowserRule.open) {
                    SwiftUI.Image(systemName: "questionmark")
                }
                .font(.system(size: 10).weight(.bold))
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 99))
                .disabled(isDisableTips)

                Spacer()

                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .padding()
        .frame(width: 400)
        .onAppear {
            DispatchQueue.main.async {
                isDisableTips = false
            }
        }
        .onChange(of: permissionsVM.isAccessibilityEnabled) { _ in
            onAuthorizeSuccess()
        }
    }

    func close() {
        isPresented = false
    }

    func openAccessibilityPreferences() {
        NSWorkspace.shared.openAccessibilityPreferences()
    }

    func openAutomationPreferences() {
        NSWorkspace.shared.openAutomationPreferences()
    }

    func onAuthorizeSuccess() {
        onSuccess()
        close()
    }
}
