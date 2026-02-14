import AppKit
import ApplicationServices
import Foundation
import OSLog

enum GlobalHotkeyManagerStartError: LocalizedError {
    case accessibilityNotTrusted
    case monitorRegistrationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Global hotkeys require Accessibility permission."
        case .monitorRegistrationFailed:
            return "Unable to register global keyboard monitors."
        }
    }
}

@MainActor
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    var onModeStart: ((WorkflowMode) -> Void)?
    var onModeStop: ((WorkflowMode) -> Void)?
    var onModePromote: ((WorkflowMode, WorkflowMode) -> Void)?

    private var globalMonitorToken: Any?
    private var localMonitorToken: Any?

    private var dictateShortcut: HotkeyShortcut = .defaultDictation
    private var askShortcut: HotkeyShortcut = .defaultAsk
    private var translateShortcut: HotkeyShortcut = .defaultTranslate

    private var pressedModifierKeyCodes: Set<UInt16> = []
    private var pressedRegularKeyCodes: Set<UInt16> = []
    private var activeMode: WorkflowMode?
    private var activeShortcut: HotkeyShortcut?
    private var isToggleMode = false
    private var keyDownTimestamp: Date?
    private let tapThreshold: TimeInterval = 0.35
    private var suppressStartShortcut: HotkeyShortcut?
    private var lastEventSignature: EventSignature?
    private var didShowAccessibilityAlert = false
    private var pendingModifierStartWorkItem: DispatchWorkItem?
    private let modifierStartDebounce: TimeInterval = 0.08

    private(set) var isRunning = false
    private(set) var lastStartError: GlobalHotkeyManagerStartError?

    private let logger = Logger(subsystem: "com.codeandchill.ghosttype", category: "hotkey")
    private let appLogger = AppLogger.shared

    private init() {
        _ = ensureAccessibilityTrust(prompt: !Self.isRunningUnderXCTest)
    }

    private static var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCInjectBundleInto"] != nil {
            return true
        }

        if NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest") != nil {
            return true
        }

        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }

    func updateHotkeys(dictate: HotkeyShortcut, ask: HotkeyShortcut, translate: HotkeyShortcut) {
        dictateShortcut = dictate
        askShortcut = ask
        translateShortcut = translate

        logger.info(
            "Hotkeys updated. Dictate=\(dictate.displayText, privacy: .public) Ask=\(ask.displayText, privacy: .public) Translate=\(translate.displayText, privacy: .public)"
        )

        if let activeShortcut, !isShortcutPressed(activeShortcut, currentFlags: currentPressedModifierFlags) {
            stopActiveMode(reason: .cancelled)
        }
    }

    @discardableResult
    func start(promptForAccessibility: Bool = true, silent: Bool = false) -> Bool {
        guard !isRunning else { return true }

        guard ensureAccessibilityTrust(prompt: promptForAccessibility, silent: silent) else {
            lastStartError = .accessibilityNotTrusted
            if !silent {
                logger.error("Global hotkey start failed: Accessibility permission missing.")
            }
            return false
        }

        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]

        globalMonitorToken = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleEvent(event)
            }
        }

        localMonitorToken = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleEvent(event)
            return event
        }

        guard globalMonitorToken != nil, localMonitorToken != nil else {
            stop()
            lastStartError = .monitorRegistrationFailed
            logger.error("Global hotkey start failed: monitor registration failed.")
            return false
        }

        isRunning = true
        lastStartError = nil
        logger.info("Global hotkey manager started.")
        return true
    }

    func stop() {
        if let token = globalMonitorToken {
            NSEvent.removeMonitor(token)
            globalMonitorToken = nil
        }
        if let token = localMonitorToken {
            NSEvent.removeMonitor(token)
            localMonitorToken = nil
        }

        pressedModifierKeyCodes.removeAll()
        pressedRegularKeyCodes.removeAll()
        activeMode = nil
        activeShortcut = nil
        isToggleMode = false
        keyDownTimestamp = nil
        suppressStartShortcut = nil
        lastEventSignature = nil
        pendingModifierStartWorkItem?.cancel()
        pendingModifierStartWorkItem = nil
        isRunning = false
        logger.info("Global hotkey manager stopped.")
    }

    private func handleEvent(_ event: NSEvent) {
        if isDuplicateEvent(event) {
            return
        }
        let keyCode = event.keyCode
        let flags = event.modifierFlags.hotkeyRelevant

        switch event.type {
        case .keyDown:
            handleKeyDownEvent(keyCode: keyCode, flags: flags, isAutoRepeat: event.isARepeat)
        case .keyUp:
            handleKeyUpEvent(keyCode: keyCode)
        case .flagsChanged:
            handleFlagsChangedEvent(keyCode: keyCode, flags: flags)
        default:
            break
        }
    }

    private func handleKeyDownEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags, isAutoRepeat: Bool) {
        if !HotkeyShortcut.isModifierKey(keyCode) {
            cancelPendingModifierStart()
            pressedRegularKeyCodes.insert(keyCode)
        }

        if isAutoRepeat {
            return
        }

        if let activeShortcut, let activeMode {
            if isToggleMode, matchesOnKeyDown(activeShortcut, keyCode: keyCode, flags: flags) {
                logger.debug("Toggle stop on keyDown for mode \(activeMode.title, privacy: .public).")
                stopActiveMode(reason: .toggleKeyDown)
                return
            }

            if let candidate = detectModeFromKeyDown(keyCode: keyCode, flags: flags),
               candidate.mode != activeMode,
               shouldPromoteActiveMode(
                   currentMode: activeMode,
                   currentShortcut: activeShortcut,
                   candidate: candidate
               ) {
                promoteActiveMode(from: activeMode, to: candidate.mode, shortcut: candidate.shortcut)
            }
            return
        }

        if matchesOnKeyDown(askShortcut, keyCode: keyCode, flags: flags) {
            guard !isStartSuppressed(for: askShortcut, currentFlags: flags) else { return }
            logger.debug("Matched Ask shortcut on keyDown keyCode=\(keyCode).")
            triggerModeStart(.ask, shortcut: askShortcut)
            return
        }

        if matchesOnKeyDown(translateShortcut, keyCode: keyCode, flags: flags) {
            guard !isStartSuppressed(for: translateShortcut, currentFlags: flags) else { return }
            logger.debug("Matched Translate shortcut on keyDown keyCode=\(keyCode).")
            triggerModeStart(.translate, shortcut: translateShortcut)
            return
        }

        if matchesOnKeyDown(dictateShortcut, keyCode: keyCode, flags: flags) {
            guard !isStartSuppressed(for: dictateShortcut, currentFlags: flags) else { return }
            logger.debug("Matched Dictation shortcut on keyDown keyCode=\(keyCode).")
            triggerModeStart(.dictate, shortcut: dictateShortcut)
        }
    }

    private func handleKeyUpEvent(keyCode: UInt16) {
        if !HotkeyShortcut.isModifierKey(keyCode) {
            pressedRegularKeyCodes.remove(keyCode)
        }

        guard let activeShortcut, let activeMode else {
            clearSuppressedShortcutIfReleased(currentFlags: currentPressedModifierFlags)
            return
        }

        guard !activeShortcut.isModifierOnly else {
            clearSuppressedShortcutIfReleased(currentFlags: currentPressedModifierFlags)
            return
        }

        guard keyCode == activeShortcut.keyCode else {
            clearSuppressedShortcutIfReleased(currentFlags: currentPressedModifierFlags)
            return
        }

        if !isToggleMode {
            handleShortcutReleaseForActiveMode(activeMode)
        }

        clearSuppressedShortcutIfReleased(currentFlags: currentPressedModifierFlags)
    }

    private func handleFlagsChangedEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        updateModifierState(keyCode: keyCode, flags: flags)
        appLogger.log("Raw Flags: \(readableFlags(flags)) | keyCode=\(keyCode)", type: .debug)
        let detected = detectModeFromModifierFlags(flags)
        appLogger.log("Detected mode: [\(detected?.mode.rawValue ?? "None")]", type: .info)

        if let activeShortcut, let activeMode {
            // When in toggle mode and the active modifier combo is no longer fully held,
            // stop the current mode instead of promoting to a less-specific shortcut.
            if isToggleMode, activeShortcut.isModifierOnly,
               !isShortcutPressed(activeShortcut, currentFlags: flags) {
                logger.debug("Toggle stop: active combo partially released for mode \(activeMode.title, privacy: .public).")
                stopActiveMode(reason: .toggleKeyDown)
                clearSuppressedShortcutIfReleased(currentFlags: flags)
                return
            }

            if let detected, detected.mode != activeMode {
                promoteActiveMode(from: activeMode, to: detected.mode, shortcut: detected.shortcut)
                clearSuppressedShortcutIfReleased(currentFlags: flags)
                return
            }

            if activeShortcut.isModifierOnly {
                if isToggleMode {
                    if matchesOnFlagsChanged(activeShortcut, keyCode: keyCode, flags: flags) {
                        logger.debug("Toggle stop on modifier flagsChanged for mode \(activeMode.title, privacy: .public).")
                        appLogger.log("Toggle stop on modifier flagsChanged for mode \(activeMode.title).", type: .warning)
                        stopActiveMode(reason: .toggleKeyDown)
                    }
                } else if !isShortcutPressed(activeShortcut, currentFlags: flags) {
                    appLogger.log("Modifier combo released. Stopping mode \(activeMode.title).")
                    handleShortcutReleaseForActiveMode(activeMode)
                } else if let detected {
                    activeShortcutIfNeeded(detected.shortcut)
                    appLogger.log("Mode remains active: \(activeMode.title) (modifier combo still matched).", type: .debug)
                } else {
                    appLogger.log("No shortcut match while mode is still recording: \(activeMode.title).", type: .debug)
                }
            }

            clearSuppressedShortcutIfReleased(currentFlags: flags)
            return
        }

        if let detected {
            logger.debug("Matched \(detected.mode.title, privacy: .public) shortcut on flagsChanged keyCode=\(keyCode).")
            appLogger.log("flagsChanged matched mode: \(detected.mode.title) | keyCode=\(keyCode)")
            scheduleModifierModeStart(candidate: detected, currentFlags: flags)
        } else {
            cancelPendingModifierStart()
            appLogger.log("flagsChanged matched no mode.", type: .debug)
        }

        clearSuppressedShortcutIfReleased(currentFlags: flags)
    }

    private func updateModifierState(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard let modifier = HotkeyShortcut.modifierFlag(for: keyCode) else { return }
        let isPressed = flags.contains(modifier)
        if isPressed {
            pressedModifierKeyCodes.insert(keyCode)
        } else {
            pressedModifierKeyCodes.remove(keyCode)
        }
    }

    private func matchesOnKeyDown(_ shortcut: HotkeyShortcut, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard !shortcut.isModifierOnly else { return false }
        guard shortcut.keyCode == keyCode else { return false }
        guard flags.containsAll(shortcut.modifiers.hotkeyRelevant) else { return false }
        guard shortcut.requiredModifierKeyCodes.allSatisfy(pressedModifierKeyCodes.contains) else { return false }
        return true
    }

    private func matchesOnFlagsChanged(_ shortcut: HotkeyShortcut, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard shortcut.isModifierOnly else { return false }
        guard shortcut.keyCode == keyCode else { return false }
        return isShortcutPressed(shortcut, currentFlags: flags)
    }

    private func isShortcutPressed(_ shortcut: HotkeyShortcut, currentFlags: NSEvent.ModifierFlags) -> Bool {
        guard currentFlags.containsAll(shortcut.modifiers.hotkeyRelevant) else {
            return false
        }

        guard shortcut.requiredModifierKeyCodes.allSatisfy(pressedModifierKeyCodes.contains) else {
            return false
        }

        if shortcut.isModifierOnly {
            return pressedModifierKeyCodes.contains(shortcut.keyCode)
        }

        return pressedRegularKeyCodes.contains(shortcut.keyCode)
    }

    private func triggerModeStart(_ mode: WorkflowMode, shortcut: HotkeyShortcut) {
        cancelPendingModifierStart()
        triggerModeStartImmediately(mode, shortcut: shortcut)
    }

    private func triggerModeStartImmediately(_ mode: WorkflowMode, shortcut: HotkeyShortcut) {
        guard activeMode == nil else { return }

        activeMode = mode
        activeShortcut = shortcut
        isToggleMode = false
        keyDownTimestamp = Date()
        logger.info("Hotkey mode started: \(mode.title, privacy: .public).")
        onModeStart?(mode)
    }

    private func promoteActiveMode(from currentMode: WorkflowMode, to nextMode: WorkflowMode, shortcut: HotkeyShortcut) {
        cancelPendingModifierStart()
        activeMode = nextMode
        activeShortcut = shortcut
        isToggleMode = false
        logger.info("Hotkey mode promoted: \(currentMode.title, privacy: .public) -> \(nextMode.title, privacy: .public).")
        appLogger.log("Mode promoted: \(currentMode.title) -> \(nextMode.title)")
        onModePromote?(currentMode, nextMode)
    }

    private func activeShortcutIfNeeded(_ shortcut: HotkeyShortcut) {
        if activeShortcut != shortcut {
            activeShortcut = shortcut
        }
    }

    private func stopActiveMode(reason: StopReason) {
        guard let mode = activeMode else { return }
        cancelPendingModifierStart()

        if reason == .toggleKeyDown, let shortcut = activeShortcut {
            suppressStartShortcut = shortcut
        }

        activeMode = nil
        activeShortcut = nil
        isToggleMode = false
        keyDownTimestamp = nil
        logger.info("Hotkey mode stopped: \(mode.title, privacy: .public).")
        onModeStop?(mode)
    }

    private func scheduleModifierModeStart(
        candidate: (mode: WorkflowMode, shortcut: HotkeyShortcut),
        currentFlags: NSEvent.ModifierFlags
    ) {
        guard candidate.shortcut.isModifierOnly else {
            guard !isStartSuppressed(for: candidate.shortcut, currentFlags: currentFlags) else { return }
            triggerModeStartImmediately(candidate.mode, shortcut: candidate.shortcut)
            return
        }

        guard !isStartSuppressed(for: candidate.shortcut, currentFlags: currentFlags) else { return }
        pendingModifierStartWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingModifierStartWorkItem = nil
            guard self.activeMode == nil else { return }

            let settledFlags = self.currentPressedModifierFlags
            guard let settled = self.detectModeFromModifierFlags(settledFlags) else { return }
            guard !self.isStartSuppressed(for: settled.shortcut, currentFlags: settledFlags) else { return }
            self.triggerModeStartImmediately(settled.mode, shortcut: settled.shortcut)
        }
        pendingModifierStartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + modifierStartDebounce, execute: workItem)
    }

    private func cancelPendingModifierStart() {
        pendingModifierStartWorkItem?.cancel()
        pendingModifierStartWorkItem = nil
    }

    private func handleShortcutReleaseForActiveMode(_ mode: WorkflowMode) {
        guard let keyDownTimestamp else {
            stopActiveMode(reason: .holdRelease)
            return
        }

        let pressDuration = Date().timeIntervalSince(keyDownTimestamp)
        if pressDuration > tapThreshold {
            logger.debug("Hold release stop for mode \(mode.title, privacy: .public); duration=\(pressDuration).")
            stopActiveMode(reason: .holdRelease)
        } else {
            isToggleMode = true
            self.keyDownTimestamp = nil
            logger.debug("Tap lock enabled for mode \(mode.title, privacy: .public); duration=\(pressDuration).")
        }
    }

    private func isStartSuppressed(for shortcut: HotkeyShortcut, currentFlags: NSEvent.ModifierFlags) -> Bool {
        guard let suppressed = suppressStartShortcut else { return false }
        guard suppressed == shortcut else { return false }
        guard isShortcutPressed(suppressed, currentFlags: currentFlags) else {
            suppressStartShortcut = nil
            return false
        }
        return true
    }

    private func clearSuppressedShortcutIfReleased(currentFlags: NSEvent.ModifierFlags) {
        guard let suppressed = suppressStartShortcut else { return }
        if !isShortcutPressed(suppressed, currentFlags: currentFlags) {
            suppressStartShortcut = nil
        }
    }

    private func detectModeFromModifierFlags(_ flags: NSEvent.ModifierFlags) -> (mode: WorkflowMode, shortcut: HotkeyShortcut)? {
        // Longest-match-first: more constrained modifier combos win over single modifiers.
        let candidates: [(WorkflowMode, HotkeyShortcut)] = [
            (.translate, translateShortcut),
            (.ask, askShortcut),
            (.dictate, dictateShortcut),
        ]
        .filter { $0.1.isModifierOnly && isShortcutPressed($0.1, currentFlags: flags) }
        .sorted { lhs, rhs in
            let leftSpecificity = shortcutSpecificity(lhs.1)
            let rightSpecificity = shortcutSpecificity(rhs.1)
            if leftSpecificity != rightSpecificity {
                return leftSpecificity > rightSpecificity
            }
            return modePriority(lhs.0) > modePriority(rhs.0)
        }

        return candidates.first
    }

    private func detectModeFromKeyDown(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) -> (mode: WorkflowMode, shortcut: HotkeyShortcut)? {
        let candidates: [(WorkflowMode, HotkeyShortcut)] = [
            (.translate, translateShortcut),
            (.ask, askShortcut),
            (.dictate, dictateShortcut),
        ]
        .filter { matchesOnKeyDown($0.1, keyCode: keyCode, flags: flags) }
        .sorted { lhs, rhs in
            let leftSpecificity = shortcutSpecificity(lhs.1)
            let rightSpecificity = shortcutSpecificity(rhs.1)
            if leftSpecificity != rightSpecificity {
                return leftSpecificity > rightSpecificity
            }
            return modePriority(lhs.0) > modePriority(rhs.0)
        }

        return candidates.first
    }

    private func shouldPromoteActiveMode(
        currentMode: WorkflowMode,
        currentShortcut: HotkeyShortcut,
        candidate: (mode: WorkflowMode, shortcut: HotkeyShortcut)
    ) -> Bool {
        let currentSpecificity = shortcutSpecificity(currentShortcut)
        let candidateSpecificity = shortcutSpecificity(candidate.shortcut)
        if candidateSpecificity != currentSpecificity {
            return candidateSpecificity > currentSpecificity
        }
        return modePriority(candidate.mode) > modePriority(currentMode)
    }

    private func shortcutSpecificity(_ shortcut: HotkeyShortcut) -> Int {
        let requiredCount = shortcut.requiredModifierKeyCodes.count
        let flagCount = shortcut.modifiers.hotkeyRelevant.rawValue.nonzeroBitCount
        return requiredCount * 10 + flagCount
    }

    private func modePriority(_ mode: WorkflowMode) -> Int {
        switch mode {
        case .translate:
            return 3
        case .ask:
            return 2
        case .dictate:
            return 1
        }
    }

    private func readableFlags(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.option) { parts.append("Option") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Command") }
        if flags.contains(.control) { parts.append("Control") }
        return parts.isEmpty ? "None" : parts.joined(separator: ", ")
    }

    private func isDuplicateEvent(_ event: NSEvent) -> Bool {
        let signature = EventSignature(type: event.type, keyCode: event.keyCode, timestamp: event.timestamp)
        defer { lastEventSignature = signature }

        guard let lastEventSignature else { return false }
        return
            lastEventSignature.type == signature.type &&
            lastEventSignature.keyCode == signature.keyCode &&
            abs(lastEventSignature.timestamp - signature.timestamp) < 0.000_1
    }

    @MainActor
    private func ensureAccessibilityTrust(prompt: Bool, silent: Bool = false) -> Bool {
        let isTrusted: Bool
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            isTrusted = AXIsProcessTrustedWithOptions(options)
        } else {
            isTrusted = AXIsProcessTrusted()
        }

        if !isTrusted && !silent {
            print(AppState.shared.ui("警告：系统未授予辅助功能权限，全局监听将失效！", "Warning: Accessibility permission is missing. Global hotkeys will not work."))
            logger.error("Accessibility permission missing for global hotkeys.")
            appLogger.log("Accessibility permission missing for global hotkeys.", type: .error)
            if !Self.isRunningUnderXCTest {
                presentAccessibilityGuidanceIfNeeded()
            }
        }

        return isTrusted
    }

    private func presentAccessibilityGuidanceIfNeeded() {
        guard !didShowAccessibilityAlert else { return }
        didShowAccessibilityAlert = true

        DispatchQueue.main.async { [weak self] in
            guard self != nil else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = AppState.shared.ui("需要“辅助功能”权限", "Accessibility Permission Required")
            alert.informativeText = AppState.shared.ui(
                "请在 系统设置 -> 隐私与安全性 -> 辅助功能 中允许 GhostType（或 Xcode），否则全局快捷键无法在其他应用中生效。",
                "Please allow GhostType (or Xcode) in System Settings -> Privacy & Security -> Accessibility, otherwise global hotkeys will not work in other apps."
            )
            alert.addButton(withTitle: AppState.shared.ui("打开系统设置", "Open System Settings"))
            alert.addButton(withTitle: AppState.shared.ui("稍后", "Later"))

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private var currentPressedModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for keyCode in pressedModifierKeyCodes {
            if let modifier = HotkeyShortcut.modifierFlag(for: keyCode) {
                flags.insert(modifier)
            }
        }
        return flags.hotkeyRelevant
    }

    private enum StopReason {
        case holdRelease
        case toggleKeyDown
        case cancelled
    }

    private struct EventSignature {
        let type: NSEvent.EventType
        let keyCode: UInt16
        let timestamp: TimeInterval
    }
}

private extension NSEvent.ModifierFlags {
    func containsAll(_ flags: NSEvent.ModifierFlags) -> Bool {
        intersection(flags) == flags
    }
}
