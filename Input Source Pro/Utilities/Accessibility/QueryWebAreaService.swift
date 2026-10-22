import AXSwift
import Cocoa
import RxSwift

class QueryWebAreaService {
    let windowElement: Element

    init(windowElement: Element) {
        self.windowElement = windowElement
    }

    func perform() throws -> Element? {
        try fetchScrollArea()
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

    private func fetchScrollArea() throws -> Element? {
        var stack: [Element] = [windowElement]

        while stack.count > 0 {
            let element = stack.popLast()!

            if element.role == "AXWebArea",
               element.url?.scheme != "chrome-extension"
            {
                return element
            }

            let children = try fetchChildren(element) ?? []
            for child in children {
                stack.append(child)
            }
        }

        return nil
    }

    private func fetchChildren(_ element: Element) throws -> [Element]? {
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
