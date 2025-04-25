import AppKit
import AXSwift

// Update BrowserThatCanWatchBrowserAddressFocus as well
enum Browser: String, CaseIterable {
    case Safari = "com.apple.Safari"
    case SafariTechnologyPreview = "com.apple.SafariTechnologyPreview"
    case Chrome = "com.google.Chrome"
    case Chromium = "org.chromium.Chromium"
    case Arc = "company.thebrowser.Browser"
    case Edge = "com.microsoft.edgemac"
    case Brave = "com.brave.Browser"
    case BraveBeta = "com.brave.Browser.beta"
    case BraveNightly = "com.brave.Browser.nightly"
    case Vivaldi = "com.vivaldi.Vivaldi"
    case Opera = "com.operasoftware.Opera"
    case Thorium = "org.chromium.Thorium"
    case Firefox = "org.mozilla.firefox"
    case FirefoxDeveloperEdition = "org.mozilla.firefoxdeveloperedition"
    case FirefoxNightly = "org.mozilla.nightly"

    var displayName: String {
        switch self {
        case .Safari:
            return "Safari"
        case .SafariTechnologyPreview:
            return "Safari Technology Preview"
        case .Chrome:
            return "Chrome"
        case .Chromium:
            return "Chromium"
        case .Arc:
            return "Arc"
        case .Edge:
            return "Edge"
        case .Brave:
            return "Brave"
        case .BraveBeta:
            return "Brave Beta"
        case .BraveNightly:
            return "Brave Nightly"
        case .Vivaldi:
            return "Vivaldi"
        case .Opera:
            return "Opera"
        case .Thorium:
            return "Thorium"
        case .Firefox:
            return "Firefox"
        case .FirefoxDeveloperEdition:
            return "Firefox Developer Edition"
        case .FirefoxNightly:
            return "Firefox Nightly"
        }
    }
}

extension Browser {
    func getCurrentTabURL(focusedWindow: UIElement) -> URL? {
        guard let windowElement = Element.initialize(rawElement: focusedWindow.element),
              let webArea = (try? QueryWebAreaService(windowElement: windowElement).perform()),
              let url = webArea.url
        else { return nil }

        if [
            "favorites://",
            "edge://newtab/",
            "chrome://newtab/",
            "chrome://new-tab-page/",
            "chrome://vivaldi-webui/",
            "about:newtab", // Firefox
        ].contains(where: { url.absoluteString.contains($0) }) {
            return .newtab
        } else {
            return url
        }
    }
}

extension Browser {
    static func isSupportedBrowser(bundleId: String) -> Bool {
        return allCases.contains { $0.rawValue == bundleId }
    }
}
