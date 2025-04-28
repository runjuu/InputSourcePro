import AVKit
import SwiftUI

struct PositionSettingsView: View {
    @EnvironmentObject var preferencesVM: PreferencesVM
    @EnvironmentObject var navigationVM: NavigationVM

    @Environment(\.colorScheme) var colorScheme: ColorScheme

    @State var displayIndicatorNearCursorTips = false
    @State var displayAlwaysOnIndicatorTips = false
    @State private var width = CGFloat.zero

    var body: some View {
        let sliderBinding = Binding(
            get: {
                Double(preferencesVM.preferences.indicatorPositionSpacing?.rawValue ?? 3)
            },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.2)) {
                    preferencesVM.update {
                        $0.indicatorPositionSpacing = .fromSlide(value: newValue)
                    }
                }
            }
        )

        let positionBinding = Binding(
            get: {
                preferencesVM.preferences.indicatorPosition ?? .nearMouse
            },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.3)) {
                    preferencesVM.update {
                        $0.indicatorPosition = newValue
                    }
                }
            }
        )

        ScrollView {
            VStack(spacing: 18) {
                SettingsSection(title: "Position") {
                    VStack(spacing: 0) {
                        IndicatorPositionEditor()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(.horizontal)
                            .padding(.top)

                        Picker("Position", selection: positionBinding) {
                            ForEach(IndicatorPosition.allCases) { item in
                                Text(item.name).tag(item)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .padding()

                        if preferencesVM.preferences.indicatorPosition != .nearMouse {
                            HStack {
                                Text("Spacing".i18n() + ":")
                                    .alignedView(width: $width, alignment: .leading)

                                HStack {
                                    Slider(value: sliderBinding, in: 0 ... 5, step: 1)

                                    if let name = preferencesVM.preferences.indicatorPositionSpacing?.name {
                                        Text(name)
                                            .foregroundColor(.primary)
                                            .frame(width: 50, height: 25)
                                            .background(Color.primary.opacity(0.05))
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                            .noAnimation()
                                    }
                                }
                            }
                            .padding()
                            .border(width: 1, edges: [.top, .bottom], color: NSColor.border2.color)

                            HStack {
                                Text("Alignment".i18n() + ":")
                                    .alignedView(width: $width, alignment: .leading)

                                HStack {
                                    PopUpButtonPicker<IndicatorPosition.Alignment>(
                                        items: IndicatorPosition.Alignment.allCases,
                                        isItemSelected: { $0 == preferencesVM.preferences.indicatorPositionAlignment },
                                        getTitle: { $0.name },
                                        getToolTip: { $0.name },
                                        onSelect: { index in
                                            withAnimation(.easeInOut(duration: 0.3)) {
                                                preferencesVM.update {
                                                    let value = IndicatorPosition.Alignment.allCases[index]
                                                    $0.indicatorPositionAlignment = value
                                                }
                                            }
                                        }
                                    )
                                }
                            }
                            .padding()
                        }
                    }
                }

                SettingsSection(title: "Advanced", tips: EnhancedModeRequiredBadge()) {
                    VStack(spacing: 0) {
                        HStack {
                            Toggle(isOn: $preferencesVM.preferences.tryToDisplayIndicatorNearCursor) {}
                                .toggleStyle(.switch)
                                .disabled(!preferencesVM.preferences.isEnhancedModeEnabled)

                            Text("tryToDisplayIndicatorNearCursor".i18n())

                            Spacer()

                            QuestionButton(
                                content: {
                                    SwiftUI.Image(systemName: "video")
                                        .font(.system(size: 11, weight: .bold))
                                        .padding(6)
                                },
                                popover: {
                                    PlayerView(url: Bundle.main.url(
                                        forResource: "Indicator-Near-Cursor-Demo-\($0 == .dark ? "Dark" : "Light")",
                                        withExtension: "mp4"
                                    )!)
                                        .frame(height: 118)

                                    Text("Enhanced Mode Required Tips".i18n())
                                        .font(.footnote)
                                        .opacity(0.6)
                                        .padding(.vertical, 10)
                                }
                            )
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        .border(width: 1, edges: [.bottom], color: NSColor.border2.color)

                        VStack {
                            let needDisableAlwaysOnIndicator = !preferencesVM.preferences.isEnhancedModeEnabled || !preferencesVM.preferences.tryToDisplayIndicatorNearCursor

                            HStack {
                                Toggle("", isOn: $preferencesVM.preferences.isEnableAlwaysOnIndicator)
                                    .disabled(needDisableAlwaysOnIndicator)
                                    .toggleStyle(.switch)
                                    .labelsHidden()

                                Text("isEnableAlwaysOnIndicator".i18n())

                                Spacer()

                                QuestionButton(
                                    content: {
                                        SwiftUI.Image(systemName: "video")
                                            .font(.system(size: 11, weight: .bold))
                                            .padding(6)
                                    },
                                    popover: {
                                        PlayerView(url: Bundle.main.url(
                                            forResource: "Always-On-Indicator-Demo-\($0 == .dark ? "Dark" : "Light")",
                                            withExtension: "mp4"
                                        )!)
                                            .frame(height: 118)

                                        Text("alwaysOnIndicatorTips".i18n())
                                            .font(.footnote)
                                            .padding(.vertical, 10)
                                            .opacity(0.6)
                                    }
                                )
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                    }
                }
            }
            .padding()
            .padding(.bottom)
        }
        .onAppear(perform: updatePreviewModeOnAppear)
        .background(NSColor.background1.color)
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
