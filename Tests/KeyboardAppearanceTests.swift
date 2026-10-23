import AppKit
import Combine
import CoreData
import SwiftUI
import XCTest
@testable import Input_Source_Pro

@MainActor
final class KeyboardAppearanceTests: XCTestCase {
    func testOpeningAndReopeningPanelDoesNotCreateRecords() throws {
        try withPreferences { preferencesVM, source in
            let saves = try countSaves(in: preferencesVM.container.viewContext) {
                for appearance: NSAppearance.Name in [.darkAqua, .aqua] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    for _ in 0..<2 {
                        try withPanel(preferencesVM, source: source) { view in
                            XCTAssertEqual(colorWells(in: view).count, 2)
                            XCTAssertTrue(try preferencesVM.container.viewContext.fetch(KeyboardConfig.fetchRequest()).isEmpty)
                        }
                    }
                }
            }

            XCTAssertEqual(saves, 0)
            XCTAssertFalse(preferencesVM.container.viewContext.hasChanges)
            assertColors(preferencesVM, source: source, appearance: .aqua, text: "111111ff", background: "ee5500ff")
            assertColors(preferencesVM, source: source, appearance: .darkAqua, text: "eeeeeeff", background: "2255eeff")
        }
    }

    func testOpeningPanelPreservesExistingCustomizations() throws {
        let customizations: [(String?, String?)] = [
            ("12ab34d0", "56789ab0"),
            ("eeeeeeff", "2255eeff"),
            (nil, "2255eeff"),
        ]

        for (text, background) in customizations {
            try withPreferences { preferencesVM, source in
                let config = try insertConfig(preferencesVM, source: source, text: text, background: background)
                let saves = countSaves(in: preferencesVM.container.viewContext) {
                    for appearance: NSAppearance.Name in [.darkAqua, .aqua] {
                        NSApp.appearance = NSAppearance(named: appearance)
                        withPanel(preferencesVM, source: source) { _ in
                            XCTAssertEqual(config.textColorHex, text)
                            XCTAssertEqual(config.bgColorHex, background)
                        }
                    }
                }

                XCTAssertEqual(saves, 0)
                let stored = try persistedColors(preferencesVM, source: source)
                XCTAssertEqual(stored.text, text)
                XCTAssertEqual(stored.background, background)
            }
        }
    }

    func testAppearanceAndGlobalColorChangesWhilePanelIsOpenDoNotSaveOverrides() throws {
        try withPreferences { preferencesVM, source in
            let saves = try countSaves(in: preferencesVM.container.viewContext) {
                try withPanel(preferencesVM, source: source) { _ in
                    NSApp.appearance = NSAppearance(named: .aqua)
                    flushUI()
                    assertColors(preferencesVM, source: source, appearance: .aqua, text: "111111ff", background: "ee5500ff")

                    preferencesVM.update {
                        $0.indicatorBackground = IndicatorColor(light: Color(hex: "ff0000ff"), dark: Color(hex: "0000ffff"))
                        $0.isAutoAppearanceMode = false
                        $0.appearanceMode = .dark
                    }
                    flushUI()
                    assertColors(preferencesVM, source: source, appearance: .aqua, text: "eeeeeeff", background: "0000ffff")
                    XCTAssertTrue(try preferencesVM.container.viewContext.fetch(KeyboardConfig.fetchRequest()).isEmpty)
                }
            }
            XCTAssertEqual(saves, 0)
        }
    }

    func testEditingForegroundKeepsBackgroundInherited() throws {
        try withPreferences { preferencesVM, source in
            try withPanel(preferencesVM, source: source) { view in
                let well = try XCTUnwrap(colorWells(in: view).first)
                let saves = try countSaves(in: preferencesVM.container.viewContext) {
                    try chooseColor("00ff00ff", in: well)
                }

                XCTAssertEqual(saves, 1)
                let stored = try persistedColors(preferencesVM, source: source)
                XCTAssertEqual(stored.text, "00ff00ff")
                XCTAssertNil(stored.background)
                assertColors(preferencesVM, source: source, appearance: .aqua, text: "00ff00ff", background: "ee5500ff")
                assertColors(preferencesVM, source: source, appearance: .darkAqua, text: "00ff00ff", background: "2255eeff")
            }
        }
    }

    func testEditingBackgroundKeepsForegroundInherited() throws {
        try withPreferences { preferencesVM, source in
            try withPanel(preferencesVM, source: source) { view in
                let well = try XCTUnwrap(colorWells(in: view).last)
                let saves = try countSaves(in: preferencesVM.container.viewContext) {
                    try chooseColor("ff0000ff", in: well)
                }

                XCTAssertEqual(saves, 1)
                let stored = try persistedColors(preferencesVM, source: source)
                XCTAssertNil(stored.text)
                XCTAssertEqual(stored.background, "ff0000ff")
                assertColors(preferencesVM, source: source, appearance: .aqua, text: "111111ff", background: "ff0000ff")
                assertColors(preferencesVM, source: source, appearance: .darkAqua, text: "eeeeeeff", background: "ff0000ff")
            }
        }
    }

    func testChoosingCurrentInheritedColorCreatesAnExplicitOverride() throws {
        try withPreferences { preferencesVM, source in
            try withPanel(preferencesVM, source: source) { view in
                try chooseColor("eeeeeeff", in: XCTUnwrap(colorWells(in: view).first))

                let stored = try persistedColors(preferencesVM, source: source)
                XCTAssertEqual(stored.text, "eeeeeeff")
                XCTAssertNil(stored.background)

                preferencesVM.update {
                    $0.indicatorForgeground = IndicatorColor(light: .black, dark: .white)
                }
                assertColors(preferencesVM, source: source, appearance: .aqua, text: "eeeeeeff", background: "ee5500ff")
            }
        }
    }

    func testApplyingPaletteSavesBothColorsInOneTransaction() throws {
        try withPreferences { preferencesVM, source in
            let saves = countSaves(in: preferencesVM.container.viewContext) {
                preferencesVM.updateKeyboardConfig(source) {
                    $0.textColor = Color(hex: "eeeeeeff")
                    $0.bgColor = Color(hex: "2255eeff")
                }
            }

            XCTAssertEqual(saves, 1)
            let stored = try persistedColors(preferencesVM, source: source)
            XCTAssertEqual(stored.text, "eeeeeeff")
            XCTAssertEqual(stored.background, "2255eeff")
            assertColors(preferencesVM, source: source, appearance: .aqua, text: "eeeeeeff", background: "2255eeff")
        }
    }

    func testConsecutiveEditsReuseTheConfigAndPreserveTheOtherColor() throws {
        try withPreferences { preferencesVM, source in
            preferencesVM.updateKeyboardConfig(source) { $0.textColor = Color(hex: "00ff00ff") }
            preferencesVM.updateKeyboardConfig(source) { $0.bgColor = Color(hex: "ff0000ff") }

            XCTAssertEqual(try preferencesVM.container.viewContext.count(for: KeyboardConfig.fetchRequest()), 1)
            let stored = try persistedColors(preferencesVM, source: source)
            XCTAssertEqual(stored.text, "00ff00ff")
            XCTAssertEqual(stored.background, "ff0000ff")
        }
    }

    func testSwapSavesTheDisplayedColorsTogether() throws {
        for customText: String? in [nil, "00ff00ff"] {
            try withPreferences { preferencesVM, source in
                if let customText {
                    _ = try insertConfig(preferencesVM, source: source, text: customText, background: nil)
                }
                preferencesVM.preferences.appearanceMode = .light
                let saves = countSaves(in: preferencesVM.container.viewContext) {
                    NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                        preferencesVM.swapKeyboardColors(source)
                    }
                }

                XCTAssertEqual(saves, 1)
                let stored = try persistedColors(preferencesVM, source: source)
                XCTAssertEqual(stored.text, "2255eeff")
                XCTAssertEqual(stored.background, customText ?? "eeeeeeff")
            }
        }
    }

    func testResetClearsMatchingOverridesAndReopeningKeepsInheritance() throws {
        try withPreferences { preferencesVM, source in
            let config = try insertConfig(preferencesVM, source: source, text: "eeeeeeff", background: "2255eeff")
            withPanel(preferencesVM, source: source) { _ in
                let saves = countSaves(in: preferencesVM.container.viewContext) {
                    preferencesVM.resetKeyboardColors(source)
                    flushUI()
                }
                XCTAssertEqual(saves, 1)
                XCTAssertNil(config.textColorHex)
                XCTAssertNil(config.bgColorHex)
            }

            let stored = try persistedColors(preferencesVM, source: source)
            XCTAssertNil(stored.text)
            XCTAssertNil(stored.background)

            NSApp.appearance = NSAppearance(named: .aqua)
            let saves = countSaves(in: preferencesVM.container.viewContext) {
                withPanel(preferencesVM, source: source) { _ in
                    assertColors(preferencesVM, source: source, appearance: .aqua, text: "111111ff", background: "ee5500ff")
                    XCTAssertNil(config.textColorHex)
                    XCTAssertNil(config.bgColorHex)
                }
            }
            XCTAssertEqual(saves, 0)
        }
    }

    func testResetWithoutCustomizationDoesNotCreateARecord() throws {
        try withPreferences { preferencesVM, source in
            let saves = countSaves(in: preferencesVM.container.viewContext) {
                preferencesVM.resetKeyboardColors(source)
            }
            XCTAssertEqual(saves, 0)
            XCTAssertTrue(try preferencesVM.container.viewContext.fetch(KeyboardConfig.fetchRequest()).isEmpty)
        }
    }

    func testExistingOverrideRemainsFixedInAutomaticAndManualModes() throws {
        try withPreferences { preferencesVM, source in
            let config = try insertConfig(preferencesVM, source: source, text: nil, background: "00ff00ff")
            preferencesVM.preferences.isAutoAppearanceMode = false
            preferencesVM.preferences.appearanceMode = .light
            assertColors(preferencesVM, source: source, appearance: .darkAqua, text: "111111ff", background: "00ff00ff")

            preferencesVM.preferences.appearanceMode = .dark
            assertColors(preferencesVM, source: source, appearance: .aqua, text: "eeeeeeff", background: "00ff00ff")

            preferencesVM.preferences.isAutoAppearanceMode = true
            assertColors(preferencesVM, source: source, appearance: .aqua, text: "111111ff", background: "00ff00ff")
            XCTAssertNil(config.textColorHex)
            XCTAssertEqual(config.bgColorHex, "00ff00ff")
        }
    }

    private func withPreferences(_ body: (PreferencesVM, InputSource) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let keys = ["isAutoAppearanceMode", "appearanceMode", "indicatorBackground", "indicatorForgeground"]
        let saved = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        let previousAppearance = NSApp.appearance
        defer {
            NSApp.appearance = previousAppearance
            for key in keys {
                if let value = saved[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let container = NSPersistentContainer(name: "Main", managedObjectModel: PreferencesVM.managedObjectModel)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }

        let preferencesVM = PreferencesVM(permissionsVM: PermissionsVM(), container: container)
        preferencesVM.mainStorage.refresh()
        preferencesVM.update {
            $0.isAutoAppearanceMode = true
            $0.appearanceMode = .dark
            $0.indicatorBackground = IndicatorColor(light: Color(hex: "ee5500ff"), dark: Color(hex: "2255eeff"))
            $0.indicatorForgeground = IndicatorColor(light: Color(hex: "111111ff"), dark: Color(hex: "eeeeeeff"))
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try body(preferencesVM, InputSource.getCurrentInputSource())
    }

    private func withPanel(_ preferencesVM: PreferencesVM, source: InputSource, _ body: (NSView) throws -> Void) rethrows {
        let host = NSHostingView(rootView: KeyboardCustomization(inputSource: source).environmentObject(preferencesVM))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 450),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }
        host.layoutSubtreeIfNeeded()
        flushUI()
        try body(host)
    }

    private func colorWells(in view: NSView) -> [NSColorWell] {
        if let well = view as? NSColorWell { return [well] }
        return view.subviews.flatMap { colorWells(in: $0) }
    }

    private func chooseColor(_ hex: String, in well: NSColorWell) throws {
        well.color = NSColor(hex: hex)
        XCTAssertTrue(well.sendAction(try XCTUnwrap(well.action), to: well.target))
        flushUI()
    }

    private func flushUI() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func countSaves(in context: NSManagedObjectContext, _ body: () throws -> Void) rethrows -> Int {
        var saves = 0
        let observation = NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave, object: context)
            .sink { _ in saves += 1 }
        defer { observation.cancel() }
        try body()
        return saves
    }

    private func insertConfig(_ preferencesVM: PreferencesVM, source: InputSource, text: String?, background: String?) throws -> KeyboardConfig {
        let config = KeyboardConfig(context: preferencesVM.container.viewContext)
        config.id = source.persistentIdentifier
        config.textColorHex = text
        config.bgColorHex = background
        try preferencesVM.container.viewContext.save()
        return config
    }

    private func persistedColors(_ preferencesVM: PreferencesVM, source: InputSource) throws -> (text: String?, background: String?) {
        let sourceID = source.persistentIdentifier
        let reader = preferencesVM.container.newBackgroundContext()
        return try reader.performAndWait {
            let request = KeyboardConfig.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", sourceID)
            let config = try XCTUnwrap(reader.fetch(request).first)
            return (config.textColorHex, config.bgColorHex)
        }
    }

    private func assertColors(_ preferencesVM: PreferencesVM, source: InputSource, appearance: NSAppearance.Name, text: String, background: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let resolvedAppearance = NSAppearance(named: appearance) else {
            XCTFail("Missing appearance: \(appearance.rawValue)", file: file, line: line)
            return
        }
        resolvedAppearance.performAsCurrentDrawingAppearance {
            XCTAssertEqual(preferencesVM.getTextNSColor(source)?.hexWithAlpha, text, file: file, line: line)
            XCTAssertEqual(preferencesVM.getBgNSColor(source)?.hexWithAlpha, background, file: file, line: line)
        }
    }
}
