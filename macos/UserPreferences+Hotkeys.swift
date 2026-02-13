import AppKit
import Carbon
import Foundation

extension UserPreferences {
    func shortcut(for mode: WorkflowMode) -> HotkeyShortcut {
        switch mode {
        case .dictate:
            return dictateShortcut
        case .ask:
            return askShortcut
        case .translate:
            return translateShortcut
        }
    }

    @discardableResult
    func applyHotkey(_ shortcut: HotkeyShortcut, for mode: WorkflowMode) -> HotkeyValidationError? {
        if let error = validateHotkey(shortcut, for: mode) {
            return error
        }
        switch mode {
        case .dictate:
            dictateShortcut = shortcut
        case .ask:
            askShortcut = shortcut
        case .translate:
            translateShortcut = shortcut
        }
        return nil
    }

    func validateHotkey(_ shortcut: HotkeyShortcut, for mode: WorkflowMode) -> HotkeyValidationError? {
        for targetMode in WorkflowMode.allCases where targetMode != mode {
            if shortcut == self.shortcut(for: targetMode) {
                return .duplicated(with: targetMode)
            }
        }

        if let reason = Self.systemReservedReason(for: shortcut) {
            return .systemReserved(reason: reason)
        }

        if !shortcut.isModifierOnly, !Self.canRegisterGlobally(shortcut) {
            return .unavailable
        }
        return nil
    }

    func persistShortcut(_ shortcut: HotkeyShortcut, forKey key: String) {
        if let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: key)
        }
    }

    static func loadShortcut(from defaults: UserDefaults, forKey key: String, fallback: HotkeyShortcut) -> HotkeyShortcut {
        if let data = defaults.data(forKey: key),
           let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data) {
            return shortcut
        }
        if let legacyString = defaults.string(forKey: key),
           let legacyData = legacyString.data(using: .utf8),
           let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: legacyData) {
            return shortcut
        }
        return fallback
    }

    private static func canRegisterGlobally(_ shortcut: HotkeyShortcut) -> Bool {
        let hotkeyID = EventHotKeyID(
            signature: 0x4C54594D,
            id: UInt32.random(in: 1...UInt32.max)
        )
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.modifiers.carbonHotkeyMask,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            if let ref {
                UnregisterEventHotKey(ref)
            }
            return true
        }
        return false
    }

    private static func systemReservedReason(for shortcut: HotkeyShortcut) -> String? {
        let key = ReservedShortcutKey(
            keyCode: shortcut.keyCode,
            modifiersRawValue: UInt64(shortcut.modifiers.rawValue)
        )
        return reservedSystemHotkeys[key]
    }

    private static let reservedSystemHotkeys: [ReservedShortcutKey: String] = {
        func mask(_ flags: NSEvent.ModifierFlags) -> UInt64 {
            UInt64(flags.hotkeyRelevant.rawValue)
        }
        return [
            ReservedShortcutKey(keyCode: 49, modifiersRawValue: mask([.command])): "Spotlight",
            ReservedShortcutKey(keyCode: 49, modifiersRawValue: mask([.control])): "Input Source",
            ReservedShortcutKey(keyCode: 49, modifiersRawValue: mask([.command, .option])): "Spotlight Finder",
            ReservedShortcutKey(keyCode: 48, modifiersRawValue: mask([.command])): "App Switcher",
            ReservedShortcutKey(keyCode: 53, modifiersRawValue: mask([.command, .option])): "Force Quit",
            ReservedShortcutKey(keyCode: 12, modifiersRawValue: mask([.command])): "Quit App",
            ReservedShortcutKey(keyCode: 13, modifiersRawValue: mask([.command])): "Close Window",
            ReservedShortcutKey(keyCode: 46, modifiersRawValue: mask([.command])): "Minimize Window",
            ReservedShortcutKey(keyCode: 50, modifiersRawValue: mask([.command])): "Cycle Windows",
        ]
    }()

    private struct ReservedShortcutKey: Hashable {
        let keyCode: UInt16
        let modifiersRawValue: UInt64
    }
}
