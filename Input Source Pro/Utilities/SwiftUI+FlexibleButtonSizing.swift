import SwiftUI

private struct FlexibleButtonSizingModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .buttonSizing(.flexible)
        } else {
            content
        }
    }
}

extension View {
    func flexibleButtonSizing() -> some View {
        modifier(FlexibleButtonSizingModifier())
    }
}
