import SwiftUI

struct NoAnimation: ViewModifier {
    func body(content: Content) -> some View {
        content
            .transaction { transaction in
                transaction.animation = nil
            }
    }
}

extension View {
    func noAnimation() -> some View {
        modifier(NoAnimation())
    }
}
