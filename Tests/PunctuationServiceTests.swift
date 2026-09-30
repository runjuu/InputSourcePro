import AppKit
import Carbon
import Combine
import XCTest
@testable import Input_Source_Pro

@MainActor
final class PunctuationServiceTests: XCTestCase {
    private final class Environment {
        var inputMonitoring = true
        var accessibility = true
        var anotherInstance = false
        var canCreateTap = true
        var createdTaps = 0
        var invalidatedTaps = 0
        var time: TimeInterval = 0
        var timeStep: TimeInterval = 0
        var inputContext: MarkdownPunctuationMapping.InputContext?

        @MainActor
        func makeService() -> PunctuationService {
            var dependencies = PunctuationService.Dependencies()
            dependencies.hasInputMonitoring = { self.inputMonitoring }
            dependencies.hasAccessibility = { self.accessibility }
            dependencies.hasAnotherInstance = { self.anotherInstance }
            dependencies.createEventTap = { _, _ in
                guard self.canCreateTap else { return nil }
                self.createdTaps += 1
                return PunctuationService.EventTap { self.invalidatedTaps += 1 }
            }
            dependencies.markdownInputContext = { self.inputContext }
            dependencies.now = {
                defer { self.time += self.timeStep }
                return self.time
            }
            return PunctuationService(dependencies: dependencies)
        }
    }

