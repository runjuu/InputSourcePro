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
    case Zen = "app.zen-browser.zen"
    case Dia = "company.thebrowser.dia"
    case Helium = "net.imput.helium"
    case Comet = "ai.perplexity.comet"
    case Aside = "at.studio.AsideBrowser"
    case Whale = "com.naver.Whale"

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
        case .Zen:
            return "Zen"
        case .Dia:
            return "Dia"
        case .Helium:
            return "Helium"
        case .Comet:
            return "Comet"
        case .Aside:
            return "Aside"
        case .Whale:
            return "Whale"
        }
    }
}

extension Browser {
    func getCurrentTabURL(focusedWindow: UIElement, focusedElement: UIElement? = nil) -> URL? {
        let documentURL = focusedWindow.safeString(attribute: .document)
            .flatMap { URL(string: $0) }
            .flatMap { $0.scheme == nil ? nil : $0 }

        // These browsers expose sidebars and extension-based new tabs as web areas.
        if self == .Comet || self == .Aside, let documentURL {
            return normalizedTabURL(documentURL)
        }

        guard let windowElement = Element.initialize(rawElement: focusedWindow.element)
        else { return nil }

        let query = QueryWebAreaService(windowElement: windowElement)
        if self == .Whale {
            guard let content = try? query.whaleContent(focusedElement: focusedElement)
            else { return documentURL.map(normalizedTabURL) }

            return selectWhaleTabURL(
                documentURL: documentURL,
                webAreaURLs: content.urls,
                focusedWebAreaURL: content.focusedURL,
                addressBarValue: content.addressBarValue
            )
        }

        guard let webArea = try? query.perform(),
              let url = webArea.url
        else { return nil }

        return normalizedTabURL(url)
    }

    func normalizedTabURL(_ url: URL) -> URL {
        if self == .Whale,
           url.scheme == "chrome-extension",
           url.host == "mdppnmkhoflepinhojdkmkanhhlkginn",
           url.path == "/index.html"
        {
            return .newtab
        }

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

    func selectWhaleTabURL(
        documentURL: URL?,
        webAreaURLs: [URL],
        focusedWebAreaURL: URL?,
        addressBarValue: String?
    ) -> URL? {
        if let focusedWebAreaURL, webAreaURLs.contains(focusedWebAreaURL) {
            return normalizedTabURL(focusedWebAreaURL)
        }

        // Whale's AXDocument stays on the left pane. The omnibox identifies the
        // active pane when focus moves to browser controls or the sidebar.
        if let addressBarValue {
            if let exactMatch = webAreaURLs.first(where: { $0.absoluteString == addressBarValue }) {
                return normalizedTabURL(exactMatch)
            }

            if addressBarValue.isEmpty,
               webAreaURLs.contains(where: { normalizedTabURL($0) == .newtab })
            {
                return .newtab
            }

            let matches = webAreaURLs.filter {
                Self.comparableAddress($0.absoluteString) == Self.comparableAddress(addressBarValue)
            }
            if matches.count == 1 {
                return normalizedTabURL(matches[0])
            }
        }

        return (documentURL ?? webAreaURLs.first).map(normalizedTabURL)
    }

    private static func comparableAddress(_ value: String) -> String {
        let address = value.contains("://") ? value : "https://\(value)"
        guard var components = URLComponents(string: address), let host = components.host
        else { return value }

        components.scheme = nil
        let normalizedHost = host.lowercased()
        components.host = normalizedHost.hasPrefix("www.") ? String(normalizedHost.dropFirst(4)) : normalizedHost
        if components.path == "/" {
            components.path = ""
        }
        return components.string?.removingPercentEncoding ?? value
    }
}

extension Browser {
    static func isSupportedBrowser(bundleId: String) -> Bool {
        return allCases.contains { $0.rawValue == bundleId }
    }
}
