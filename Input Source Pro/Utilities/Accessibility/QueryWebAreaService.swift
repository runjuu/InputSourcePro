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
