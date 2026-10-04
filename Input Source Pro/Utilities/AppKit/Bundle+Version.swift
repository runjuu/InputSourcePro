import AppKit

extension Bundle {
    var isBetaBuild: Bool {
        infoDictionary?["ISPReleaseChannel"] as? String == "beta"
    }

    var displayVersion: String {
        isBetaBuild ? "Beta" : shortVersion
    }

    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    var buildVersion: Int {
        Int(infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }
}
