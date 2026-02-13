import AppKit
import CoreGraphics
import Foundation

enum ResolvedTargetKind {
    case axElement(AXUIElement)
    case pasteFallback
}

enum ResolvedTargetSource: String {
    case focusedElement
    case windowSearch
    case unavailable
}

struct ResolvedTarget {
    let kind: ResolvedTargetKind
    let source: ResolvedTargetSource
    let confidence: Double
    let debugInfo: String
}

enum InsertPathKind: String {
    case axFocusedElement
    case axWindowSearch
    case pasteFallback
}

struct InsertOutcome {
    let path: InsertPathKind
    let success: Bool
    let debugInfo: String
    let clipboardRestore: ClipboardRestoreResult?
    let resolverSource: ResolvedTargetSource
}

@MainActor
final class TargetResolver {
    private struct CacheEntry {
        let fingerprint: String
        let updatedAt: Date
    }

    private var cacheByBundleID: [String: CacheEntry] = [:]
    private let candidateKeywords = [
        "message", "chat", "prompt", "input", "send", "reply",
        "输入", "消息", "发送", "提问", "回复"
    ]

    func resolve(preferredTargetApp: NSRunningApplication?, snapshot: ContextSnapshot?) -> ResolvedTarget {
        guard AXIsProcessTrusted() else {
            return ResolvedTarget(
                kind: .pasteFallback,
                source: .unavailable,
                confidence: 0.0,
                debugInfo: "Accessibility permission missing."
            )
        }

        guard let targetApp = resolveTargetApplication(preferredTargetApp) else {
            return ResolvedTarget(
                kind: .pasteFallback,
                source: .unavailable,
                confidence: 0.0,
                debugInfo: "No foreground target application."
            )
        }

        let targetPID = targetApp.processIdentifier
        if let focused = focusedElementForTarget(pid: targetPID), isEditableElement(focused) {
            return ResolvedTarget(
                kind: .axElement(focused),
                source: .focusedElement,
                confidence: 0.95,
                debugInfo: "Focused editable element in target app."
            )
        }

        let appElement = AXUIElementCreateApplication(targetPID)
        if let candidate = bestWindowCandidate(
            appElement: appElement,
            targetBundleID: targetApp.bundleIdentifier
        ) {
            return ResolvedTarget(
                kind: .axElement(candidate.element),
                source: .windowSearch,
                confidence: min(0.9, max(0.35, candidate.score / 4.0)),
                debugInfo: "Window candidate matched (\(candidate.debugLabel))."
            )
        }

        return ResolvedTarget(
            kind: .pasteFallback,
            source: .unavailable,
            confidence: 0.1,
            debugInfo: "No editable AX target found. app=\(targetApp.bundleIdentifier ?? "unknown") domain=\(snapshot?.activeDomain ?? "n/a")"
        )
    }

    func recordSuccessfulResolution(_ target: ResolvedTarget, bundleID: String?) {
        guard let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty else {
            return
        }
        guard case .axElement(let element) = target.kind else { return }
        let fingerprint = fingerprint(for: element)
        guard !fingerprint.isEmpty else { return }
        cacheByBundleID[bundleID] = CacheEntry(fingerprint: fingerprint, updatedAt: Date())
    }

    private func resolveTargetApplication(_ preferredTargetApp: NSRunningApplication?) -> NSRunningApplication? {
        if let preferredTargetApp,
           preferredTargetApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            return preferredTargetApp
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        if frontmost.bundleIdentifier == Bundle.main.bundleIdentifier {
            return nil
        }
        return frontmost
    }

