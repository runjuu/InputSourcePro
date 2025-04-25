import AppKit

extension PreferencesWindowController: NSSharingServicePickerToolbarItemDelegate {
    func items(for _: NSSharingServicePickerToolbarItem) -> [Any] {
        // Compose an array of items that are sharable such as text, URLs, etc.
        // depending on the context of your application (i.e. what the user
        // current has selected in the app and/or they tab they're in).
        let sharableItems = [URL(string: "https://inputsource.pro/")!] as [Any]

        return sharableItems
    }
}

extension PreferencesWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        return []
//    return [.toolbarShareButtonItem]
    }

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.toolbarShareButtonItem]
    }

    func toolbar(
        _: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == NSToolbarItem.Identifier.toolbarShareButtonItem {
            let shareItem = NSSharingServicePickerToolbarItem(itemIdentifier: itemIdentifier)

            shareItem.toolTip = "Share"
            shareItem.delegate = self

            if #available(macOS 11.0, *) {
                shareItem.menuFormRepresentation?.image = NSImage(
                    systemSymbolName: "square.and.arrow.up",
                    accessibilityDescription: nil
                )
            }

            return shareItem
        }

        return nil
    }
}

extension PreferencesWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == .toolbarShareButtonItem {
            return true
        }

        return false
    }
}