    func testMarkdownUsesEachEventsKeyboardType() throws {
        let environment = Environment()
        environment.inputContext = .init(
            sourceID: "com.apple.inputmethod.SCIM.ITABC",
            inputModeID: "com.apple.inputmethod.SCIM.ITABC",
            keyboardLayoutID: "com.apple.keylayout.PinyinKeyboard"
        )
        let service = environment.makeService()
        try service.enable(mode: .markdown).get()
        let keyEvent = try event()
        keyEvent.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_ANSI_RightBracket))

        for (keyboardType, expected): (Int64, String) in [(40, "]"), (42, "["), (41, "]")] {
            keyEvent.setIntegerValueField(.keyboardEventKeyboardType, value: keyboardType)
            let handled = service.handleKeyEvent(type: .keyDown, event: keyEvent)
            guard handled.takeUnretainedValue() !== keyEvent else {
                XCTFail("Expected a replacement for keyboard type \(keyboardType)")
                continue
            }
            let replacement = handled.takeRetainedValue()
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            replacement.keyboardGetUnicodeString(
                maxStringLength: characters.count,
                actualStringLength: &length,
                unicodeString: &characters
            )
            XCTAssertEqual(String(utf16CodeUnits: characters, count: length), expected)
        }
    }

    func testRejectedRevalidationInvalidatesTapImmediately() throws {
        let environment = Environment()
        let service = environment.makeService()
        try service.enable(mode: .markdown).get()
        environment.anotherInstance = true

        XCTAssertEqual(service.enable(mode: .markdown).failure, .anotherInstanceRunning)
        XCTAssertNil(service.activeMode)
        XCTAssertEqual(environment.invalidatedTaps, 1)
    }

    func testPermissionFailureReportsEachMissingPermission() {
        let environment = Environment()
        environment.inputMonitoring = false
        let service = environment.makeService()

        XCTAssertEqual(
            service.enable(mode: .markdown).failure,
            .missingPermissions(inputMonitoring: true, accessibility: false)
        )
        XCTAssertEqual(environment.createdTaps, 0)
    }

    func testFailedOptInPreservesExistingEnglishTap() throws {
        let environment = Environment()
        let service = environment.makeService()
        try service.enable(mode: .appEnglish).get()
        environment.anotherInstance = true

        XCTAssertEqual(service.enable(mode: .markdown).failure, .anotherInstanceRunning)
        XCTAssertEqual(service.activeMode, .appEnglish)
        XCTAssertEqual(environment.invalidatedTaps, 0)
        XCTAssertEqual(environment.createdTaps, 1)
    }

    func testDisableCleansUpOnlyOnceAndAllowsRestart() throws {
        let environment = Environment()
        let service = environment.makeService()
        try service.enable(mode: .markdown).get()
        service.disable()
        service.disable()
        XCTAssertEqual(environment.invalidatedTaps, 1)

        try service.enable(mode: .markdown).get()
        XCTAssertEqual(service.activeMode, .markdown)
        XCTAssertEqual(environment.createdTaps, 2)
    }

    func testSafetyCallbackCanRestartWithoutStaleCleanupStoppingNewTap() throws {
        let environment = Environment()
        let service = environment.makeService()
        try service.enable(mode: .markdown).get()
        var shutdown: PunctuationService.SafetyShutdown?
        service.onSafetyShutdown = { [weak service] failure in
            shutdown = failure
            XCTAssertNil(service?.activeMode)
            service?.enable(mode: .appEnglish)
        }

        _ = service.handleKeyEvent(type: .tapDisabledByTimeout, event: try event())

        XCTAssertEqual(shutdown, .init(mode: .markdown, failure: .eventTapDisabled))
        XCTAssertEqual(environment.invalidatedTaps, 1)
        XCTAssertEqual(environment.createdTaps, 2)
        XCTAssertEqual(service.activeMode, .appEnglish)
    }

    func testHandlerWatchdogOnlyStopsMarkdown() throws {
        let environment = Environment()
        environment.timeStep = 0.06
        let service = environment.makeService()
        let keyEvent = try event()
        try service.enable(mode: .appEnglish).get()
        _ = service.handleKeyEvent(type: .keyDown, event: keyEvent)
        XCTAssertEqual(service.activeMode, .appEnglish)

        try service.enable(mode: .markdown).get()
        var shutdown: PunctuationService.SafetyShutdown?
        service.onSafetyShutdown = { shutdown = $0 }
        _ = service.handleKeyEvent(type: .keyDown, event: keyEvent)
        XCTAssertNil(service.activeMode)
        XCTAssertEqual(shutdown, .init(mode: .markdown, failure: .handlerTimedOut))
    }

    func testCreationFailureDoesNotReportActiveMarkdown() {
        let environment = Environment()
        environment.canCreateTap = false
        let service = environment.makeService()
        let controller = MarkdownModeController(service: service, shouldEnableAppEnglish: false)
        var preference: Bool?
        controller.onPreferenceChange = { preference = $0 }

        controller.setEnabled(true)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.failure, .eventTapCreationFailed)
        XCTAssertEqual(preference, false)
        XCTAssertNil(service.activeMode)
    }

    func testStartupRequestDoesNotNeedAnAppContext() {
        let environment = Environment()
        let service = environment.makeService()
        let controller = MarkdownModeController(service: service, shouldEnableAppEnglish: false)

        controller.setEnabled(true)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(service.activeMode, .markdown)
        XCTAssertEqual(environment.createdTaps, 1)
    }

    func testRejectedOptInRestoresApplicableEnglishRule() {
        let environment = Environment()
        environment.accessibility = false
        let service = environment.makeService()
        let controller = MarkdownModeController(service: service, shouldEnableAppEnglish: true)

        controller.setEnabled(true)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(service.activeMode, .appEnglish)
        XCTAssertEqual(controller.failure, .missingPermissions(inputMonitoring: false, accessibility: true))
    }

    func testRuntimeRejectionStaysStoppedAcrossAppChangesUntilRetry() {
        let environment = Environment()
        let service = environment.makeService()
        let controller = MarkdownModeController(service: service, shouldEnableAppEnglish: true)
        controller.setEnabled(true)
        environment.anotherInstance = true

        controller.revalidateMarkdown()
        controller.appContextChanged(shouldEnableAppEnglish: true)
        environment.anotherInstance = false
        controller.revalidateMarkdown()

        XCTAssertNil(service.activeMode)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.failure, .anotherInstanceRunning)
        XCTAssertEqual(environment.invalidatedTaps, 1)

        controller.setEnabled(true)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.failure)
        XCTAssertEqual(service.activeMode, .markdown)
    }

    func testRuntimeSafetyShutdownDoesNotFallBackToEnglish() throws {
        let environment = Environment()
        let service = environment.makeService()
        let controller = MarkdownModeController(service: service, shouldEnableAppEnglish: true)
        controller.setEnabled(true)

        _ = service.handleKeyEvent(type: .tapDisabledByUserInput, event: try event())
        controller.appContextChanged(shouldEnableAppEnglish: true)

        XCTAssertNil(service.activeMode)
        XCTAssertEqual(controller.failure, .eventTapDisabled)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(environment.createdTaps, 1)
    }

    func testLegacyTapDisableDoesNotProduceMarkdownFailure() throws {
        let environment = Environment()
        let service = environment.makeService()
        let controller = MarkdownModeController(service: service, shouldEnableAppEnglish: true)
        controller.setEnabled(false)

        _ = service.handleKeyEvent(type: .tapDisabledByTimeout, event: try event())

        XCTAssertNil(service.activeMode)
        XCTAssertNil(controller.failure)
        XCTAssertFalse(controller.isEnabled)
    }

    func testAppRuleUsesIncomingContext() {
        let environment = Environment()
        let service = environment.makeService()
        let controller = MarkdownModeController(service: service, shouldEnableAppEnglish: false)
        controller.setEnabled(false)

        controller.appContextChanged(shouldEnableAppEnglish: true)
        XCTAssertEqual(service.activeMode, .appEnglish)
        controller.appContextChanged(shouldEnableAppEnglish: false)
        XCTAssertNil(service.activeMode)
    }

    func testRejectedPublishedPreferenceCanBeRetriedWithoutAnAppChange() throws {
        @MainActor
        final class PreferenceStore: ObservableObject {
            @Published var preferences: Preferences

            init(defaults: UserDefaults) {
                preferences = Preferences(markdownModeUserDefaults: defaults)
            }

            func update(_ change: (inout Preferences) -> Void) {
                var draft = preferences
                change(&draft)
                preferences = draft
            }
        }

        let suiteName = "PunctuationServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let environment = Environment()
        environment.accessibility = false
        let service = environment.makeService()
        let controller = MarkdownModeController(service: service, shouldEnableAppEnglish: false)
        let store = PreferenceStore(defaults: defaults)
        let subscription = controller.bindPreference(
            values: store.$preferences.map(\.isMarkdownModeEnabled).eraseToAnyPublisher(),
            currentValue: { store.preferences.isMarkdownModeEnabled },
            update: { enabled in store.update { $0.isMarkdownModeEnabled = enabled } }
        )
        let backup = try JSONDecoder().decode(
            SettingsBackupPreferences.self,
            from: Data(#"{"isMarkdownModeEnabled":true}"#.utf8)
        )

        store.update { backup.apply(to: &$0) }
        XCTAssertFalse(store.preferences.isMarkdownModeEnabled)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(service.activeMode)
        XCTAssertEqual(controller.failure, .missingPermissions(inputMonitoring: false, accessibility: true))

        environment.accessibility = true
        store.update { backup.apply(to: &$0) }
        XCTAssertTrue(store.preferences.isMarkdownModeEnabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(service.activeMode, .markdown)
        XCTAssertNil(controller.failure)
        withExtendedLifetime(subscription) {}
    }

    func testUnrelatedDisabledPreferenceDoesNotClearSafetyStop() throws {
        final class PreferenceStore: ObservableObject {
            @Published var enabled = true
        }
        let environment = Environment()
        let service = environment.makeService()
        let controller = MarkdownModeController(service: service, shouldEnableAppEnglish: true)
        let store = PreferenceStore()
        let subscription = controller.bindPreference(
            values: store.$enabled.eraseToAnyPublisher(),
            currentValue: { store.enabled },
            update: { store.enabled = $0 }
        )
        XCTAssertTrue(controller.isEnabled)

        _ = service.handleKeyEvent(type: .tapDisabledByTimeout, event: try event())
        store.enabled = false
        controller.appContextChanged(shouldEnableAppEnglish: true)

        XCTAssertFalse(store.enabled)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(service.activeMode)
        XCTAssertEqual(controller.failure, .eventTapDisabled)
        XCTAssertEqual(environment.createdTaps, 1)
        withExtendedLifetime(subscription) {}
    }

    private func event() throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.type = .keyDown
        event.flags = []
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_ANSI_A))
        event.setIntegerValueField(.eventSourceUserData, value: 0)
        return event
    }
}

private extension Result where Success == Void, Failure == PunctuationService.Failure {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
