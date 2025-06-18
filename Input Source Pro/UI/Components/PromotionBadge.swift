import SwiftUI

struct PromotionBadge: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("Promotion".i18n())
            
            Spacer(minLength: 10)
            
            HStack {
                Spacer()
                
                Button(action: {
                    URL(string: "https://inputsource.pro")?.open()
                }) {
                    Label {
                        Text("Share with friends".i18n())
                    } icon: {
                        if #available(macOS 15.0, *) {
                            Image(systemName: "square.and.arrow.up.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.primary, .blue)
                                .symbolEffect(.bounce.down.byLayer, options: .repeat(.periodic(delay: 1)))
                        } else {
                            Image(systemName: "square.and.arrow.up.fill")
                                .foregroundColor(.blue)
                        }
                        
                    }
                }
                
                Button(action: {
                    URL(string: "https://github.com/runjuu/InputSourcePro")?.open()
                }) {
                    Label {
                        Text("Star on GitHub".i18n())
                    } icon: {
                        if #available(macOS 15.0, *) {
                            Image(systemName: "star.fill")
                                .symbolRenderingMode(.multicolor)
                                .symbolEffect(.bounce.down.byLayer, options: .repeat(.periodic(delay: 1)))
                        } else {
                            Image(systemName: "star.fill")
                                .foregroundColor(Color(red: 1.0, green: 0.84, blue: 0.0))
                        }
                    }
                }
                
                Button(action: {
                    URL(string: "https://github.com/sponsors/runjuu")?.open()
                }) {
                    Label {
                        Text("Sponsor".i18n())
                    } icon: {
                        if #available(macOS 15.0, *) {
                            Image(systemName: "heart.fill")
                                .symbolRenderingMode(.multicolor)
                                .symbolEffect(.bounce.down.byLayer, options: .repeat(.periodic(delay: 1)))
                        } else {
                            Image(systemName: "heart.fill")
                                .foregroundColor(.pink)
                        }
                    }
                }
            }
        }
        .padding()
    }
}

// add support for Canvas Preview
struct PromotionBadge_Previews: PreviewProvider {
    static var previews: some View {
        PromotionBadge()
            .frame(width: 635, height: 95)
    }
}
