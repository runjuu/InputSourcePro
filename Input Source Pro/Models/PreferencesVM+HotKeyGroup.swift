import AppKit
import AXSwift
import Foundation

extension PreferencesVM {
    private var didMigrateModeAwareHotKeyGroupsKey: String {
        "didMigrateModeAwareHotKeyGroups"
    }

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

    func migrateHotKeyGroupsIfNeed() {
        guard !UserDefaults.standard.bool(forKey: didMigrateModeAwareHotKeyGroupsKey) else { return }

        let request = NSFetchRequest<HotKeyGroup>(entityName: "HotKeyGroup")

        do {
            let groups = try container.viewContext.fetch(request)

            saveContext {
                for group in groups {
                    let identifiers = group.persistedInputSourceIdentifiers
                    let shouldExpandLegacyIDs = identifiers.allSatisfy {
                        !InputSource.hasModeAwareIdentifier($0)
                    }
                    let migratedIdentifiers = InputSource
                        .resolvePersistedIdentifiers(
                            identifiers,
                            expandingLegacySourceIDs: shouldExpandLegacyIDs
                        )
                        .map(\.persistentIdentifier)

                    if !migratedIdentifiers.isEmpty, migratedIdentifiers != identifiers {
                        group.updatePersistedInputSourceIdentifiers(migratedIdentifiers)
                    }
                }
            }

            UserDefaults.standard.set(true, forKey: didMigrateModeAwareHotKeyGroupsKey)
        } catch {
            print("migrateHotKeyGroups error: \(error.localizedDescription)")
        }
    }
}
