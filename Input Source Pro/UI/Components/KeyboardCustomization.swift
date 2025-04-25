import SwiftUI
import VisualEffects

struct KeyboardCustomization: View {
    @EnvironmentObject var preferencesVM: PreferencesVM

    @State var textColor: Color = .clear
    @State var bgColor: Color = .clear

    let inputSource: InputSource

    let columns = [
        GridItem(.fixed(100), alignment: .trailing),
        GridItem(.flexible(minimum: 50, maximum: .infinity), alignment: .leading),
    ]

    let indicatorColumns = [
        GridItem(.flexible(minimum: 50, maximum: .infinity), alignment: .center),
        GridItem(.flexible(minimum: 50, maximum: .infinity), alignment: .center),
    ]

    var body: some View {
        let keyboardConfig = preferencesVM.getOrCreateKeyboardConfig(inputSource)

        VStack(alignment: .leading) {
            ZStack {
                LazyVGrid(columns: indicatorColumns) {
                    DumpIndicatorView(config: IndicatorViewConfig(
                        inputSource: inputSource,
                        kind: .alwaysOn,
                        size: preferencesVM.preferences.indicatorSize ?? .medium,
                        bgColor: NSColor(bgColor),
                        textColor: NSColor(textColor)
                    ))

                    DumpIndicatorView(config: IndicatorViewConfig(
                        inputSource: inputSource,
                        kind: preferencesVM.preferences.indicatorKind,
                        size: preferencesVM.preferences.indicatorSize ?? .medium,
                        bgColor: NSColor(bgColor),
                        textColor: NSColor(textColor)
                    ))

                    Text("Always-On Indicator Style")
                        .font(.caption)
                        .opacity(0.5)

                    Text("Keyboard Indicator Style")
                        .font(.caption)
                        .opacity(0.5)
                }
                .padding()
                .itemSectionStyle()

                VStack {
                    Spacer()

                    HStack {
                        Spacer()
                        Button(action: { reset(keyboardConfig) }) {
                            Text("Reset")
                        }
                        .buttonStyle(GhostButton(icon: Image(systemName: "arrow.clockwise")))
                    }
                }
                .padding(.trailing, 4)
                .padding(.bottom, 4)
            }

            VStack(alignment: .center) {
                ColorBlocks(onSelectColor: {
                    textColor = $0.a
                    bgColor = $0.b
                })
                .padding(.vertical, 8)

                HStack {
                    ColorPicker("Color", selection: $textColor)

                    Button(
                        action: {
                            let a = textColor
                            let b = bgColor

                            textColor = b
                            bgColor = a
                        },
                        label: {
                            Image(systemName: "repeat")
                        }
                    )

                    ColorPicker("Background", selection: $bgColor)
                }
                .labelsHidden()
            }
            .padding(.horizontal)
        }
        .padding()
        .onAppear {
            textColor = preferencesVM.getTextColor(inputSource)
            bgColor = preferencesVM.getBgColor(inputSource)
        }
        .onChange(of: bgColor, perform: { _ in save(keyboardConfig) })
        .onChange(of: textColor, perform: { _ in save(keyboardConfig) })
        .onDisappear {
            NSColorPanel.shared.close()
        }
    }

    func save(_ keyboardConfig: KeyboardConfig) {
        preferencesVM.update(keyboardConfig, textColor: textColor, bgColor: bgColor)
    }

    func reset(_: KeyboardConfig) {
        bgColor = preferencesVM.preferences.indicatorBackgroundColor
        textColor = preferencesVM.preferences.indicatorForgegroundColor
    }
}
