import AppKit
import XCTest
@testable import Input_Source_Pro

@MainActor
final class AppKeyboardCacheMultiInstanceTests: XCTestCase {
    func testRemoveByBundleIdClearsPerProcessKeys() {
        let suiteName = "isp.cache.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        defaults.set(
            [
                "com.jetbrains.clion#1001": "layout.ru",
                "com.jetbrains.clion#1002": "layout.en",
                "com.jetbrains.clion": "layout.legacy",
                "com.jetbrains.clion_example.com": "layout.site",
                "com.other.app#9": "layout.keep",
            ] as [String: String],
            forKey: "ISPAppKeyboardCache.v1"
        )

        let cache = AppKeyboardCache(defaults: defaults)
        XCTAssertEqual(cache.entryCount, 5)

        cache.remove(byBundleId: "com.jetbrains.clion")
        XCTAssertEqual(cache.entryCount, 1)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testWindowKeyDoesNotFallBackWhenExactMissingIfUsingExactAPI() {
        let suiteName = "isp.cache.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let cache = AppKeyboardCache(defaults: defaults)
        let app = NSRunningApplication.current
        let processKind = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: false, windowId: nil)
        )
        let windowKind = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: false, windowId: "w9")
        )
        let source = InputSource.getCurrentInputSource()

        cache.save(processKind, keyboard: source, liveProcessIdentifiers: [app.processIdentifier])
        XCTAssertNil(cache.retrieveExact(windowKind))
        XCTAssertEqual(cache.retrieve(windowKind)?.persistentIdentifier, source.persistentIdentifier)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testSaveWindowAlsoWritesProcessAndBundleKeys() {
        let suiteName = "isp.cache.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let cache = AppKeyboardCache(defaults: defaults)
        let app = NSRunningApplication.current
        let windowKind = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: false, windowId: "w3")
        )
        let processKind = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: false, windowId: nil)
        )
        let source = InputSource.getCurrentInputSource()
        let bundleId = app.bundleId() ?? app.bundleIdentifier

        cache.save(windowKind, keyboard: source, liveProcessIdentifiers: [app.processIdentifier])
        XCTAssertEqual(cache.retrieveExact(windowKind)?.persistentIdentifier, source.persistentIdentifier)
        XCTAssertEqual(cache.retrieveExact(processKind)?.persistentIdentifier, source.persistentIdentifier)

        let stored = defaults.dictionary(forKey: "ISPAppKeyboardCache.v1") as? [String: String]
        XCTAssertEqual(stored?[bundleId ?? ""], source.persistentIdentifier)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testRetrieveSurvivesRelaunchViaBundleFallback() {
        let suiteName = "isp.cache.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let app = NSRunningApplication.current
        let windowKind = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: false, windowId: "w1")
        )
        let processKind = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: false, windowId: nil)
        )
        let source = InputSource.getCurrentInputSource()

        let cache = AppKeyboardCache(defaults: defaults)
        cache.save(windowKind, keyboard: source, liveProcessIdentifiers: [app.processIdentifier])

        var stored = defaults.dictionary(forKey: "ISPAppKeyboardCache.v1") as? [String: String] ?? [:]
        if let windowId = windowKind.getId() {
            stored.removeValue(forKey: windowId)
        }
        if let processId = processKind.getId() {
            stored.removeValue(forKey: processId)
        }
        defaults.set(stored, forKey: "ISPAppKeyboardCache.v1")

        let relaunched = AppKeyboardCache(defaults: defaults)
        let newWindowKind = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: false, windowId: "w99")
        )

        XCTAssertNil(relaunched.retrieveExact(newWindowKind))
        XCTAssertEqual(
            relaunched.retrieve(newWindowKind)?.persistentIdentifier,
            source.persistentIdentifier
        )

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testSavePrunesUnreachablePidsForSameBundle() {
        let suiteName = "isp.cache.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let app = NSRunningApplication.current
        guard let bundleId = app.bundleId() ?? app.bundleIdentifier else {
            XCTFail("Missing bundle id")
            return
        }

        defaults.set(
            [
                "\(bundleId)#999001": "layout.old",
                "\(bundleId)#999001#w1": "layout.old",
            ] as [String: String],
            forKey: "ISPAppKeyboardCache.v1"
        )

        let cache = AppKeyboardCache(defaults: defaults)
        let windowKind = AppKind.normal(
            app: app,
            info: (focusedElement: nil, isFocusOnInputContainer: false, windowId: "w3")
        )
        let source = InputSource.getCurrentInputSource()
        cache.save(windowKind, keyboard: source, liveProcessIdentifiers: [app.processIdentifier])

        let stored = defaults.dictionary(forKey: "ISPAppKeyboardCache.v1") as? [String: String] ?? [:]
        XCTAssertNil(stored["\(bundleId)#999001"])
        XCTAssertNil(stored["\(bundleId)#999001#w1"])
        XCTAssertEqual(stored[bundleId], source.persistentIdentifier)

        defaults.removePersistentDomain(forName: suiteName)
    }
}