    private func focusedElementForTarget(pid targetPID: pid_t) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let focused = elementAttribute(systemWide, attribute: kAXFocusedUIElementAttribute) else {
            return nil
        }
        guard let focusedPID = pid(of: focused), focusedPID == targetPID else {
            return nil
        }
        return focused
    }

    private struct Candidate {
        let element: AXUIElement
        let score: Double
        let debugLabel: String
    }

    private func bestWindowCandidate(appElement: AXUIElement, targetBundleID: String?) -> Candidate? {
        let roots = candidateRootElements(from: appElement)
        guard !roots.isEmpty else { return nil }

        let cachedFingerprint = cachedFingerprintForBundleID(targetBundleID)
        let windowFrame = roots.compactMap(frame(of:)).max(by: { $0.width * $0.height < $1.width * $1.height })

        var best: Candidate?
        var queue: [AXUIElement] = roots
        var index = 0
        var visited = Set<UInt>()
        let maxNodes = 280

        while index < queue.count, visited.count < maxNodes {
            let element = queue[index]
            index += 1

            let identity = elementIdentity(element)
            guard visited.insert(identity).inserted else { continue }

            if isEditableElement(element) {
                let score = scoreCandidate(
                    element,
                    windowFrame: windowFrame,
                    cachedFingerprint: cachedFingerprint
                )
                if score > (best?.score ?? -1) {
                    let role = stringAttribute(element, attribute: kAXRoleAttribute) ?? "unknown"
                    let title = stringAttribute(element, attribute: kAXTitleAttribute) ?? ""
                    best = Candidate(
                        element: element,
                        score: score,
                        debugLabel: "score=\(String(format: "%.2f", score)) role=\(role) title=\(title)"
                    )
                }
            }

            queue.append(contentsOf: childElements(of: element))
        }

        return best
    }

    private func cachedFingerprintForBundleID(_ bundleID: String?) -> String? {
        guard let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty,
              let cacheEntry = cacheByBundleID[bundleID] else {
            return nil
        }
        if Date().timeIntervalSince(cacheEntry.updatedAt) > 86_400 {
            cacheByBundleID.removeValue(forKey: bundleID)
            return nil
        }
        return cacheEntry.fingerprint
    }

    private func candidateRootElements(from appElement: AXUIElement) -> [AXUIElement] {
        if let focusedWindow = elementAttribute(appElement, attribute: kAXFocusedWindowAttribute) {
            return [focusedWindow]
        }
        if let mainWindow = elementAttribute(appElement, attribute: kAXMainWindowAttribute) {
            return [mainWindow]
        }
        let windows = elementArrayAttribute(appElement, attribute: kAXWindowsAttribute)
        if !windows.isEmpty {
            return Array(windows.prefix(3))
        }
        return [appElement]
    }

    private func scoreCandidate(
        _ element: AXUIElement,
        windowFrame: CGRect?,
        cachedFingerprint: String?
    ) -> Double {
        var score = 1.0

        if isAttributeSettable(element, attribute: kAXValueAttribute) {
            score += 1.2
        }
        if boolAttribute(element, attribute: kAXEnabledAttribute) ?? true {
            score += 0.5
        }
        if !(boolAttribute(element, attribute: kAXHiddenAttribute) ?? false) {
            score += 0.3
        }

        if let frame = frame(of: element), frame.width > 0, frame.height > 0 {
            let area = frame.width * frame.height
            score += min(0.8, area / 250_000.0)
            if let windowFrame = windowFrame, windowFrame.width > 0, windowFrame.height > 0 {
                if frame.width >= windowFrame.width * 0.42 {
                    score += 0.35
                }
                let relativeBottom = (frame.minY - windowFrame.minY) / max(windowFrame.height, 1)
                if relativeBottom <= 0.45 || relativeBottom >= 0.55 {
                    score += 0.2
                }
            }
        }

        let metadata = metadataBlob(for: element)
        if candidateKeywords.contains(where: { metadata.contains($0) }) {
            score += 0.9
        }

        let fingerprint = fingerprint(for: element)
        if let cachedFingerprint, !cachedFingerprint.isEmpty, cachedFingerprint == fingerprint {
            score += 1.3
        }

        return score
    }

    private func isEditableElement(_ element: AXUIElement) -> Bool {
        if boolAttribute(element, attribute: "AXEditable") == true {
            return true
        }
        let role = stringAttribute(element, attribute: kAXRoleAttribute) ?? ""
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField"
        ]
        if editableRoles.contains(role) {
            return true
        }
        return isAttributeSettable(element, attribute: kAXValueAttribute)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = axValueAttribute(element, attribute: kAXPositionAttribute),
              let sizeValue = axValueAttribute(element, attribute: kAXSizeAttribute) else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        let visible = elementArrayAttribute(element, attribute: kAXVisibleChildrenAttribute)
        if !visible.isEmpty {
            return visible
        }
        return elementArrayAttribute(element, attribute: kAXChildrenAttribute)
    }

    private func metadataBlob(for element: AXUIElement) -> String {
        let parts = [
            stringAttribute(element, attribute: kAXRoleAttribute) ?? "",
            stringAttribute(element, attribute: kAXSubroleAttribute) ?? "",
            stringAttribute(element, attribute: kAXIdentifierAttribute) ?? "",
            stringAttribute(element, attribute: kAXTitleAttribute) ?? "",
            stringAttribute(element, attribute: kAXDescriptionAttribute) ?? "",
            stringAttribute(element, attribute: kAXHelpAttribute) ?? "",
            stringAttribute(element, attribute: "AXPlaceholderValue") ?? "",
        ]
        return parts
            .joined(separator: "|")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func fingerprint(for element: AXUIElement) -> String {
        metadataBlob(for: element)
    }

    private func pid(of element: AXUIElement) -> pid_t? {
        var processID: pid_t = 0
        let status = AXUIElementGetPid(element, &processID)
        return status == .success ? processID : nil
    }

    private func elementIdentity(_ element: AXUIElement) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(element).toOpaque())
    }

    private func boolAttribute(_ element: AXUIElement, attribute: String) -> Bool? {
        if let value = attributeValueCF(element, attribute: attribute) as? Bool {
            return value
        }
        if let value = attributeValueCF(element, attribute: attribute) as? NSNumber {
            return value.boolValue
        }
        return nil
    }

    private func stringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        if let value = attributeValueCF(element, attribute: attribute) as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func isAttributeSettable(_ element: AXUIElement, attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return result == .success && settable.boolValue
    }

    private func attributeValueCF(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    private func axValueAttribute(_ element: AXUIElement, attribute: String) -> AXValue? {
        guard let value = attributeValueCF(element, attribute: attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXValue.self)
    }

    private func elementAttribute(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = attributeValueCF(element, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func elementArrayAttribute(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        guard let value = attributeValueCF(element, attribute: attribute),
              CFGetTypeID(value) == CFArrayGetTypeID() else {
            return []
        }
        let array = unsafeBitCast(value, to: NSArray.self)
        var output: [AXUIElement] = []
        output.reserveCapacity(array.count)
        for item in array {
            let cfItem = item as CFTypeRef
            guard CFGetTypeID(cfItem) == AXUIElementGetTypeID() else { continue }
            output.append(unsafeBitCast(cfItem, to: AXUIElement.self))
        }
        return output
    }
}

@MainActor
final class TextInserter {
    private let targetResolver: TargetResolver
    private let pasteCoordinator: PasteCoordinator
    private let clipboardService: ClipboardContextService

    init(
        targetResolver: TargetResolver,
        pasteCoordinator: PasteCoordinator,
        clipboardService: ClipboardContextService
    ) {
        self.targetResolver = targetResolver
        self.pasteCoordinator = pasteCoordinator
        self.clipboardService = clipboardService
    }

    func insert(
        _ text: String,
        preferredTargetApp: NSRunningApplication?,
        snapshot: ContextSnapshot?,
        sessionID: UUID,
        useSmartInsert: Bool,
        restoreClipboard: Bool,
        dispatchDelay: TimeInterval,
        logger: AppLogger,
        completion: @escaping (InsertOutcome) -> Void
    ) {
        let resolvedTarget: ResolvedTarget = {
            guard useSmartInsert else {
                return ResolvedTarget(
                    kind: .pasteFallback,
                    source: .unavailable,
                    confidence: 0.0,
                    debugInfo: "Smart insert disabled."
                )
            }
            return targetResolver.resolve(
                preferredTargetApp: preferredTargetApp,
                snapshot: snapshot
            )
        }()

        if case .axElement(let element) = resolvedTarget.kind,
           useSmartInsert,
           insertViaAccessibility(text, into: element) {
            targetResolver.recordSuccessfulResolution(
                resolvedTarget,
                bundleID: preferredTargetApp?.bundleIdentifier ?? snapshot?.frontmostAppBundleId
            )
            let insertPath: InsertPathKind = resolvedTarget.source == .focusedElement
                ? .axFocusedElement
                : .axWindowSearch
            completion(
                InsertOutcome(
                    path: insertPath,
                    success: true,
                    debugInfo: "\(resolvedTarget.debugInfo) confidence=\(String(format: "%.2f", resolvedTarget.confidence))",
                    clipboardRestore: nil,
                    resolverSource: resolvedTarget.source
                )
            )
            return
        }

        let clipboardSnapshot = clipboardService.snapshotCurrentPasteboard()
        let expectedChangeCount = clipboardService.writeTextPayload(text)

        pasteCoordinator.paste(
            to: preferredTargetApp,
            sessionID: sessionID,
            dispatchDelay: dispatchDelay,
            logger: logger
        ) { [weak self] didDispatch in
            guard let self else { return }
            let restoreResult = self.clipboardService.restoreSnapshotIfUnchanged(
                clipboardSnapshot,
                expectedChangeCount: expectedChangeCount,
                restoreEnabled: restoreClipboard
            )
            completion(
                InsertOutcome(
                    path: .pasteFallback,
                    success: didDispatch,
                    debugInfo: "\(resolvedTarget.debugInfo) -> pasteDispatch=\(didDispatch ? "ok" : "failed")",
                    clipboardRestore: restoreResult,
                    resolverSource: resolvedTarget.source
                )
            )
        }
    }

    private func insertViaAccessibility(_ text: String, into element: AXUIElement) -> Bool {
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)

        if insertIntoSelectedRange(text, element: element) {
            return true
        }
        return replaceValue(text, element: element)
    }

    private func insertIntoSelectedRange(_ text: String, element: AXUIElement) -> Bool {
        guard let currentValue = stringAttribute(element, attribute: kAXValueAttribute),
              let selected = selectedTextRange(of: element),
              isAttributeSettable(element, attribute: kAXValueAttribute) else {
            return false
        }

        let valueNSString = currentValue as NSString
        let location = max(0, min(selected.location, valueNSString.length))
        let length = max(0, min(selected.length, valueNSString.length - location))
        let replaceRange = NSRange(location: location, length: length)
        let updated = valueNSString.replacingCharacters(in: replaceRange, with: text)

        let setStatus = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updated as CFTypeRef
        )
        guard setStatus == .success else { return false }

        let cursorLocation = location + (text as NSString).length
        setSelectedTextRange(
            element,
            range: NSRange(location: cursorLocation, length: 0)
        )
        return true
    }

    private func replaceValue(_ text: String, element: AXUIElement) -> Bool {
        guard isAttributeSettable(element, attribute: kAXValueAttribute) else { return false }
        let setStatus = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        )
        guard setStatus == .success else { return false }
        setSelectedTextRange(
            element,
            range: NSRange(location: (text as NSString).length, length: 0)
        )
        return true
    }

    private func selectedTextRange(of element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        )
        guard status == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func setSelectedTextRange(_ element: AXUIElement, range: NSRange) {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return }
        _ = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )
    }

    private func isAttributeSettable(_ element: AXUIElement, attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return status == .success && settable.boolValue
    }

    private func stringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return nil }
        return value as? String
    }
}

