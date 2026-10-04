import SwiftUI

struct AdditionalCursorSupportView: View {
    @ObservedObject private var helper = CaretHelperManager.shared
    @State private var showSetup = false
    @State private var confirmUninstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Additional cursor support")
                    Text("Help the indicator follow the text cursor in more apps.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if helper.status.installed {
                    Button("Uninstall…") { confirmUninstall = true }
                        .disabled(helper.isBusy)
                }
                if !helper.status.isReady {
                    Button("Set up…") { showSetup = true }
                        .disabled(helper.isBusy || !helper.canActivate)
                }
            }
            if let operation = helper.operation {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(operation.title).font(.callout)
                }
                .accessibilityElement(children: .combine)
            } else if let error = helper.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Review setup…") { showSetup = true }
                    .disabled(!helper.canActivate)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .task { await helper.refresh() }
        .sheet(isPresented: $showSetup) {
            CaretHelperSheet()
        }
        .alert("Uninstall cursor helper?", isPresented: $confirmUninstall) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) {
                Task { await helper.uninstall() }
            }
        } message: {
            Text("This turns off additional cursor support and removes the helper from this Mac. Standard cursor tracking will remain available.")
        }
    }
}

private struct CaretHelperSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var helper = CaretHelperManager.shared
    @State private var attemptedSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up additional cursor support")
                .font(.headline)
            if helper.isActive {
                Label("Additional cursor support is on.", systemImage: "checkmark.circle")
            } else {
                Text("Install Cursor Helper to keep the indicator next to the text cursor in more apps.")
                Text("macOS treats the helper as an input method, so its permission dialog warns about access to what you type. Cursor Helper uses the cursor’s position and does not read or record your text.")
                    .foregroundColor(.secondary)
            }

            if let operation = helper.operation {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(operation.title)
                }
                .accessibilityElement(children: .combine)
                if operation == .permission {
                    Text("In System Settings, choose Allow to enable Cursor Helper.")
                        .foregroundColor(.secondary)
                }
            } else if let error = helper.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button(attemptedSetup ? "Close" : "Cancel") {
                    helper.cancelPermissionRequest()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(helper.isBusy && helper.operation != .permission)
                if !helper.isActive {
                    Button(attemptedSetup ? "Try again" : "Install and continue") {
                        attemptedSetup = true
                        Task { await helper.setup() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(helper.isBusy || !helper.canActivate)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            if attemptedSetup && !helper.status.enabled && helper.error != nil && !helper.isBusy {
                Text("If the permission dialog did not appear, close System Settings and try again.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled(helper.isBusy)
    }
}
