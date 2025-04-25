import SwiftUI

struct RunningApplicationsPicker: View {
    @EnvironmentObject var preferencesVM: PreferencesVM

    let appIconSize: CGFloat = 18

    let onSelect: (NSRunningApplication) -> Void

    init(onSelect: @escaping (NSRunningApplication) -> Void) {
        self.onSelect = onSelect
    }

    var body: some View {
        Menu("Add Running Apps") {
            ForEach(preferencesVM.filterApps(NSWorkspace.shared.runningApplications), id: \.processIdentifier) { app in
                Button(action: { onSelect(app) }) {
                    Text(app.localizedName ?? app.bundleId() ?? app.description)

                    if let url = app.bundleURL {
                        let image = NSWorkspace.shared.icon(forFile: url.path)

                        SwiftUI.Image(nsImage: image)
                            .resizable()
                            .frame(width: appIconSize, height: appIconSize)
                    } else {
                        SwiftUI.Image(systemName: "app.dashed")
                            .resizable()
                            .frame(width: appIconSize, height: appIconSize)
                    }
                }
            }
        }
    }
}
