import AppKit

extension NSMenuItem {
    convenience init(
        title string: String,
        target: AnyObject = NSMenuItem.self as AnyObject,
        action selector: Selector?,
        keyEquivalent charCode: String,
        modifier: NSEvent.ModifierFlags = .command
    ) {
        self.init(title: string, action: selector, keyEquivalent: charCode)
        keyEquivalentModifierMask = modifier
        self.target = target
    }

    convenience init(title string: String, submenuItems: [NSMenuItem]) {
        self.init(title: string, action: nil, keyEquivalent: "")
        submenu = NSMenu()
        submenu?.items = submenuItems
    }
}
