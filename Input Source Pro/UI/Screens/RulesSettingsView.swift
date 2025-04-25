import SwiftUI

struct RulesSettingsView: View {
    @State var selectedApp = Set<AppRule>()

    @EnvironmentObject var preferencesVM: PreferencesVM

    var items: [PickerItem] {
        [PickerItem.empty]
            + InputSource.sources.map { PickerItem(id: $0.id, title: $0.name, toolTip: $0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ApplicationPicker(selectedApp: $selectedApp)
                        .border(width: 1, edges: [.bottom], color: Color(NSColor.gridColor))

                    HStack(spacing: 5) {
                        Button(action: selectApp) {
                            SwiftUI.Image(systemName: "plus")
                        }

                        Button(action: removeApp) {
                            SwiftUI.Image(systemName: "minus")
                        }
                        .disabled(selectedApp.isEmpty)

                        RunningApplicationsPicker(onSelect: selectRunningApp)
                    }
                    .padding(10)
                }
                .frame(width: 245)
                .border(width: 1, edges: [.trailing], color: Color(NSColor.gridColor))

                ApplicationDetail(selectedApp: $selectedApp)
                    .padding()

                Spacer(minLength: 0)
            }
        }
    }

    func selectApp() {
        let panel = NSOpenPanel()

        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]

        if let applicationPath = NSSearchPathForDirectoriesInDomains(
            .applicationDirectory,
            .localDomainMask,
            true
        ).first {
            panel.directoryURL = URL(fileURLWithPath: applicationPath, isDirectory: true)
        }

        if panel.runModal() == .OK {
            selectedApp = Set(panel.urls.map {
                preferencesVM.addAppCustomization($0, bundleId: $0.bundleId())
            })
        }
    }

    func removeApp() {
        for app in selectedApp {
            preferencesVM.removeAppCustomization(app)
        }
        selectedApp.removeAll()
    }

    func selectRunningApp(_ app: NSRunningApplication) {
        if let appRule = preferencesVM.addAppCustomization(app) {
            selectedApp = Set([appRule])
        }
    }
}
