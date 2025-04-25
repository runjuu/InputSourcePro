import AXSwift
import Cocoa

class Element {
    let rawElement: AXUIElement
    let role: String
    let url: URL?

    var clippedFrame: NSRect?

    static func initialize(rawElement: AXUIElement) -> Element? {
        let uiElement = UIElement(rawElement)
        let valuesOptional = try? uiElement.getMultipleAttributes([.role, .url])

        guard let values = valuesOptional else { return nil }
        guard let role: String = values[Attribute.role] as! String? else { return nil }

        return Element(rawElement: rawElement, role: role, url: values[Attribute.url] as? URL)
    }

    init(rawElement: AXUIElement, role: String, url: URL?) {
        self.rawElement = rawElement
        self.role = role
        self.url = url
    }
}
