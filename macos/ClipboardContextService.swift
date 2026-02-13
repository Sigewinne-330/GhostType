import AppKit
import Foundation

struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
    let changeCount: Int
}

enum ClipboardRestoreResult: Equatable {
    case restored
    case skippedConflict
    case skippedDisabled
    case failed

    var title: String {
        switch self {
        case .restored:
            return "Restored"
        case .skippedConflict:
            return "Skipped (Clipboard Changed)"
        case .skippedDisabled:
            return "Disabled"
        case .failed:
            return "Restore Failed"
        }
    }
}

final class ClipboardContextService {
    func captureSelectedText() -> String {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotCurrentPasteboard()

        triggerCommandC()
        usleep(120_000)
        let selectedText = pasteboard.string(forType: .string) ?? ""

        restoreSnapshot(snapshot)
        return selectedText
    }

    func snapshotCurrentPasteboard() -> PasteboardSnapshot {
        let pasteboard = NSPasteboard.general
        return PasteboardSnapshot(
            items: snapshotPasteboardItems(pasteboard),
            changeCount: pasteboard.changeCount
        )
    }

    @discardableResult
    func writeTextPayload(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let rtfData = rtfData(from: text) {
            pasteboard.setData(rtfData, forType: .rtf)
        }
        return pasteboard.changeCount
    }

    @discardableResult
    func restoreSnapshotIfUnchanged(
        _ snapshot: PasteboardSnapshot,
        expectedChangeCount: Int,
        restoreEnabled: Bool
    ) -> ClipboardRestoreResult {
        guard restoreEnabled else { return .skippedDisabled }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expectedChangeCount else {
            return .skippedConflict
        }
        return restoreSnapshot(snapshot)
    }

    @discardableResult
    func restoreSnapshot(_ snapshot: PasteboardSnapshot) -> ClipboardRestoreResult {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if snapshot.items.isEmpty {
            return .restored
        }
        let restoredItems: [NSPasteboardItem] = snapshot.items.map { stored in
            let item = NSPasteboardItem()
            for (type, data) in stored {
                item.setData(data, forType: type)
            }
            return item
        }
        return pasteboard.writeObjects(restoredItems) ? .restored : .failed
    }

    private func snapshotPasteboardItems(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var output: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    output[type] = data
                }
            }
            return output
        }
    }

    private func rtfData(from text: String) -> Data? {
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        )
        return try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    private func triggerCommandC() {
        guard
            let source = CGEventSource(stateID: .combinedSessionState) ?? CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
