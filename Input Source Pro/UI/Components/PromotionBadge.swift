import SwiftUI

struct PromotionBadge: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("Promotion".i18n())
            
            Spacer(minLength: 10)
            
            HStack {
                Spacer()
                
                Button("🫶 " + "Share with friends".i18n(), action: {
                    URL(string: "https://inputsource.pro")?.open()
                })
                
                Button("⭐️ " + "Star on GitHub".i18n(), action: {
                    URL(string: "https://github.com/runjuu/InputSourcePro")?.open()
                })
                
                Button("🧡 " + "Sponsor".i18n(), action: {
                    URL(string: "https://github.com/sponsors/runjuu")?.open()
                })
            }
        }
        .padding()
    }
}
