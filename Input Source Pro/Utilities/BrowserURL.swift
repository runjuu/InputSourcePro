import AppKit
import AXSwift

private var atlasAddressBarCachedURL: URL?
private var atlasAddressBarObserver: Observer?
private var atlasAddressBarElement: AXUIElement?

private func atlasURLFromAddressBarValue(_ value: String) -> URL? {
    let newtabMarkers = [
        "favorites://",
        "edge://newtab/",
        "chrome://newtab/",
        "chrome://new-tab-page/",
        "chrome://vivaldi-webui/",
        "about:newtab", // Firefox
    ]

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: ","))

    guard !trimmed.isEmpty else { return nil }

    if let url = URL(string: trimmed), url.scheme != nil {
        if newtabMarkers.contains(where: { url.absoluteString.contains($0) }) {
            return .newtab
        }
        return url
    }

    if !trimmed.contains(" "),
       (trimmed.contains(".") || trimmed.contains(":") || trimmed == "localhost"),
       let url = URL(string: "https://\(trimmed)")
    {
        if newtabMarkers.contains(where: { url.absoluteString.contains($0) }) {
            return .newtab
        }
        return url
    }

    return nil
}

private func updateAtlasCachedURL(from value: String) {
    if let url = atlasURLFromAddressBarValue(value) {
        atlasAddressBarCachedURL = url
    }
}

private func findAtlasAddressBarElement(in root: UIElement) -> UIElement? {
    var stack: [UIElement] = [root]

    while let element = stack.popLast() {
        if let role = try? element.role(), role.rawValue == "AXWebArea" {
            continue
        }

        if let role = try? element.role(),
           role == .textField || role == .textArea || role == .comboBox,
           let value = element.safeString(attribute: .value),
           atlasURLFromAddressBarValue(value) != nil
        {
            return element
        }

        stack.append(contentsOf: fetchChildren(of: element))
    }

    return nil
}

private func fetchChildren(of element: UIElement) -> [UIElement] {
    let role = try? element.role()
    let rawElementsOptional: [AXUIElement]? = {
        if role == .table || role == .outline {
            return try? element.attribute(.visibleRows)
        }

        return try? element.attribute(.children)
    }()

    guard let rawElements = rawElementsOptional else {
        return []
    }

    return rawElements.map(UIElement.init)
}

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
    case Atlas = "com.openai.atlas"

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
        case .Atlas:
            return "ChatGPT Atlas"
        }
    }
}

extension Browser {
    func registerAtlasAddressBarObserver(application: Application?, focusedWindow: UIElement) {
        guard self == .Atlas, let application = application else { return }
        guard let addressBarElement = findAtlasAddressBarElement(in: focusedWindow) else { return }

        let rawElement = addressBarElement.element
        if let cachedElement = atlasAddressBarElement,
           CFEqual(cachedElement, rawElement)
        {
            return
        }

        atlasAddressBarObserver?.stop()
        atlasAddressBarElement = rawElement

        atlasAddressBarObserver = application.createObserver { _, element, notification in
            guard notification == .valueChanged,
                  let value = element.safeString(attribute: .value)
            else { return }

            updateAtlasCachedURL(from: value)
        }

        if let value = addressBarElement.safeString(attribute: .value) {
            updateAtlasCachedURL(from: value)
        }

        try? atlasAddressBarObserver?.addNotification(.valueChanged, forElement: addressBarElement)
    }

    func getCurrentTabURL(focusedWindow: UIElement) -> URL? {
        if self == .Atlas,
           let focusedElement: UIElement = try? focusedWindow.attribute(.focusedUIElement),
           let value = focusedElement.safeString(attribute: .value)
        {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ","))
            if !trimmed.isEmpty {
                if let url = URL(string: trimmed), url.scheme != nil {
                    return url
                }
                if !trimmed.contains(" "),
                   (trimmed.contains(".") || trimmed.contains(":") || trimmed == "localhost"),
                   let url = URL(string: "https://\(trimmed)")
                {
                    return url
                }
            }
        }

        if self == .Atlas,
           let focusedElement: UIElement = try? systemWideElement.attribute(.focusedUIElement),
           let value = focusedElement.safeString(attribute: .value)
        {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ","))
            if !trimmed.isEmpty {
                if let url = URL(string: trimmed), url.scheme != nil {
                    return url
                }
                if !trimmed.contains(" "),
                   (trimmed.contains(".") || trimmed.contains(":") || trimmed == "localhost"),
                   let url = URL(string: "https://\(trimmed)")
                {
                    return url
                }
            }
        }

        guard let windowElement = Element.initialize(rawElement: focusedWindow.element),
              let webArea = (try? QueryWebAreaService(windowElement: windowElement).perform()),
              let url = webArea.url
        else {
            if self == .Atlas, let cachedURL = atlasAddressBarCachedURL {
                return cachedURL
            }
            return nil
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
}

extension Browser {
    static func isSupportedBrowser(bundleId: String) -> Bool {
        return allCases.contains { $0.rawValue == bundleId }
    }
}
