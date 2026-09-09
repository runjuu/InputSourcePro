import SwiftUI

private struct FlexibleButtonSizingModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
    }
}

extension View {
    func flexibleButtonSizing() -> some View {
        modifier(FlexibleButtonSizingModifier())
    }
}
