import AppKit
import AXSwift
import Foundation

extension PreferencesVM {
    func addHotKeyGroup(
        inputSources: [InputSource]
    ) {
        let rule = HotKeyGroup(context: container.viewContext)

        rule.createdAt = Date()
        rule.id = UUID().uuidString
        rule.inputSources = inputSources

        saveContext()
    }

    func deleteHotKeyGroup(_ group: HotKeyGroup) {
        removeShortcutConfig(for: group)
        container.viewContext.delete(group)
        saveContext()
    }

    func updateHotKeyGroup(
        _ group: HotKeyGroup,
        inputSources: [InputSource]
    ) {
        saveContext {
            group.inputSources = inputSources
        }
    }

    func getHotKeyGroups() -> [HotKeyGroup] {
        let request = NSFetchRequest<HotKeyGroup>(entityName: "HotKeyGroup")

        do {
            return try container.viewContext.fetch(request)
        } catch {
            print("getHotKeyGroups() error: \(error.localizedDescription)")
            return []
        }
    }
}
