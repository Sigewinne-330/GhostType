import XCTest
@testable import GhostType

@MainActor
final class UserPreferencesTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for suiteName in suiteNames {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    func testHotkeyShortcutSaveAndLoad() {
        let defaults = makeDefaults()
        let prefs = UserPreferences(defaults: defaults)

        let dictate = HotkeyShortcut(
            keyCode: 62,
            modifiers: [.control],
            requiredModifierKeyCodes: [62],
            keyLabel: "Right Ctrl"
        )
        let ask = HotkeyShortcut(
            keyCode: 56,
            modifiers: [.shift],
            requiredModifierKeyCodes: [56],
            keyLabel: "Left Shift"
        )
        let translate = HotkeyShortcut(
            keyCode: 54,
            modifiers: [.command],
            requiredModifierKeyCodes: [54],
            keyLabel: "Right Cmd"
        )

        prefs.dictateShortcut = dictate
        prefs.askShortcut = ask
        prefs.translateShortcut = translate
        prefs.memoryTimeout = .tenMinutes
        prefs.outputLanguage = .japanese
        prefs.smartInsertEnabled = false
        prefs.restoreClipboardAfterPaste = false
        prefs.pretranscribeEnabled = true
        prefs.pretranscribeStepSeconds = 4.5
        prefs.pretranscribeOverlapSeconds = 0.8
        prefs.pretranscribeMaxChunkSeconds = 9.0
        prefs.pretranscribeMinSpeechSeconds = 1.0
        prefs.pretranscribeEndSilenceMS = 280
        prefs.pretranscribeMaxInFlight = 2
        prefs.pretranscribeFallbackPolicy = .off

        let reloaded = UserPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.dictateShortcut, dictate)
        XCTAssertEqual(reloaded.askShortcut, ask)
        XCTAssertEqual(reloaded.translateShortcut, translate)
        XCTAssertEqual(reloaded.memoryTimeout, .tenMinutes)
        XCTAssertEqual(reloaded.outputLanguage, .japanese)
        XCTAssertFalse(reloaded.smartInsertEnabled)
        XCTAssertFalse(reloaded.restoreClipboardAfterPaste)
        XCTAssertTrue(reloaded.pretranscribeEnabled)
        XCTAssertEqual(reloaded.pretranscribeStepSeconds, 4.5, accuracy: 0.0001)
        XCTAssertEqual(reloaded.pretranscribeOverlapSeconds, 0.8, accuracy: 0.0001)
        XCTAssertEqual(reloaded.pretranscribeMaxChunkSeconds, 9.0, accuracy: 0.0001)
        XCTAssertEqual(reloaded.pretranscribeMinSpeechSeconds, 1.0, accuracy: 0.0001)
        XCTAssertEqual(reloaded.pretranscribeEndSilenceMS, 280)
        XCTAssertEqual(reloaded.pretranscribeMaxInFlight, 2)
        XCTAssertEqual(reloaded.pretranscribeFallbackPolicy, .off)
    }

    func testNoHotkeyConflict() {
        let prefs = UserPreferences(defaults: makeDefaults())
        let uniqueShortcut = HotkeyShortcut(
            keyCode: 62,
            modifiers: [.control],
            requiredModifierKeyCodes: [62],
            keyLabel: "Right Ctrl"
        )

        XCTAssertNil(prefs.validateHotkey(uniqueShortcut, for: .ask))
    }

    func testHotkeyConflictDetection() {
        let prefs = UserPreferences(defaults: makeDefaults())
        let conflicting = prefs.dictateShortcut

        let result = prefs.validateHotkey(conflicting, for: .ask)
        guard case .duplicated(let mode)? = result else {
            XCTFail("Expected duplicated error, got \(String(describing: result))")
            return
        }
        XCTAssertEqual(mode, .dictate)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "UserPreferencesTests.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create UserDefaults suite: \(suiteName)")
            return .standard
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
