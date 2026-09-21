import XCTest
@testable import Input_Source_Pro

@MainActor
final class ShortcutTriggerManagerTests: XCTestCase {
    func testManagerCanBeReleased() {
        let preferencesVM = PreferencesVM(permissionsVM: PermissionsVM())
        var manager: ShortcutTriggerManager? = ShortcutTriggerManager(preferencesVM: preferencesVM)
        manager?.updateBindings([
            ShortcutBinding(
                id: "command-shift",
                mode: .singleModifier,
                modifierCombo: ModifierCombo(keys: [.leftShift, .leftCommand]),
                singleModifierTrigger: .singlePress,
                onTrigger: {}
            ),
        ])
        weak var releasedManager = manager

        manager = nil

        XCTAssertNil(releasedManager)
    }
}
