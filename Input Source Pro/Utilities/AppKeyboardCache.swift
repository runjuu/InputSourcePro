import AppKit
import Foundation
import os

@MainActor
class AppKeyboardCache {
    private var cache = [String: String]()

    let logger = ISPLogger(category: String(describing: AppKeyboardCache.self))

    func remove(_ kind: AppKind) {
        if let id = kind.getId(), cache[id] != nil {
            logger.debug { "Remove #\(id)" }
            cache[id] = nil
        }
    }

    func save(_ kind: AppKind, keyboard: InputSource?) {
        guard let id = kind.getId() else { return }

        if let keyboardId = keyboard?.id {
            logger.debug { "Save \(id)#\(keyboardId)" }
            cache[id] = keyboardId
        }
    }

    func retrieve(_ kind: AppKind) -> InputSource? {
        guard let id = kind.getId(),
              let keyboardId = cache[id]
        else { return nil }

        logger.debug { "Retrieve \(id)#\(keyboardId)" }

        return InputSource.sources.first { $0.id == keyboardId }
    }

    func clear() {
        // FIXME: - 部分选择「恢复」的应用/网站应该被忽略
        logger.debug { "Clear All" }
        cache.removeAll()
    }

    func remove(byBundleId bundleId: String) {
        for key in cache.keys {
            if key.starts(with: "\(bundleId)_") {
                logger.debug { "Remove \(bundleId)#\(key)" }
                cache[key] = nil
            }
        }
    }
}
