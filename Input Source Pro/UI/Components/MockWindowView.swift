import SwiftUI
import VisualEffects

struct MockWindowView: View {
    var body: some View {
        ZStack {
            VisualEffectBlur(
                material: .windowBackground,
                blendingMode: .withinWindow,
                state: .active
            )

            VStack {
                HStack {
                    Circle()
                        .frame(width: 10, height: 10)
                        .foregroundColor(Color(NSColor.close))

                    Circle()
                        .frame(width: 10, height: 10)
                        .foregroundColor(Color(NSColor.minimise))

                    Circle()
                        .frame(width: 10, height: 10)
                        .foregroundColor(Color(NSColor.maximise))
                    Spacer()
                }
                Spacer()
            }
            .padding(10)
        }
        .cornerRadius(9)
        .shadow(color: Color.black.opacity(0.2), radius: 5, x: 3, y: 3)
    }
}
