import AXSwift
import Cocoa

extension UIElement {
    func domIdentifier() -> String? {
        return safeString(attribute: .identifier)
    }

    func firefoxDomIdentifier() -> String? {
        return safeString(attribute: "AXDOMIdentifier")
    }

    func safeString(attribute attr: Attribute) -> String? {
        if let anyObject: AnyObject = try? attribute(attr),
           CFGetTypeID(anyObject) == CFStringGetTypeID()
        {
            return anyObject as? String
        } else {
            return nil
        }
    }

    func safeString(attribute attr: String) -> String? {
        if let anyObject: AnyObject = try? attribute(attr),
           CFGetTypeID(anyObject) == CFStringGetTypeID()
        {
            return anyObject as? String
        } else {
            return nil
        }
    }

    func domClassList() -> [String] {
        if let rawDOMClassList: AnyObject = try? attribute("AXDOMClassList"),
           CFGetTypeID(rawDOMClassList) == CFArrayGetTypeID(),
           let domClassList1 = rawDOMClassList as? [AnyObject],
           let rawDOMClass = domClassList1.first,
           CFGetTypeID(rawDOMClass) == CFStringGetTypeID(),
           let domClassList = domClassList1 as? [String]
        {
            return domClassList
        } else {
            return []
        }
    }
}
