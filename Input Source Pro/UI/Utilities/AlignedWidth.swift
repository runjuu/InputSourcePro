import SwiftUI

// https://stackoverflow.com/a/63997630

// The preference key used to advise parent views of a change in value.
struct AlignedWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    func alignedView(width: Binding<CGFloat>, alignment: Alignment = .trailing) -> some View {
        modifier(AlignedWidthView(width: width, alignment: alignment))
    }
}

struct AlignedWidthView: ViewModifier {
    @Binding var width: CGFloat

    var alignment: Alignment

    func body(content: Content) -> some View {
        content
            .background(GeometryReader {
                Color.clear.preference(
                    key: AlignedWidthPreferenceKey.self,
                    value: $0.frame(in: .local).size.width
                )
            })
            .onPreferenceChange(AlignedWidthPreferenceKey.self) {
                if $0 > self.width {
                    self.width = $0
                }
            }
            .frame(minWidth: width, alignment: alignment)
    }
}
