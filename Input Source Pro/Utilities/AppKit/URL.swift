import AppKit

extension URL {
    static let newtab = URL(string: "isp://newtab")!

    func open() {
        NSWorkspace.shared.open(self)
    }

    func bundleId() -> String {
        Bundle(url: self)?.bundleIdentifier ?? dataRepresentation.md5()
    }

    func removeFragment() -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)

        components?.fragment = nil

        return components?.url ?? self
    }
}

extension URL {
    static let website = URL(
        string: "https://inputsource.pro"
    )!

    static let purchase = URL(
        string: "https://inputsource.pro/purchase"
    )!

    static let twitter = URL(
        string: "https://twitter.com/runjuuu"
    )!

    static let emailString = "support@inputsource.pro"

    static let email = URL(string: "mailto:\(emailString)")!

    static let howToEnableAccessbility = URL(
        string: "https://inputsource.pro/help/enable-spotlight-like-apps-support"
    )!

    static let howToEnableBrowserRule = URL(
        string: "https://inputsource.pro/help/enable-browser-rule"
    )!
}
