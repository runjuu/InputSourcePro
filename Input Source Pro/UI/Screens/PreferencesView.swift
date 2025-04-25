import SwiftUI
import VisualEffects

struct PreferencesView: View {
    @EnvironmentObject var navigationVM: NavigationVM
    @EnvironmentObject var preferencesVM: PreferencesVM
    @EnvironmentObject var indicatorVM: IndicatorVM

    @State private var asyncSelection: NavigationVM.Nav = .general

    var body: some View {
        return HStack(spacing: 0) {
            ZStack {
                VisualEffectBlur(material: .sidebar, blendingMode: .behindWindow, state: .followsWindowActiveState)

                HStack {
                    VStack {
                        Button(action: {}) {
                            // Trap default focus ring
                            Text("Input Source Pro")
                        }

                        Spacer()
                    }
                    Spacer()
                }
                .opacity(0)

                VStack(spacing: 12) {
                    ForEach(NavigationVM.Nav.grouped, id: \.id) { group in
                        VStack(spacing: 2) {
                            if !group.title.isEmpty {
                                HStack {
                                    Text(group.title.i18n())
                                        .font(.system(size: 10))
                                        .opacity(0.6)
                                    Spacer()
                                }
                                .padding(.leading, 20)
                                .padding(.bottom, 2)
                            }

                            ForEach(group.nav) { nav in
                                let onSelect = { navigationVM.selection = nav }

                                Button(action: onSelect) {
                                    Text(nav.displayName)
                                }
                                .buttonStyle(
                                    NavButtonStyle(
                                        icon: nav.icon,
                                        isActive: navigationVM.selection == nav
                                    )
                                )
                            }
                        }
                    }

                    Spacer()

                    Text(" \(preferencesVM.versionStr) (\(preferencesVM.buildStr))")
                        .opacity(0.5)
                        .font(.system(size: 12))
                }
                .padding(.top, 40)
                .padding(.vertical)
            }
            .frame(width: 200)

            HStack {
                VStack(spacing: 0) {
                    HStack {
                        SwiftUI.Image(systemName: asyncSelection.icon)
                            .font(.system(size: 18, weight: .medium))
                            .opacity(0.8)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 0) {
                            Text("Input Source Pro")
                                .font(.system(size: 12, weight: .semibold))
                                .opacity(0.8)

                            Text(asyncSelection.displayName)
                                .font(.system(size: 11))
                                .opacity(0.6)
                        }

                        Spacer()
                    }
                    .frame(height: 52)
                    .padding(.horizontal)
                    .border(width: 1, edges: [.bottom], color: NSColor.border.color)

                    asyncSelection.getView()
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)
            }
            .border(width: 1, edges: [.leading], color: NSColor.border.color)
        }
        .frame(minWidth: 780, minHeight: 620)
        .background(NSColor.background.color)
        .environment(\.managedObjectContext, preferencesVM.container.viewContext)
        .onChange(of: navigationVM.selection) { _ in
            asyncSelection = navigationVM.selection
        }
        .onAppear {
            asyncSelection = navigationVM.selection
        }
        .edgesIgnoringSafeArea(.top)
        .modifier(FeedbackModal())
    }
}

extension NavigationVM.Nav {
    var icon: String {
        switch self {
        case .general:
            return "slider.horizontal.3"

        case .appRules:
            return "square.grid.2x2"

        case .browserRules:
            return "safari"

        case .position:
            return "arrow.up.and.down.and.arrow.left.and.right"

        case .appearance:
            return "paintbrush"

        case .inputSourcesColorScheme:
            return "paintpalette"

        case .keyboardShortcut:
            return "command"

        case .troubleshooting:
            return "ladybug"
        }
    }

    var displayName: String {
        switch self {
        case .inputSourcesColorScheme:
            return "Color Scheme".i18n()
        default:
            return rawValue.i18n()
        }
    }

    @ViewBuilder
    func getView() -> some View {
        switch self {
        case .general:
            GeneralSettingsView()

        case .appRules:
            RulesSettingsView()

        case .browserRules:
            BrowserRulesSettingsView()

        case .position:
            PositionSettingsView()

        case .appearance:
            AppearanceSettingsView()

        case .inputSourcesColorScheme:
            InputSourcesAppearanceSettingsView()

        case .keyboardShortcut:
            KeyboardsSettingsView()

        case .troubleshooting:
            TroubleshootingSettingsView()
        }
    }
}

struct NavButtonStyle: ButtonStyle {
    let icon: String

    let isActive: Bool

    func makeBody(configuration: Self.Configuration) -> some View {
        HStack {
            VStack {
                SwiftUI.Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 15, height: 15)
                    .opacity(0.9)
            }

            configuration.label
                .lineLimit(1)

            Spacer()
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(isActive ? Color.gray.opacity(0.2) : Color.clear)
        .background(configuration.isPressed ? Color.gray.opacity(0.1) : Color.clear)
        .foregroundColor(Color.primary)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .padding(.horizontal, 10)
    }
}
