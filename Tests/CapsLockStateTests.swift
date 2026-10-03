import AppKit
import Combine
import XCTest
@testable import Input_Source_Pro

@MainActor
final class CapsLockStateTests: XCTestCase {
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

                for isOn in [true, false] {
                    config.showsCapsLock = false
                    config.badge = .capsLock(isOn: isOn)
                    let badge = try XCTUnwrap(config.render())
                    XCTAssertGreaterThan(badge.fittingSize.width, 0)
                    XCTAssertGreaterThan(badge.fittingSize.height, 0)
                }
            }
        }
    }

    func testCapsLockOnAndOffBadgesAreVisuallyDistinct() {
        let on = IndicatorViewConfig.Badge.capsLock(isOn: true)
        let off = IndicatorViewConfig.Badge.capsLock(isOn: false)
        XCTAssertNotEqual(on.glyph, off.glyph)
        XCTAssertNotEqual(on.title, off.title)
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
                    kind: .iconAndTitle, size: size, bgColor: .black, textColor: .white,
                    showsCapsLock: true
                )
                let source = try XCTUnwrap(config.render())
                let caret = try XCTUnwrap(config.renderAlwaysOn())
                config.showsCapsLock = false
                config.badge = .capsLock(isOn: true)
                let on = try XCTUnwrap(config.render())
                config.badge = .capsLock(isOn: false)
                let off = try XCTUnwrap(config.render())

                var x: CGFloat = 16
                for view in [source, on, off, caret] {
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
}
