import SwiftUI

struct InputSourcesAppearanceSettingsView: View {
    @EnvironmentObject var preferencesVM: PreferencesVM

    let imgSize: CGFloat = 16

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForEach(InputSource.sources, id: \.id) { inputSource in
                    SettingsSection(title: inputSource.name, noI18N: true) {
                        KeyboardCustomization(inputSource: inputSource)
                    }
                }
            }
            .padding()
            .padding(.bottom)
        }
        .background(NSColor.background1.color)
    }
}
