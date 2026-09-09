import AppKit

// MARK: - isFloatingApp

private let floatingAppIdentifier: [(
    identifier: String,
    maxWindowLayer: Int,
    isSpotlightLikeApp: Bool,
    isValid: (((windowLayer: Int?, windowBounds: CGRect?)) -> Bool)?
)] = [
    ("com.apple.Spotlight", 30, true, nil),
    ("com.runningwithcrayons.Alfred", 30, true, nil),
    ("at.obdev.LaunchBar", 30, true, nil),
    ("com.raycast.macos", 30, true, nil),
    ("com.googlecode.iterm2", 30, false, nil),
    ("com.xunyong.hapigo", 30, true, nil),
    ("com.hezongyidev.Bob", 30, false, nil),
    ("com.ripperhe.Bob", 30, false, nil),
    ("org.yuanli.utools", 30, false, nil),
    ("com.1password.1password", 1000, true, nil),
    ("com.eusoft.eudic.LightPeek", 1000, true, nil),
    ("com.contextsformac.Contexts", 1000, true, { $0.windowLayer != 20 }),
]

extension NSApplication {
    static func isFloatingApp(_ bundleIdentifier: String?, windowLayer: Int? = nil, windowBounds: CGRect? = nil) -> Bool {
        guard let bundleIdentifier = bundleIdentifier else { return false }

        return floatingAppIdentifier.contains {
            guard $0.0 == bundleIdentifier else { return false }
            guard let windowLayer = windowLayer else { return true }
            guard windowLayer < $0.1, windowLayer > 0 else { return false }

            return $0.isValid?((windowLayer, windowBounds)) ?? true
        }
    }

    static func isSpotlightLikeApp(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier = bundleIdentifier else { return false }

        return floatingAppIdentifier.contains(where: { $0.isSpotlightLikeApp && $0.identifier == bundleIdentifier })
    }

    static func isBrowser(_ app: NSRunningApplication) -> Bool {
        return getBrowser(app) != nil
    }

    static func getBrowser(_ app: NSRunningApplication) -> Browser? {
        if let bundleIdentifier = app.bundleIdentifier,
           let browser = Browser(rawValue: bundleIdentifier)
        {
            return browser
        } else {
            return nil
        }
    }
}

// MARK: - isBrowserApp

private var browserAppIdentifier: Set<String> = {
    let htmlViewers = LSCopyAllRoleHandlersForContentType(
        "public.html" as CFString, .viewer
    )?.takeRetainedValue() as? [String] ?? []

    let httpsHandlers = httpsURLSchemeHandlers()

    return Set(htmlViewers).intersection(httpsHandlers)
}()

private func httpsURLSchemeHandlers() -> [String] {
    if #available(macOS 12.0, *) {
        return NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://")!)
            .compactMap { Bundle(url: $0)?.bundleIdentifier }
    }
    return legacyHTTPSURLSchemeHandlers()
}

@available(macOS, deprecated: 10.15)
private func legacyHTTPSURLSchemeHandlers() -> [String] {
    LSCopyAllHandlersForURLScheme("https" as CFString)?
        .takeRetainedValue() as? [String] ?? []
}

extension NSApplication {
    static func isBrowserApp(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier = bundleIdentifier else { return false }

        return browserAppIdentifier.contains(bundleIdentifier)
    }

    static func isBrowserInstalled(_ bundleIdentifier: String) -> Bool {
        return isBrowserApp(bundleIdentifier)
    }
}