@MainActor
final class PasteCoordinator {
    func resolveCurrentTargetApplication() -> NSRunningApplication? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let currentBundleID = Bundle.main.bundleIdentifier
        if frontmost.bundleIdentifier == currentBundleID {
            return nil
        }
        return frontmost
    }

    func paste(
        to targetApp: NSRunningApplication?,
        sessionID: UUID,
        dispatchDelay: TimeInterval,
        logger: AppLogger,
        completion: @escaping (Bool) -> Void
    ) {
        if #available(macOS 14.0, *) {
            targetApp?.activate(options: [.activateAllWindows])
        } else {
            targetApp?.activate(options: [.activateIgnoringOtherApps])
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + dispatchDelay) { [weak self] in
            let dispatched = self?.dispatchPasteShortcut(sessionID: sessionID, logger: logger) ?? false
            completion(dispatched)
        }
    }

    func undoThenPaste(
        to targetApp: NSRunningApplication?,
        sessionID: UUID,
        dispatchDelay: TimeInterval,
        logger: AppLogger,
        completion: @escaping (Bool) -> Void
    ) {
        if #available(macOS 14.0, *) {
            targetApp?.activate(options: [.activateAllWindows])
        } else {
            targetApp?.activate(options: [.activateIgnoringOtherApps])
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + dispatchDelay) { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            let undoDispatched = self.dispatchUndoShortcut(sessionID: sessionID, logger: logger)
            guard undoDispatched else {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                let pasteDispatched = self?.dispatchPasteShortcut(sessionID: sessionID, logger: logger) ?? false
                completion(pasteDispatched)
            }
        }
    }

    private func dispatchPasteShortcut(sessionID: UUID, logger: AppLogger) -> Bool {
        dispatchShortcut(
            keyCode: 9,
            command: true,
            sessionID: sessionID,
            logger: logger,
            actionLabel: "Cmd+V paste"
        )
    }

    private func dispatchUndoShortcut(sessionID: UUID, logger: AppLogger) -> Bool {
        dispatchShortcut(
            keyCode: 6,
            command: true,
            sessionID: sessionID,
            logger: logger,
            actionLabel: "Cmd+Z undo"
        )
    }

    private func dispatchShortcut(
        keyCode: CGKeyCode,
        command: Bool,
        sessionID: UUID,
        logger: AppLogger,
        actionLabel: String
    ) -> Bool {
        guard
            let source = CGEventSource(stateID: .combinedSessionState) ?? CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            logger.log(
                "Failed to create CGEvent for \(actionLabel). sessionId=\(sessionID.uuidString)",
                type: .error
            )
            return false
        }

        if command {
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        logger.log("Dispatched \(actionLabel) shortcut. sessionId=\(sessionID.uuidString)")
        return true
    }
}
