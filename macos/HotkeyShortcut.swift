import AppKit
import Carbon
import Foundation

enum WorkflowMode: String, CaseIterable {
    case dictate
    case ask
    case translate

    var title: String {
        switch self {
        case .dictate:
            return "Dictation"
        case .ask:
            return "Ask"
        case .translate:
            return "Translate"
        }
    }
}

enum HotkeyValidationError: LocalizedError {
    case duplicated(with: WorkflowMode)
    case systemReserved(reason: String)
    case unavailable

    var errorDescription: String? {
        let primaryLanguage = Locale.preferredLanguages.first?.lowercased() ?? "en"
        let useEnglish = !primaryLanguage.hasPrefix("zh")
        switch self {
        case .duplicated(let mode):
            return useEnglish
                ? "Hotkey conflicts with \(mode.title). Please choose a different combination."
                : "快捷键与 \(mode.title) 冲突，请使用不同组合。"
        case .systemReserved(let reason):
            return useEnglish
                ? "This hotkey is reserved by macOS (\(reason)). Please choose another one."
                : "该快捷键被系统保留（\(reason)），请更换。"
        case .unavailable:
            return useEnglish
                ? "This hotkey conflicts with macOS or another app and cannot be registered."
                : "该快捷键与系统或其他应用冲突，无法注册。"
        }
    }
}

struct HotkeyShortcut: Codable, Equatable {
    let keyCode: UInt16
    let modifiersRawValue: UInt64
    let requiredModifierKeyCodes: [UInt16]
    let keyLabel: String

    init(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        requiredModifierKeyCodes: [UInt16] = [],
        keyLabel: String
    ) {
        self.keyCode = keyCode
        modifiersRawValue = UInt64(modifiers.hotkeyRelevant.rawValue)
        self.requiredModifierKeyCodes = Array(
            Set(requiredModifierKeyCodes.filter { Self.isModifierKey($0) })
        ).sorted(by: { Self.modifierSortRank($0) < Self.modifierSortRank($1) })
        let trimmed = keyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyLabel = trimmed.isEmpty ? Self.displayName(for: keyCode) : trimmed
    }

    static let defaultDictation = HotkeyShortcut(
        keyCode: 61,
        modifiers: [.option],
        requiredModifierKeyCodes: [61],
        keyLabel: "Right Option"
    )

    static let defaultAsk = HotkeyShortcut(
        keyCode: 49,
        modifiers: [.option],
        requiredModifierKeyCodes: [61],
        keyLabel: "Space"
    )

    static let defaultTranslate = HotkeyShortcut(
        keyCode: 54,
        modifiers: [.option, .command],
        requiredModifierKeyCodes: [61, 54],
        keyLabel: "Right Cmd"
    )

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(modifiersRawValue)).hotkeyRelevant
    }

    var isModifierOnly: Bool {
        Self.isModifierKey(keyCode)
    }

    var displayText: String {
        var parts: [String] = []
        if requiredModifierKeyCodes.isEmpty {
            if modifiers.contains(.control) { parts.append("Control") }
            if modifiers.contains(.option) { parts.append("Option") }
            if modifiers.contains(.shift) { parts.append("Shift") }
            if modifiers.contains(.command) { parts.append("Cmd") }
        } else {
            for code in requiredModifierKeyCodes {
                let name = Self.displayName(for: code)
                if !parts.contains(name) {
                    parts.append(name)
                }
            }
        }

        if !isModifierOnly || !parts.contains(keyLabel) {
            parts.append(keyLabel)
        }

        if parts.isEmpty {
            return keyLabel
        }
        return parts.joined(separator: " + ")
    }

    static func isModifierKey(_ keyCode: UInt16) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }

    static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 55, 54:
            return .command
        case 58, 61:
            return .option
        case 59, 62:
            return .control
        case 56, 60:
            return .shift
        default:
            return nil
        }
    }

    static func displayName(for keyCode: UInt16, fallback: String? = nil) -> String {
        if let mapped = keyDisplayNames[keyCode] {
            return mapped
        }
        if let fallback {
            let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed.uppercased()
            }
        }
        return "Key \(keyCode)"
    }

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62]

    private static func modifierSortRank(_ keyCode: UInt16) -> Int {
        switch keyCode {
        case 59: return 0
        case 62: return 1
        case 58: return 2
        case 61: return 3
        case 56: return 4
        case 60: return 5
        case 55: return 6
        case 54: return 7
        default: return 99
        }
    }

    private static let keyDisplayNames: [UInt16: String] = [
        36: "Return",
        48: "Tab",
        49: "Space",
        50: "`",
        51: "Delete",
        53: "Esc",
        54: "Right Cmd",
        55: "Left Cmd",
        56: "Left Shift",
        57: "Caps Lock",
        58: "Left Option",
        59: "Left Ctrl",
        60: "Right Shift",
        61: "Right Option",
        62: "Right Ctrl",
        63: "Fn",
        123: "Left Arrow",
        124: "Right Arrow",
        125: "Down Arrow",
        126: "Up Arrow",
    ]
}

extension NSEvent.ModifierFlags {
    var hotkeyRelevant: NSEvent.ModifierFlags {
        intersection([.command, .option, .control, .shift])
    }

    var carbonHotkeyMask: UInt32 {
        var mask: UInt32 = 0
        if contains(.command) {
            mask |= UInt32(cmdKey)
        }
        if contains(.option) {
            mask |= UInt32(optionKey)
        }
        if contains(.control) {
            mask |= UInt32(controlKey)
        }
        if contains(.shift) {
            mask |= UInt32(shiftKey)
        }
        return mask
    }
}
