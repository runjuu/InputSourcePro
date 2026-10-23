import SwiftUI

struct KeyboardCustomization: View {
    @EnvironmentObject var preferencesVM: PreferencesVM

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
        VStack(alignment: .leading) {
            ZStack {
                LazyVGrid(columns: indicatorColumns) {
                    DumpIndicatorView(config: IndicatorViewConfig(
                        inputSource: inputSource,
                        kind: .alwaysOn,
                        size: preferencesVM.preferences.indicatorSize ?? .medium,
                        bgColor: NSColor(bgColor.wrappedValue),
                        textColor: NSColor(textColor.wrappedValue)
                    ))

                    DumpIndicatorView(config: IndicatorViewConfig(
                        inputSource: inputSource,
                        kind: preferencesVM.preferences.indicatorKind,
                        size: preferencesVM.preferences.indicatorSize ?? .medium,
                        bgColor: NSColor(bgColor.wrappedValue),
                        textColor: NSColor(textColor.wrappedValue)
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
                        Button(action: { preferencesVM.resetKeyboardColors(inputSource) }) {
                            Text("Use Global Colors")
                        }
                        .buttonStyle(GhostButton(icon: Image(systemName: "arrow.clockwise")))
                    }
                }
                .padding(.trailing, 4)
                .padding(.bottom, 4)
            }

            VStack(alignment: .center) {
                ColorBlocks(onSelectColor: { scheme in
                    preferencesVM.updateKeyboardConfig(inputSource) {
                        $0.textColor = scheme.a
                        $0.bgColor = scheme.b
                    }
                })
                .padding(.vertical, 8)

                HStack {
                    ColorPicker("Color", selection: textColor)

                    Button(
                        action: { preferencesVM.swapKeyboardColors(inputSource) },
                        label: {
                            Image(systemName: "repeat")
                        }
                    )

                    ColorPicker("Background", selection: bgColor)
                }
                .labelsHidden()
            }
            .padding(.horizontal)
        }
        .padding()
        .onDisappear {
            NSColorPanel.shared.close()
        }
    }

    private var textColor: Binding<Color> {
        Binding(
            get: { preferencesVM.getTextColor(inputSource) },
            set: { color in
                preferencesVM.updateKeyboardConfig(inputSource) { $0.textColor = color }
            }
        )
    }

    private var bgColor: Binding<Color> {
        Binding(
            get: { preferencesVM.getBgColor(inputSource) },
            set: { color in
                preferencesVM.updateKeyboardConfig(inputSource) { $0.bgColor = color }
            }
        )
    }
}
