import AppKit
import SwiftUI

struct PickerItem: Equatable, Identifiable {
    static let mixed = PickerItem(id: "mixed", title: "Mixed", toolTip: nil)
    static let empty = PickerItem(id: "", title: "", toolTip: nil)

    let id: String
    let title: String
    let toolTip: String?
}

struct PopUpButtonPicker<Item: Equatable>: NSViewRepresentable {
    final class Coordinator: NSObject {
        private let parent: PopUpButtonPicker

        init(parent: PopUpButtonPicker) {
            self.parent = parent
        }

        @IBAction
        func selectItem(_ sender: NSPopUpButton) {
            parent.onSelect(sender.indexOfSelectedItem)
        }
    }

    let items: [Item]
    var width: CGFloat? = nil
    var isItemEnabled: (Item) -> Bool = { _ in true }
    let isItemSelected: (Item) -> Bool
    let getTitle: (Item) -> String
    let getToolTip: (Item) -> String?
    let onSelect: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Self.Context) -> NSPopUpButton {
        let popUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
        popUpButton.autoenablesItems = false
        popUpButton.target = context.coordinator
        popUpButton.action = #selector(Coordinator.selectItem(_:))

        if let width = width {
            popUpButton.snp.makeConstraints { make in
                make.width.equalTo(width)
            }
        }

        return popUpButton
    }

    func updateNSView(_ popUpButton: NSPopUpButton, context _: Self.Context) {
        popUpButton.removeAllItems()

        for item in items {
            let menuItem = NSMenuItem()

            // in order for this to work, autoenablesItems must be set to false
            menuItem.isEnabled = isItemEnabled(item)
            menuItem.title = getTitle(item)
            menuItem.toolTip = getToolTip(item)

            popUpButton.menu?.addItem(menuItem)
        }

        if let selectedIndex = items.firstIndex(where: isItemSelected) {
            popUpButton.selectItem(at: selectedIndex)
        }
    }
}
