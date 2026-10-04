import AppKit
import Combine
import XCTest
@testable import Input_Source_Pro

@MainActor
final class CapsLockStateTests: XCTestCase {
    func testSwitchingPulsesNeverReachCapsLockStateOrFeedback() {
        let raw = PassthroughSubject<Bool, Never>()
        let confirmed = CurrentValueSubject<Bool, Never>(false)
        var timers: [PassthroughSubject<Void, Never>] = []
        var states: [Bool] = []
        var feedback: [Bool] = []
        let feedbackSubscription = IndicatorVM.capsLockChangesPublisher(
            states: confirmed.eraseToAnyPublisher(),
            enabled: Just(true).eraseToAnyPublisher()
        ).sink { event in
            if case let .capsLockChanges(isOn) = event { feedback.append(isOn) }
        }
        let subscription = IndicatorVM.confirmedCapsLockPublisher(
            states: raw.eraseToAnyPublisher(), initialState: false,
            confirmation: {
                let timer = PassthroughSubject<Void, Never>()
                timers.append(timer)
                return timer.eraseToAnyPublisher()
            }
        ).sink {
            states.append($0)
            confirmed.send($0)
        }

        for _ in 0..<24 {
            raw.send(true)
            raw.send(false)
            timers.last?.send(())
        }
        XCTAssertEqual(timers.count, 24)
        XCTAssertEqual(states, [false])
        XCTAssertEqual(feedback, [])
        subscription.cancel()
        feedbackSubscription.cancel()
    }

    func testSustainedCapsLockConfirmsOnceAndTurnsOffImmediately() {
        let raw = PassthroughSubject<Bool, Never>()
        let timer = PassthroughSubject<Void, Never>()
        var confirmations = 0
        var states: [Bool] = []
        let subscription = IndicatorVM.confirmedCapsLockPublisher(
            states: raw.eraseToAnyPublisher(), initialState: false,
            confirmation: {
                confirmations += 1
                return timer.eraseToAnyPublisher()
            }
        ).sink { states.append($0) }

        raw.send(true)
        raw.send(true) // Other modifier changes must not restart confirmation.
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(states, [false])
        timer.send(())
        timer.send(())
        XCTAssertEqual(states, [false, true])
        raw.send(false)
        XCTAssertEqual(states, [false, true, false])
        subscription.cancel()
    }

    func testInitialCapsLockStateIsAvailableWithoutWaiting() {
        let raw = PassthroughSubject<Bool, Never>()
        var states: [Bool] = []
        let subscription = IndicatorVM.confirmedCapsLockPublisher(
            states: raw.eraseToAnyPublisher(), initialState: true,
            confirmation: { Empty().eraseToAnyPublisher() }
        ).sink { states.append($0) }

        XCTAssertEqual(states, [true])
        raw.send(false)
        XCTAssertEqual(states, [true, false])
        subscription.cancel()
    }

    func testOldConfirmationCannotActivateANewerPendingPulse() {
        let raw = PassthroughSubject<Bool, Never>()
        var timers: [PassthroughSubject<Void, Never>] = []
        var states: [Bool] = []
        let subscription = IndicatorVM.confirmedCapsLockPublisher(
            states: raw.eraseToAnyPublisher(), initialState: false,
            confirmation: {
                let timer = PassthroughSubject<Void, Never>()
                timers.append(timer)
                return timer.eraseToAnyPublisher()
            }
        ).sink { states.append($0) }

        raw.send(true)
        raw.send(false)
        raw.send(true)
        timers[0].send(())
        XCTAssertEqual(states, [false])
        timers[1].send(())
        XCTAssertEqual(states, [false, true])
        raw.send(false)
        raw.send(true)
        subscription.cancel()
        timers[2].send(())
        XCTAssertEqual(states, [false, true, false])
    }

    func testSustainedCapsLockUsesProductionConfirmationTimer() {
        let raw = PassthroughSubject<Bool, Never>()
        let activated = expectation(description: "Caps Lock confirmed")
        var states: [Bool] = []
        let subscription = IndicatorVM.confirmedCapsLockPublisher(
            states: raw.eraseToAnyPublisher(), initialState: false
        ).sink {
            states.append($0)
            if $0 { activated.fulfill() }
        }
        raw.send(true)
        XCTAssertEqual(states, [false])
        wait(for: [activated], timeout: 2)
        XCTAssertEqual(states, [false, true])
        subscription.cancel()
    }

    func testOnlyChangesProduceFeedbackAndDisabledChangesAreNotReplayed() {
        let states = CurrentValueSubject<Bool, Never>(true)
        let enabled = CurrentValueSubject<Bool, Never>(true)
        var changes: [Bool] = []
        let subscription = IndicatorVM.capsLockChangesPublisher(
            states: states.eraseToAnyPublisher(),
            enabled: enabled.eraseToAnyPublisher()
        ).sink { event in
            if case let .capsLockChanges(isOn) = event { changes.append(isOn) }
        }

        XCTAssertEqual(changes, [])
        states.send(true)
        states.send(false)
        states.send(false)
        states.send(true)
        XCTAssertEqual(changes, [false, true])

        enabled.send(false)
        states.send(false)
        enabled.send(true)
        states.send(false)
        XCTAssertEqual(changes, [false, true])

        states.send(true)
        XCTAssertEqual(changes, [false, true, true])
        subscription.cancel()
    }

