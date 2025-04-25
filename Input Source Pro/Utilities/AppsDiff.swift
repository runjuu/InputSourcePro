import AppKit
import Combine

@MainActor
struct AppsDiff {
    let removed: Set<NSRunningApplication>
    let added: Set<NSRunningApplication>
    let all: Set<NSRunningApplication>

    func diff(_ runningApps: Set<NSRunningApplication>) -> AppsDiff {
        let removedApps = all.subtracting(runningApps)
        let addedApps = runningApps.subtracting(all)

        return AppsDiff(removed: removedApps, added: addedApps, all: runningApps)
    }
}

extension AppsDiff {
    static var empty = AppsDiff(removed: [], added: [], all: [])

    static func publisher(preferencesVM: PreferencesVM) -> AnyPublisher<AppsDiff, Never> {
        NSWorkspace.shared
            .publisher(for: \.runningApplications)
            .map { apps in Set(preferencesVM.filterApps(apps)) }
            .scan(.empty) { appsDiff, runningApps -> AppsDiff in
                appsDiff.diff(runningApps)
            }
            .replaceError(with: .empty)
            .eraseToAnyPublisher()
    }
}
