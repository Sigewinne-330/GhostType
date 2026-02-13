import XCTest
@testable import GhostType

final class HotkeyShortcutTests: XCTestCase {
    func testModifierOnlyShortcut() {
        let shortcut = HotkeyShortcut(
            keyCode: 61,
            modifiers: [.option],
            requiredModifierKeyCodes: [61],
            keyLabel: "Right Option"
        )

        XCTAssertTrue(shortcut.isModifierOnly)
    }

    func testDisplayText() {
        let shortcut = HotkeyShortcut.defaultTranslate
        XCTAssertEqual(shortcut.displayText, "Right Option + Right Cmd")
    }

    func testEqualityNormalizesModifierOrder() {
        let lhs = HotkeyShortcut(
            keyCode: 54,
            modifiers: [.command, .option],
            requiredModifierKeyCodes: [61, 54],
            keyLabel: "Right Cmd"
        )
        let rhs = HotkeyShortcut(
            keyCode: 54,
            modifiers: [.option, .command],
            requiredModifierKeyCodes: [54, 61],
            keyLabel: "Right Cmd"
        )

        XCTAssertEqual(lhs, rhs)
    }
}
