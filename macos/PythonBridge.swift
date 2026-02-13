import Foundation

struct StreamInferenceMeta: Decodable {
    let mode: String
    let raw_text: String
    let output_text: String
    let used_web_search: Bool
    let web_sources: [StreamWebSource]
    let timing_ms: [String: Double]
    let asr_language_detected: String?
    let output_language_policy: String?

    private enum CodingKeys: String, CodingKey {
        case mode
        case raw_text
        case output_text
        case used_web_search
        case web_sources
        case timing_ms
        case asr_language_detected
        case output_language_policy
    }

    init(
        mode: String,
        raw_text: String,
        output_text: String,
        used_web_search: Bool,
        web_sources: [StreamWebSource],
        timing_ms: [String: Double],
        asr_language_detected: String? = nil,
        output_language_policy: String? = nil
    ) {
        self.mode = mode
        self.raw_text = raw_text
        self.output_text = output_text
        self.used_web_search = used_web_search
        self.web_sources = web_sources
        self.timing_ms = timing_ms
        self.asr_language_detected = asr_language_detected
        self.output_language_policy = output_language_policy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? container.decode(String.self, forKey: .mode)) ?? ""
        raw_text = (try? container.decode(String.self, forKey: .raw_text)) ?? ""
        output_text = (try? container.decode(String.self, forKey: .output_text)) ?? ""
        used_web_search = (try? container.decode(Bool.self, forKey: .used_web_search)) ?? false
        web_sources = (try? container.decode([StreamWebSource].self, forKey: .web_sources)) ?? []
        timing_ms = (try? container.decode([String: Double].self, forKey: .timing_ms)) ?? [:]
        asr_language_detected = try? container.decode(String.self, forKey: .asr_language_detected)
        output_language_policy = try? container.decode(String.self, forKey: .output_language_policy)
    }
}

struct StreamWebSource: Decodable {
    let title: String
    let url: String
    let snippet: String

    private enum CodingKeys: String, CodingKey {
        case title
        case url
        case snippet
    }

    init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        url = (try? container.decode(String.self, forKey: .url)) ?? ""
        snippet = (try? container.decode(String.self, forKey: .snippet)) ?? ""
    }
}

private struct ASRChunkDecodeResponse: Decodable {
    let text: String
    let timing_ms: [String: Double]
}

enum PythonRunError: LocalizedError {
    case requestEncodingFailed
    case transportFailure(String)
    case serverFailure(code: Int, body: String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .requestEncodingFailed:
            return "Failed to encode request body."
        case .transportFailure(let message):
            return "Backend request failed: \(message)"
        case .serverFailure(let code, let body):
            return "Backend returned HTTP \(code): \(body)"
        case .invalidResponse(let body):
            return "Invalid backend response: \(body)"
        }
    }
}

final class PythonStreamRunner: InferenceProvider {
    let providerID = "local.mlx.service"

    private let host = "127.0.0.1"
    private let port = 8765
    private let session = URLSession(configuration: .ephemeral)
    private let appLogger = AppLogger.shared

    private var activeStreamID: UUID?
    private var runningTask: Task<Void, Never>?

    func run(
        request: InferenceRequest,
        onToken: @escaping (String) -> Void,
        completion: @escaping (Result<StreamInferenceMeta, Error>) -> Void
    ) {
        run(
            state: request.state,
            mode: request.mode,
            audioURL: request.audioURL,
            selectedText: request.selectedText,
            dictationContext: request.dictationContext,
            audioProcessingProfile: request.audioProcessingProfile,
            onToken: onToken,
            completion: completion
        )
    }

