import AppKit
import AXSwift
import Combine
import Foundation

extension ApplicationVM {
    static func createWindowAXNotificationPublisher(
        preferencesVM: PreferencesVM
    ) -> AnyPublisher<NSRunningApplication.WatchAXOutput, Never> {
        return preferencesVM.$preferences
            .flatMapLatest { preferences -> AnyPublisher<NSRunningApplication.WatchAXOutput, Never> in
                guard preferences.isEnhancedModeEnabled
                else { return Empty<NSRunningApplication.WatchAXOutput, Never>().eraseToAnyPublisher() }

                return NSWorkspace.shared
                    .publisher(for: \.runningApplications)
                    .map { $0.filter { NSApplication.isFloatingApp($0.bundleIdentifier) } }
                    .removeDuplicates()
                    .flatMapLatest { apps in
                        Publishers.MergeMany(apps
                            .map {
                                $0.watchAX(
                                    [.windowCreated, .uiElementDestroyed],
                                    [.application, .window]
                                )
                            }
                        )
                    }
                    .eraseToAnyPublisher()
            }
            .share()
            .eraseToAnyPublisher()
    }
}
