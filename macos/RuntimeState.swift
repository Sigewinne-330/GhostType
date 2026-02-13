import Foundation

enum PipelineStage: String {
    case idle
    case recording
    case processing
    case streaming
    case completed
    case failed

    var title: String {
        switch self {
        case .idle:
            return "Idle"
        case .recording:
            return "Recording"
        case .processing:
            return "Processing"
        case .streaming:
            return "Streaming"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }
}

@MainActor
final class RuntimeState: ObservableObject {
    @Published var stage: PipelineStage = .idle
    @Published var streamingOutput: String = ""
    @Published var lastOutput: String = ""
    @Published var lastError: String = ""
    @Published var activeModeText: String = "None"
    @Published var processStatus: String = "Idle"
    @Published var backendStatus: String = "Not Started"
    @Published var lastASRDetectedLanguage: String = "Unknown"
    @Published var lastLLMOutputLanguagePolicy: String = "Unknown"
    @Published var lastInsertPath: String = "N/A"
    @Published var lastInsertDebug: String = ""
    @Published var lastClipboardRestoreStatus: String = "N/A"
    @Published var pretranscribeStatus: String = "Off"
    @Published var pretranscribeCompletedChunks: Int = 0
    @Published var pretranscribeQueueDepth: Int = 0
    @Published var pretranscribeLastLatencyMS: Double = 0
}