    func testCapsLockFeedbackPreservesFocusTrackingAndIsIndependentOfOtherTriggers() {
        for isOn in [true, false] {
            let event = IndicatorVM.ActivateEvent.capsLockChanges(isOn)
            for focusedField in [true, false] {
                XCTAssertEqual(IndicatorWindowController.activationMode(
                    event: event, focusedField: focusedField
                ), focusedField ? .autoShow : .autoHide)
            }
            XCTAssertTrue(event.shouldActivateInitially(
                onAppSwitch: false, onInputFocus: false, isInputFocused: false
            ))
        }
    }

    func testCapsLockMarkersFitAllIndicatorStylesAndSizes() throws {
        for size in IndicatorSize.allCases {
            for kind in [IndicatorKind.icon, .title, .iconAndTitle, .alwaysOn] {
                var config = IndicatorViewConfig(
                    inputSource: InputSource.getCurrentInputSource(),
                    kind: kind, size: size, bgColor: .black, textColor: .white
                )
                let original = try XCTUnwrap(config.render())
                config.showsCapsLock = true
                let marked = try XCTUnwrap(config.render())
                XCTAssertGreaterThan(marked.fittingSize.width, original.fittingSize.width)
                XCTAssertGreaterThan(marked.fittingSize.height, 0)

                XCTAssertEqual(labels(in: marked), labels(in: original))
                config.showsCapsLock = false
                let restored = try XCTUnwrap(config.render())
                XCTAssertEqual(restored.fittingSize, original.fittingSize)
                XCTAssertEqual(labels(in: restored), labels(in: original))
            }
        }
    }

    func testInputSourceAndCapsLockEventsKeepTheInputSourceLabel() throws {
        let inputSource = InputSource.getCurrentInputSource()
        let events: [IndicatorVM.ActivateEvent] = [
            .inputSourceChanges(inputSource, .system),
            .capsLockChanges(false),
            .inputSourceChanges(inputSource, .shortcut),
            .capsLockChanges(true),
            .capsLockChanges(false),
        ]

        for event in events {
            let badge = IndicatorWindowController.statusBadge(for: event)
            XCTAssertNil(badge)
            var config = IndicatorViewConfig(
                inputSource: inputSource, kind: .iconAndTitle, size: .medium,
                bgColor: .black, textColor: .white, badge: badge
            )
            if case let .capsLockChanges(isOn) = event {
                config.showsCapsLock = isOn
            }
            let view = try XCTUnwrap(config.render())
            XCTAssertEqual(labels(in: view), [inputSource.name])
        }
    }

    func testFunctionKeyEventsStillRenderTheirStatusBadge() throws {
        for mode in [FKeyMode.functionKeys, .mediaKeys] {
            let badge = try XCTUnwrap(IndicatorWindowController.statusBadge(for: .functionKeyModeChanges(mode)))
            XCTAssertEqual(badge.title, mode.displayName)
            XCTAssertEqual(badge.glyph, mode.badgeGlyph)
        }
    }

    func testRenderCapsLockAppearance() throws {
        let canvas = NSImage(size: NSSize(width: 700, height: 190))
        func draw() throws {
            canvas.lockFocus()
            defer { canvas.unlockFocus() }
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: canvas.size).fill()

            for (row, size) in IndicatorSize.allCases.enumerated() {
                var config = IndicatorViewConfig(
                    inputSource: InputSource.getCurrentInputSource(),
                    kind: .iconAndTitle, size: size, bgColor: .black, textColor: .white
                )
                let off = try XCTUnwrap(config.render())
                config.showsCapsLock = true
                let on = try XCTUnwrap(config.render())
                let caret = try XCTUnwrap(config.renderAlwaysOn())

                var x: CGFloat = 16
                for view in [off, on, caret] {
                    view.setFrameSize(view.fittingSize)
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    bitmap.draw(at: NSPoint(x: x, y: CGFloat(2 - row) * 58 + 16))
                    x += view.frame.width + 24
                }
            }
        }
        try draw()

        let attachment = XCTAttachment(image: canvas)
        attachment.name = "Caps Lock indicator sizes"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPreferencePersistsAndRoundTripsThroughBackup() throws {
        let key = "isShowCapsLockStatus"
        let defaults = UserDefaults.standard
        let saved = Bundle.main.bundleIdentifier
            .flatMap { defaults.persistentDomain(forName: $0)?[key] }
        defer {
            if let saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        var preferences = Preferences()
        XCTAssertTrue(preferences.isShowCapsLockStatus)
        preferences.isShowCapsLockStatus = false
        XCTAssertFalse(Preferences().isShowCapsLockStatus)

        let data = try JSONEncoder().encode(SettingsBackupPreferences(preferences))
        let backup = try JSONDecoder().decode(SettingsBackupPreferences.self, from: data)
        preferences.isShowCapsLockStatus = true
        backup.apply(to: &preferences)
        XCTAssertFalse(preferences.isShowCapsLockStatus)

        let olderBackup = try JSONDecoder().decode(SettingsBackupPreferences.self, from: Data("{}".utf8))
        olderBackup.apply(to: &preferences)
        XCTAssertFalse(preferences.isShowCapsLockStatus)
    }

    private func labels(in view: NSView) -> [String] {
        if let label = view as? NSTextField { return [label.stringValue] }
        return view.subviews.flatMap { labels(in: $0) }
    }
}
