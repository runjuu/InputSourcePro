import AppKit
import Combine

class MainStorage: NSObject {
    var keyboardConfigs = CurrentValueSubject<[KeyboardConfig], Never>([])

    let container: NSPersistentContainer

    private lazy var keyboardConfigsFRC: NSFetchedResultsController<KeyboardConfig> = {
        let fetchRequest = KeyboardConfig.fetchRequest()

        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]

        keyboardConfigsFRC = NSFetchedResultsController(
            fetchRequest: fetchRequest,
            managedObjectContext: container.viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )

        keyboardConfigsFRC.delegate = self

        return keyboardConfigsFRC
    }()

    init(container: NSPersistentContainer) {
        self.container = container

        super.init()
    }

    func refresh() {
        do {
            try keyboardConfigsFRC.performFetch()

            if let configs = keyboardConfigsFRC.fetchedObjects {
                keyboardConfigs.send(configs)
            }
        } catch {
            print("MainStorage refresh error: \(error.localizedDescription)")
        }
    }
}

extension MainStorage: NSFetchedResultsControllerDelegate {
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        if let configs = controller.fetchedObjects as? [KeyboardConfig] {
            keyboardConfigs.send(configs)
        }
    }
}
