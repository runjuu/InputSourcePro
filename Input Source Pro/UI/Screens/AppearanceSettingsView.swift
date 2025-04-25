import AVKit
import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject var preferencesVM: PreferencesVM
    @EnvironmentObject var navigationVM: NavigationVM

    @Environment(\.colorScheme) var colorScheme: ColorScheme

    @State private var width = CGFloat.zero

    var body: some View {
        let infoBinding = Binding(
            get: {
                preferencesVM.preferences.indicatorInfo ?? .iconAndTitle
            },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.3)) {
                    preferencesVM.update {
                        $0.indicatorInfo = newValue
                    }
                }
            }
        )

        let sizeBinding = Binding(
            get: {
                preferencesVM.preferences.indicatorSize ?? .medium
            },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.3)) {
                    preferencesVM.update {
                        $0.indicatorSize = newValue
                    }
                }
            }
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSection(title: "Indicator Info") {
                    VStack(spacing: 0) {
                        ItemSection {
                            IndicatorView()
                        }
                        .frame(height: 100)
                        .padding(.horizontal)
                        .padding(.top)

                        Picker("Position", selection: infoBinding) {
                            ForEach(IndicatorInfo.allCases) { item in
                                Text(item.name).tag(item)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .padding()
                    }
                }

                SettingsSection(title: "Indicator Size") {
                    Picker("Size", selection: sizeBinding) {
                        ForEach(IndicatorSize.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .padding()
                }

                SettingsSection(title: "Color Scheme") {
                    VStack(spacing: 0) {
                        HStack {
                            Toggle("", isOn: $preferencesVM.preferences.isAutoAppearanceMode)
                                .toggleStyle(.switch)
                                .labelsHidden()

                            Text("Sync with OS".i18n())

                            Spacer()
                        }
                        .padding()
                        .border(width: 1, edges: [.bottom], color: NSColor.border2.color)

                        VStack(spacing: 16) {
                            Picker("", selection: $preferencesVM.preferences.appearanceMode) {
                                Text("In Light Mode".i18n()).tag(Optional(Preferences.AppearanceMode.light))
                                Text("In Dark Mode".i18n()).tag(Optional(Preferences.AppearanceMode.dark))
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)

                            ColorBlocks(
                                onSelectColor: { scheme in
                                    preferencesVM.update {
                                        $0.indicatorForgegroundColor = scheme.a
                                        $0.indicatorBackgroundColor = scheme.b
                                    }
                                }
                            )

                            ItemSection {
                                IndicatorView()

                                HStack {
                                    ColorPicker(
                                        "Color",
                                        selection: $preferencesVM.preferences.indicatorForgegroundColor
                                    )
                                    .labelsHidden()

                                    Button(
                                        action: {
                                            preferencesVM.update {
                                                let a = $0.indicatorForgegroundColor
                                                let b = $0.indicatorBackgroundColor

                                                $0.indicatorForgegroundColor = b
                                                $0.indicatorBackgroundColor = a
                                            }
                                        },
                                        label: {
                                            Image(systemName: "repeat")
                                        }
                                    )

                                    ColorPicker(
                                        "Background",
                                        selection: $preferencesVM.preferences.indicatorBackgroundColor
                                    )
                                    .labelsHidden()
                                }
                            }
                            .frame(height: 130)
                        }
                        .padding()
                    }
                }
            }
            .padding()
            .padding(.bottom)
        }
        .background(NSColor.background1.color)
        .onAppear(perform: updatePreviewModeOnAppear)
        .onDisappear {
            NSColorPanel.shared.close()
        }
    }

    func updatePreviewModeOnAppear() {
        if preferencesVM.preferences.isAutoAppearanceMode {
            preferencesVM.preferences.appearanceMode = colorScheme == .dark ? .dark : .light
        }
    }

    func resetColors() {
        if preferencesVM.preferences.appearanceMode == .light {
            preferencesVM.preferences.indicatorForgegroundColor = IndicatorColor.forgeground.light
            preferencesVM.preferences.indicatorBackgroundColor = IndicatorColor.background.light
        }

        if preferencesVM.preferences.appearanceMode == .dark {
            preferencesVM.preferences.indicatorForgegroundColor = IndicatorColor.forgeground.dark
            preferencesVM.preferences.indicatorBackgroundColor = IndicatorColor.background.dark
        }
    }
}
