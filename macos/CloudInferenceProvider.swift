import Foundation

struct ASRTranscriptionResult {
    let text: String
    let detectedLanguage: String?
}

final class CloudInferenceProvider: InferenceProvider {
    let providerID = "cloud.http.multi"

    let session: URLSession
    var runningTask: Task<Void, Never>?
    var openAICompatiblePathCache: [String: OpenAICompatibleEndpointKind] = [:]
    var privacyModeEnabled = true
    let appLogger = AppLogger.shared
    let retryPolicy = ExponentialBackoffRetryPolicy(
        maxAttempts: 3,
        baseDelayMS: 400,
        maxDelayMS: 2_500,
        jitterRangeMS: 0...120
    )

    init(session: URLSession = .shared) {
        self.session = session
    }

    func run(
        request: InferenceRequest,
        onToken: @escaping (String) -> Void,
        completion: @escaping (Result<StreamInferenceMeta, Error>) -> Void
    ) {
        terminateIfRunning()
        privacyModeEnabled = request.state.privacyModeEnabled
        appLogger.log("Cloud inference run requested. mode=\(request.mode.rawValue), audio=\(request.audioURL.path)")

        runningTask = Task {
            let startedAt = Date()
            do {
                let asrStartedAt = Date()
                let transcription = try await transcribeAudio(request: request)
                let asrElapsed = Date().timeIntervalSince(asrStartedAt) * 1000
                self.appLogger.log(
                    "Cloud ASR transcription succeeded. chars=\(transcription.text.count), detectedLanguage=\(transcription.detectedLanguage ?? "unknown")"
                )
                let llmStartedAt = Date()
                let stream = try await streamGenerate(
                    request: request,
                    rawText: transcription.text,
                    asrDetectedLanguage: transcription.detectedLanguage,
                    onToken: onToken
                )
                let llmElapsed = Date().timeIntervalSince(llmStartedAt) * 1000
                let elapsed = Date().timeIntervalSince(startedAt) * 1000
                var timing: [String: Double] = [
                    "asr": asrElapsed,
                    "llm": llmElapsed,
                    "total": elapsed,
                ]
                if let firstTokenLatency = stream.firstTokenLatencyMS {
                    timing["first_token"] = firstTokenLatency
                }
                let meta = StreamInferenceMeta(
                    mode: request.mode.rawValue,
                    raw_text: transcription.text,
                    output_text: stream.output,
                    used_web_search: false,
                    web_sources: [],
                    timing_ms: timing,
                    asr_language_detected: transcription.detectedLanguage,
                    output_language_policy: stream.outputLanguagePolicy
                )
                self.appLogger.log("Cloud inference stream completed successfully.")
                await MainActor.run {
                    completion(.success(meta))
                }
            } catch is CancellationError {
                self.appLogger.log("Cloud inference stream cancelled.")
                await MainActor.run {
                    completion(.failure(CancellationError()))
                }
            } catch {
                self.appLogger.log("Cloud inference failed: \(error.localizedDescription)", type: .error)
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }


    func terminateIfRunning() {
        runningTask?.cancel()
        runningTask = nil
        appLogger.log("Cloud inference stream task terminated.")
    }
}