    func run(
        state: AppState,
        mode: WorkflowMode,
        audioURL: URL,
        selectedText: String,
        dictationContext: DictationContextSelection?,
        audioProcessingProfile: AudioProcessingProfile = .standard,
        onToken: @escaping (String) -> Void,
        completion: @escaping (Result<StreamInferenceMeta, Error>) -> Void
    ) {
        terminateIfRunning()
        appLogger.log("Local inference run requested. mode=\(mode.rawValue), audio=\(audioURL.path)")

        guard let endpointURL = endpointURL(for: mode) else {
            appLogger.log("Unsupported workflow mode for local inference.", type: .error)
            completion(.failure(PythonRunError.invalidResponse("Unsupported workflow mode.")))
            return
        }

        guard let requestBody = buildRequestBody(
            state: state,
            mode: mode,
            audioURL: audioURL,
            selectedText: selectedText,
            dictationContext: dictationContext,
            audioProcessingProfile: audioProcessingProfile
        ) else {
            appLogger.log("Failed to encode local inference request body.", type: .error)
            completion(.failure(PythonRunError.requestEncodingFailed))
            return
        }

        var request = URLRequest(url: endpointURL, timeoutInterval: 3600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = requestBody

        let streamID = UUID()
        activeStreamID = streamID

        startStreamingTask(
            request: request,
            streamID: streamID,
            onToken: onToken,
            completion: completion
        )
    }

    func transcribeChunk(
        state: AppState,
        audioURL: URL,
        dictationContext: DictationContextSelection?,
        audioProcessingProfile: AudioProcessingProfile = .standard
    ) async throws -> PretranscriptionASRResult {
        guard let endpoint = endpointURL(path: "/asr/transcribe") else {
            throw PythonRunError.invalidResponse("Invalid local ASR endpoint URL.")
        }
        guard let requestBody = buildRequestBody(
            state: state,
            mode: .dictate,
            audioURL: audioURL,
            selectedText: "",
            dictationContext: dictationContext,
            audioProcessingProfile: audioProcessingProfile
        ) else {
            throw PythonRunError.requestEncodingFailed
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 3600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PythonRunError.invalidResponse("No HTTP response from backend.")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PythonRunError.serverFailure(code: httpResponse.statusCode, body: body)
        }
        guard let decoded = try? JSONDecoder().decode(ASRChunkDecodeResponse.self, from: data) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PythonRunError.invalidResponse("Invalid ASR chunk response: \(body)")
        }
        return PretranscriptionASRResult(
            text: decoded.text,
            detectedLanguage: nil,
            timingMS: decoded.timing_ms
        )
    }

    func runPreparedTranscript(
        state: AppState,
        mode: WorkflowMode,
        rawText: String,
        selectedText: String,
        dictationContext: DictationContextSelection?,
        timingMS: [String: Double],
        onToken: @escaping (String) -> Void,
        completion: @escaping (Result<StreamInferenceMeta, Error>) -> Void
    ) {
        terminateIfRunning()
        guard let endpoint = endpointURL(path: "/llm/stream") else {
            completion(.failure(PythonRunError.invalidResponse("Invalid local LLM endpoint URL.")))
            return
        }

        var payload: [String: Any] = [
            "mode": mode.rawValue,
            "raw_text": rawText,
            "selected_text": selectedText,
            "target_language": state.targetLanguage.rawValue,
            "asr_model": state.asrModel,
            "llm_model": state.llmModel,
            "max_tokens": 350,
            "timing_ms": timingMS,
        ]

        switch mode {
        case .dictate:
            let directive = state.outputLanguageDirective(asrDetectedLanguage: nil, transcriptText: rawText)
            let dictationSystemPrompt = state.resolvedDictateSystemPrompt(
                lockedDictationPrompt: dictationContext?.preset.dictationPrompt
            )
            payload["system_prompt"] = """
            \(dictationSystemPrompt)

            \(directive.promptInstruction)
            """
        case .ask:
            let directive = state.outputLanguageDirective(asrDetectedLanguage: nil, transcriptText: rawText)
            payload["web_search_enabled"] = true
            payload["max_search_results"] = 3
            payload["system_prompt"] = """
            \(state.resolvedAskSystemPrompt())

            \(directive.promptInstruction)
            """
        case .translate:
            payload["system_prompt"] = state.resolvedTranslateSystemPrompt(targetLanguage: state.targetLanguage.rawValue)
        }

        guard let requestBody = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(PythonRunError.requestEncodingFailed))
            return
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 3600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = requestBody

