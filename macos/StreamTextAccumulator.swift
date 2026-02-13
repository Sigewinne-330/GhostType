import Foundation

enum StreamTokenMergeAction: Equatable {
    case append(String)
    case replace(String)
    case ignore
}

struct StreamTextAccumulator {
    private(set) var text: String = ""

    mutating func reset() {
        text = ""
    }

    mutating func ingest(_ incoming: String) -> StreamTokenMergeAction {
        guard !incoming.isEmpty else { return .ignore }
        if text.isEmpty {
            text = incoming
            return .append(incoming)
        }
        if incoming == text {
            return .ignore
        }
        if incoming.hasPrefix(text) {
            text = incoming
            return .replace(incoming)
        }
        if text.hasPrefix(incoming) {
            return .ignore
        }
        text += incoming
        return .append(incoming)
    }
}
