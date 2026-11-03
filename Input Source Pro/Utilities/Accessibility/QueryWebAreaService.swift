import AXSwift
import Cocoa

class QueryWebAreaService {
    let windowElement: Element
    private let fetchChildren: (Element) throws -> [Element]?

    init(
        windowElement: Element,
        fetchChildren: @escaping (Element) throws -> [Element]? = QueryWebAreaService.accessibilityChildren
    ) {
        self.windowElement = windowElement
        self.fetchChildren = fetchChildren
    }

    func perform(documentURL: URL? = nil) throws -> Element? {
        try fetchScrollArea(documentURL: documentURL)
    }

    func whaleContent(focusedElement: UIElement?) throws -> (urls: [URL], focusedURL: URL?, addressBarValue: String?) {
        var stack = [windowElement]
        var webAreas: [Element] = []
        var addressBarValue: String?

        while let element = stack.popLast() {
            let uiElement = UIElement(element.rawElement)
            let classes = uiElement.domClassList()
            if classes.contains("SidebarHost") {
                continue
            }

            if element.role == "AXWebArea" {
                webAreas.append(element)
                continue
            }

            if classes.contains("OmniboxViewViews") {
                addressBarValue = uiElement.safeString(attribute: .value)
            }
            stack.append(contentsOf: try fetchChildren(element) ?? [])
        }

        var focusedURL: URL?
        var ancestor = focusedElement
        for _ in 0..<128 {
            guard let element = ancestor else { break }
            if let webArea = webAreas.first(where: { CFEqual($0.rawElement, element.element) }) {
                focusedURL = webArea.url
                break
            }
            if CFEqual(element.element, windowElement.rawElement) { break }
            ancestor = try? element.attribute(.parent)
        }

        return (webAreas.compactMap(\.url), focusedURL, addressBarValue)
    }

    private func fetchScrollArea(documentURL: URL?) throws -> Element? {
        var stack: [Element] = [windowElement]
        var fallback: Element?

        while let element = stack.popLast() {
            if element.role == "AXWebArea" {
                let url = element.url
                // Chrome keeps this hidden footer in the window after an NTP closes.
                // Other chrome:// pages, including the real NTP, are still eligible.
                guard url?.scheme != "chrome-extension",
                      !(url?.scheme == "chrome" && url?.host == "newtab-footer")
                else { continue }

                if documentURL == nil || url == documentURL {
                    return element
                }
                if fallback == nil {
                    fallback = element
                }
                // Only inspect sibling web areas, not the page's DOM or iframes.
                continue
            }

            do {
                stack.append(contentsOf: try fetchChildren(element) ?? [])
            } catch {
                // Searching for a document match must not discard a usable fallback
                // if another part of the accessibility tree disappears.
                if fallback == nil { throw error }
            }
        }

        return fallback
    }

    private static func accessibilityChildren(_ element: Element) throws -> [Element]? {
        let rawElementsOptional: [AXUIElement]? = try {
            if element.role == "AXTable" || element.role == "AXOutline" {
                return try UIElement(element.rawElement).attribute(.visibleRows)
            }
            return try UIElement(element.rawElement).attribute(.children)
        }()

        guard let rawElements = rawElementsOptional else {
            return nil
        }

        return rawElements
            .map { Element.initialize(rawElement: $0) }
            .compactMap { $0 }
    }
}
