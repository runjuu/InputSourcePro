import SwiftUI

@MainActor
class NavigationVM: ObservableObject {
    enum Nav: String, CaseIterable, Identifiable {
        var id: String { rawValue }

        case general = "General"

        case appRules = "App Rules"
        case browserRules = "Browser Rules"

        case position = "Position"
        case appearance = "Appearance"

        case inputSourcesColorScheme = "Input Sources Color Scheme"
        case keyboardShortcut = "Hot Keys"

        case troubleshooting = "Troubleshooting"

        static var grouped: [(id: String, title: String, nav: [Nav])] {
            [
                ("general", "", [.general]),
                ("rule", "Rules", [.appRules, .browserRules]),
                ("theme", "Indicator", [.position, .appearance]),
                ("keyboard", "Keyboard", [.inputSourcesColorScheme, .keyboardShortcut]),
                ("others", "Others", [.troubleshooting]),
            ]
        }
    }

    @Published var selection: Nav = .general
}
