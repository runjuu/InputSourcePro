import AppKit
import XCTest
@testable import Input_Source_Pro

@MainActor
final class ModifierComboTriggerTests: XCTestCase {
    func testCommandShiftTriggers() {
        let keyboard = Keyboard()

        keyboard.tapCommandShift(at: 1)

        XCTAssertEqual(keyboard.triggerCount, 1)
    }

    func testHoldingComboTooLongDoesNotTrigger() {
        let keyboard = Keyboard()

        keyboard.press(.leftShift, at: 1)
        keyboard.press(.leftCommand, at: 1.05)
        keyboard.release(.leftCommand, at: 1.9)
        keyboard.release(.leftShift, at: 2)

        XCTAssertEqual(keyboard.triggerCount, 0)
    }

    func testExtraModifierPreventsTrigger() {
        let keyboard = Keyboard()

        keyboard.press(.leftControl, at: 1)
        keyboard.tapCommandShift(at: 1.05)
        keyboard.release(.leftControl, at: 1.5)

        XCTAssertEqual(keyboard.triggerCount, 0)
    }

    func testTriggersAfterRightShiftReleasedWhileLeftShiftHeld() {
        let keyboard = Keyboard()

        keyboard.press(.rightShift, at: 1)
        keyboard.press(.leftShift, at: 1.05)
        keyboard.release(.rightShift, at: 1.1)
        keyboard.release(.leftShift, at: 1.15)
        keyboard.tapCommandShift(at: 3)

        XCTAssertEqual(keyboard.triggerCount, 1)
    }

    func testTriggersAfterRightCommandReleasedWhileLeftCommandHeld() {
        let keyboard = Keyboard()

        keyboard.press(.leftCommand, at: 1)
        keyboard.press(.rightCommand, at: 1.05)
        keyboard.release(.rightCommand, at: 1.1)
        keyboard.release(.leftCommand, at: 1.15)
        keyboard.tapCommandShift(at: 3)

        XCTAssertEqual(keyboard.triggerCount, 1)
    }

    func testTriggersAfterMissedModifierRelease() {
        let keyboard = Keyboard()

        keyboard.press(.leftControl, at: 1)
        keyboard.releaseUnnoticed(.leftControl)
        keyboard.tapCommandShift(at: 3)

        XCTAssertEqual(keyboard.triggerCount, 1)
    }

    func testTriggersOnFirstTryAfterMissedReleaseOfComboKey() {
        for commandFirst in [true, false] {
            let keyboard = Keyboard()

            // e.g. Control+Command+Q: both keys go up on the lock screen.
            keyboard.press(.leftControl, at: 1)
            keyboard.press(.leftCommand, at: 1.05)
            keyboard.releaseUnnoticed(.leftControl)
            keyboard.releaseUnnoticed(.leftCommand)
            keyboard.tapCommandShift(at: 3, commandFirst: commandFirst)

            XCTAssertEqual(keyboard.triggerCount, 1, "commandFirst: \(commandFirst)")
        }
    }

    func testEveryComboRecoversFromMissedRelease() {
        let combos: [(combo: ModifierCombo, missed: SingleModifierKey)] = [
            (ModifierCombo(keys: [.rightOption, .rightCommand]), .leftShift),
            (ModifierCombo(keys: [.leftControl]), .rightOption),
            (ModifierCombo(keys: [.rightShift, .rightControl, .leftOption]), .leftCommand),
        ]

        for (combo, missed) in combos {
            let keyboard = Keyboard(combo: combo)

            keyboard.press(missed, at: 1)
            keyboard.releaseUnnoticed(missed)
            keyboard.tapCombo(at: 3)

            XCTAssertEqual(keyboard.triggerCount, 1, combo.displayName)
        }
    }

    func testDoublePressRecoversFromMissedRelease() {
        let keyboard = Keyboard(combo: ModifierCombo(keys: [.rightCommand]), trigger: .doublePress)

        keyboard.press(.leftControl, at: 1)
        keyboard.releaseUnnoticed(.leftControl)
        keyboard.tapCombo(at: 3)
        keyboard.tapCombo(at: 3.2)

        XCTAssertEqual(keyboard.triggerCount, 1)
    }
}

/// Feeds `ShortcutTriggerManager` flagsChanged events shaped like a real keyboard's:
/// each event carries the full modifier state after the change.
@MainActor
private final class Keyboard {
    private static let preferencesVM = PreferencesVM(permissionsVM: PermissionsVM())

    /// The app keeps one `ShortcutTriggerManager` for its whole lifetime, and its `deinit`
    /// hands `self` to a Task, which traps once the object is freed. Never free test ones.
    private static var managers: [ShortcutTriggerManager] = []

    private(set) var triggerCount = 0
    private let manager = ShortcutTriggerManager(preferencesVM: Keyboard.preferencesVM)
    private let combo: ModifierCombo
    private var held: Set<SingleModifierKey> = []

    init(
        combo: ModifierCombo = ModifierCombo(keys: [.leftShift, .leftCommand]),
        trigger: SingleModifierTrigger = .singlePress
    ) {
        self.combo = combo
        Self.managers.append(manager)
        manager.updateBindings([
            ShortcutBinding(
                id: "combo",
                mode: .singleModifier,
                modifierCombo: combo,
                singleModifierTrigger: trigger,
                onTrigger: { [weak self] in self?.triggerCount += 1 }
            ),
        ])
    }

    func press(_ key: SingleModifierKey, at time: TimeInterval) {
        held.insert(key)
        send(key, at: time)
    }

    func release(_ key: SingleModifierKey, at time: TimeInterval) {
        held.remove(key)
        send(key, at: time)
    }

    /// The key goes up without the app receiving a flagsChanged event for it.
    func releaseUnnoticed(_ key: SingleModifierKey) {
        held.remove(key)
    }

    /// Presses every key of the combo, then releases them in reverse order.
    func tapCombo(at time: TimeInterval) {
        var moment = time
        for key in combo.orderedKeys {
            press(key, at: moment)
            moment += 0.05
        }
        for key in combo.orderedKeys.reversed() {
            release(key, at: moment)
            moment += 0.05
        }
    }

    func tapCommandShift(at time: TimeInterval, commandFirst: Bool = true) {
        let (first, second): (SingleModifierKey, SingleModifierKey) = commandFirst
            ? (.leftCommand, .leftShift)
            : (.leftShift, .leftCommand)
        press(first, at: time)
        press(second, at: time + 0.05)
        release(second, at: time + 0.15)
        release(first, at: time + 0.2)
    }

    private func send(_ key: SingleModifierKey, at time: TimeInterval) {
        let event = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(held.map(\.modifierFlag)),
            timestamp: time,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: key.keyCode
        )!
        manager.handleFlagsChanged(event)
    }
}