        let streamID = UUID()
        activeStreamID = streamID
        startStreamingTask(
            request: request,
            streamID: streamID,
            onToken: onToken,
            completion: completion
        )
    }

    private func endpointURL(for mode: WorkflowMode) -> URL? {
        let path: String
        switch mode {
        case .dictate:
            path = "/dictate/stream"
        case .ask:
            path = "/ask/stream"
        case .translate:
            path = "/translate/stream"
        }
        return endpointURL(path: path)
    }

    private func endpointURL(path: String) -> URL? {
        URL(string: "http://\(host):\(port)\(path)")
    }

    private func buildRequestBody(
        state: AppState,
        mode: WorkflowMode,
        audioURL: URL,
        selectedText: String,
        dictationContext: DictationContextSelection?,
        audioProcessingProfile: AudioProcessingProfile
    ) -> Data? {
        let enhancementMode: String = {
            switch audioProcessingProfile {
            case .fast, .quality:
                return AudioEnhancementModeOption.webRTC.requestValue
            case .standard:
                return state.audioEnhancementEnabled
                    ? state.audioEnhancementMode.requestValue
                    : AudioEnhancementModeOption.off.requestValue
            }
        }()
        let profileIsForcedEnhancement = (audioProcessingProfile == .fast || audioProcessingProfile == .quality)
        let enhancementEnabled = profileIsForcedEnhancement ? true : state.audioEnhancementEnabled
        let enhancementVersion = enhancementEnabled ? "v2" : "legacy"
        let enhancementModeV2: String = {
            switch audioProcessingProfile {
            case .fast:
                return "fast_dsp"
            case .quality:
                return "high_quality"
            case .standard:
                break
            }
            switch state.audioEnhancementMode {
            case .off:
                return "fast_dsp"
            case .webRTC:
                return "fast_dsp"
            case .systemVoiceProcessing:
                return "high_quality"
            }
        }()
        let nsEngine: String = {
            guard enhancementEnabled else { return "off" }
            switch state.audioEnhancementMode {
            case .off:
                if audioProcessingProfile == .quality || audioProcessingProfile == .fast {
                    return "webrtc"
                }
                return "off"
            case .webRTC, .systemVoiceProcessing:
                return "webrtc"
            }
        }()
        let loudnessStrategy: String = {
            guard enhancementEnabled else { return "rms" }
            return enhancementModeV2 == "high_quality" ? "dynaudnorm" : "rms"
        }()
        let dynamics: String = {
            guard enhancementEnabled else { return "off" }
            return enhancementModeV2 == "high_quality" ? "upward_comp" : "off"
        }()
        let maxGainDB: Double = {
            switch state.lowVolumeBoost {
            case .low:
                return 12.0
            case .medium:
                return 18.0
            case .high:
                return 24.0
            }
        }()
        let vadAggressiveness: Int = {
            switch state.noiseSuppressionLevel {
            case .low:
                return 0
            case .moderate:
                return 1
            case .high:
                return 2
            case .veryHigh:
                return 3
            }
        }()
        var payload: [String: Any] = [
            "audio_path": audioURL.path,
            "asr_model": state.asrModel,
            "llm_model": state.llmModel,
            "max_tokens": 350,
            "audio_enhancement_enabled": enhancementEnabled,
            "audio_enhancement_mode": enhancementMode,
            "low_volume_boost": state.lowVolumeBoost.requestValue,
            "noise_suppression_level": state.noiseSuppressionLevel.requestValue,
            "anti_cutoff_pause_ms": state.endpointPauseThreshold.milliseconds,
            "audio_debug_enabled": state.showAudioDebugHUD,
            "enhancement_version": enhancementVersion,
            "enhancement_mode": enhancementModeV2,
            "inference_audio_profile": {
                switch audioProcessingProfile {
                case .standard: return "standard"
                case .fast: return "fast"
                case .quality: return "quality"
                }
            }(),
            "ns_engine": nsEngine,
            "loudness_strategy": loudnessStrategy,
            "dynamics": dynamics,
            "limiter": [
                "enabled": true,
                "threshold": 0.98,
                "attack_ms": 5.0,
                "release_ms": 50.0,
            ],
            "targets": [
                "lufs_target": -18.0,
                "max_gain_db": maxGainDB,
            ],
            "vad": [
                "engine": "webrtcvad",
                "aggressiveness": vadAggressiveness,
                "preroll_ms": 100,
                "hangover_ms": state.endpointPauseThreshold.milliseconds,
            ],
            "pretranscribe_enabled": state.pretranscribeEnabled,
            "pretranscribe_config": [
                "step_sec": state.pretranscribeStepSeconds,
                "overlap_sec": state.pretranscribeOverlapSeconds,
                "max_chunk_sec": state.pretranscribeMaxChunkSeconds,
                "min_speech_sec": state.pretranscribeMinSpeechSeconds,
                "end_silence_ms": state.pretranscribeEndSilenceMS,
                "max_in_flight": state.pretranscribeMaxInFlight,
                "fallback_policy": state.pretranscribeFallbackPolicy.rawValue,
            ],
        ]
        switch mode {
        case .dictate:
            payload["ui_language"] = state.uiLanguage.rawValue
            let directive = state.outputLanguageDirective(asrDetectedLanguage: nil, transcriptText: "")
            let dictationSystemPrompt = state.resolvedDictateSystemPrompt(
                lockedDictationPrompt: dictationContext?.preset.dictationPrompt
            )
            payload["output_language"] = state.outputLanguage.rawValue
            payload["system_prompt"] = """
            \(dictationSystemPrompt)

            \(directive.promptInstruction)
            """
        case .ask:
            let directive = state.outputLanguageDirective(asrDetectedLanguage: nil, transcriptText: "")
            payload["selected_text"] = selectedText
            payload["ui_language"] = state.uiLanguage.rawValue
            payload["output_language"] = state.outputLanguage.rawValue
            payload["web_search_enabled"] = true
            payload["max_search_results"] = 3
            payload["system_prompt"] = """
            \(state.resolvedAskSystemPrompt())

            \(directive.promptInstruction)
            """
        case .translate:
            payload["target_language"] = state.targetLanguage.rawValue
            payload["system_prompt"] = state.resolvedTranslateSystemPrompt(targetLanguage: state.targetLanguage.rawValue)
        }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private func startStreamingTask(
        request: URLRequest,
        streamID: UUID,
        onToken: @escaping (String) -> Void,
        completion: @escaping (Result<StreamInferenceMeta, Error>) -> Void
    ) {
        runningTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (bytes, response) = try await self.session.bytes(for: request)
                guard self.activeStreamID == streamID else { return }
                guard let httpResponse = response as? HTTPURLResponse else {
                    self.appLogger.log("Local stream failed: no HTTP response.", type: .error)
                    throw PythonRunError.invalidResponse("No HTTP response from backend stream.")
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    let body = try await self.readBodyPreview(from: bytes)
                    self.appLogger.log("Local stream failed: HTTP \(httpResponse.statusCode): \(body)", type: .error)
                    throw PythonRunError.serverFailure(code: httpResponse.statusCode, body: body)
                }

                var finalMeta: StreamInferenceMeta?
                for try await line in bytes.lines {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    guard self.activeStreamID == streamID else { return }

                    guard let payload = self.sseDataPayload(from: line) else {
                        continue
                    }
                    if payload == "[DONE]" {
                        break
                    }

                    switch try self.parseSSEPayload(payload) {
                    case .token(let token):
                        if !token.isEmpty {
                            await MainActor.run {
                                onToken(token)
                            }
                        }
                    case .done(let meta):
                        finalMeta = meta
                    case .error(let message):
                        throw PythonRunError.invalidResponse(message)
                    case .ignore:
                        continue
                    }
                }

                guard let meta = finalMeta else {
                    self.appLogger.log("Local stream failed: missing done event.", type: .error)
                    throw PythonRunError.invalidResponse("Missing done event from backend stream.")
                }

                self.finish(streamID: streamID)
                self.appLogger.log("Local inference stream completed successfully.")
                await MainActor.run {
                    completion(.success(meta))
                }
            } catch {
                if Task.isCancelled {
                    self.finish(streamID: streamID)
                    self.appLogger.log("Local inference stream cancelled.")
                    await MainActor.run {
                        completion(.failure(CancellationError()))
                    }
                    return
                }
                self.finish(streamID: streamID)
                self.appLogger.log("Local inference stream failed: \(error.localizedDescription)", type: .error)
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    private enum SSEBackendEvent {
        case token(String)
        case done(StreamInferenceMeta)
        case error(String)
        case ignore
    }

    private func parseSSEPayload(_ payload: String) throws -> SSEBackendEvent {
        guard let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return .ignore
        }

        switch type {
        case "token":
            return .token((object["token"] as? String) ?? "")
        case "done":
            guard let metaObject = object["meta"] as? [String: Any] else {
                return .error("Missing done meta payload.")
            }
            let metaData = try JSONSerialization.data(withJSONObject: metaObject)
            let meta = try JSONDecoder().decode(StreamInferenceMeta.self, from: metaData)
            return .done(meta)
        case "error":
            return .error((object["message"] as? String) ?? "Unknown backend stream error.")
        default:
            return .ignore
        }
    }

    private func finish(streamID: UUID) {
        guard activeStreamID == streamID else { return }
        runningTask = nil
        activeStreamID = nil
    }

    func terminateIfRunning() {
        runningTask?.cancel()
        runningTask = nil
        activeStreamID = nil
        appLogger.log("Local inference stream task terminated.")
    }
    
    private func sseDataPayload(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        return payload.isEmpty ? nil : payload
    }

    private func readBodyPreview(from bytes: URLSession.AsyncBytes, maxBytes: Int = 4096) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            if Task.isCancelled {
                throw CancellationError()
            }
            data.append(byte)
            if data.count >= maxBytes {
                break
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
