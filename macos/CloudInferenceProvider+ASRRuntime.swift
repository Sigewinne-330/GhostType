import Foundation

private let audioStreamChunkSize = 4_096

// MARK: - ASR Runtime
// Responsibility: Execute ASR calls, retries, and fallback language logic for cloud providers.
// Public entry point: transcribeAudio(request:).
extension CloudInferenceProvider {
    func transcribeAudio(request: InferenceRequest) async throws -> ASRTranscriptionResult {
        saveDebugAudioCopy(audioURL: request.audioURL)
        let asrRequest = makeUnifiedASRRequest(request)
        let runtime = try asrRuntimeConfig(for: request.state)

        let response = try await performASR(
            unifiedRequest: asrRequest,
            runtime: runtime,
            audioURL: request.audioURL,
            state: request.state
        )

        var text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var detectedLanguage = response.languageDetected
        if detectedLanguage == nil, asrRequest.language != "auto" {
            detectedLanguage = asrRequest.language
        }
        if text.isEmpty, runtime.requestKind == .deepgramBinary {
            if asrRequest.language == "auto" {
                let languageCandidates = deepgramLanguageRetryCandidates(for: request.state)
                for forcedLanguage in languageCandidates {
                    appLogger.log(
                        "Deepgram returned empty transcript. Retrying with forced language=\(forcedLanguage).",
                        type: .warning
                    )
                    let retryRequest = UnifiedASRRequest(
                        requestID: asrRequest.requestID,
                        audio: asrRequest.audio,
                        language: forcedLanguage,
                        timestamps: asrRequest.timestamps,
                        diarization: asrRequest.diarization
                    )
                    do {
                        let retryResponse = try await performASR(
                            unifiedRequest: retryRequest,
                            runtime: runtime,
                            audioURL: request.audioURL,
                            state: request.state
                        )
                        let retryText = retryResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !retryText.isEmpty {
                            appLogger.log("Deepgram retry succeeded with forced language=\(forcedLanguage).")
                            text = retryText
                            detectedLanguage = retryResponse.languageDetected ?? forcedLanguage
                            break
                        }
                    } catch {
                        appLogger.log(
                            "Deepgram retry failed for language=\(forcedLanguage): \(error.localizedDescription)",
                            type: .warning
                        )
                    }
                }
            }

            let fallbackRuntimes = asrFallbackRuntimeConfigs(excludingProviderID: runtime.providerID)
            if fallbackRuntimes.isEmpty {
                appLogger.log(
                    "No fallback ASR provider is configured in Keychain. Configure at least one backup ASR key (OpenAI/Groq/AssemblyAI/Gemini).",
                    type: .warning
                )
            }
            for fallbackRuntime in fallbackRuntimes {
                appLogger.log(
                    "Deepgram returned empty transcript. Retrying with \(fallbackRuntime.providerName).",
                    type: .warning
                )
                do {
                    let fallbackResponse = try await performASR(
                        unifiedRequest: asrRequest,
                        runtime: fallbackRuntime,
                        audioURL: request.audioURL,
                        state: request.state
                    )
                    let fallbackText = fallbackResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !fallbackText.isEmpty {
                        appLogger.log("Fallback ASR succeeded with \(fallbackRuntime.providerName).")
                        text = fallbackText
                        detectedLanguage = fallbackResponse.languageDetected
                        break
                    } else {
                        appLogger.log(
                            "Fallback ASR \(fallbackRuntime.providerName) also returned an empty transcript.",
                            type: .warning
                        )
                    }
                } catch {
                    appLogger.log(
                        "Fallback ASR \(fallbackRuntime.providerName) failed: \(error.localizedDescription)",
                        type: .warning
                    )
                }
            }
        }

        guard !text.isEmpty else {
            throw CloudInferenceError.missingTextFromTranscription
        }
        if request.state.removeRepeatedTextEnabled {
            let deduped = TextDeduper.dedupe(text)
            if deduped != text {
                appLogger.log(
                    "ASR dedupe applied. beforeChars=\(text.count), afterChars=\(deduped.count).",
                    type: .debug
                )
                text = deduped
            }
        }

        let resolvedDetectedLanguage = detectedLanguage ?? inferLanguageTag(from: text)
        return ASRTranscriptionResult(
            text: text,
            detectedLanguage: resolvedDetectedLanguage
        )
    }


    func performASR(
        unifiedRequest: UnifiedASRRequest,
        runtime: ASRRuntimeConfig,
        audioURL: URL,
        state: AppState
    ) async throws -> UnifiedASRResponse {
        switch runtime.requestKind {
        case .openAIMultipart:
            return try await transcribeOpenAIMultipart(
                unifiedRequest: unifiedRequest,
                runtime: runtime,
                audioURL: audioURL
            )
        case .deepgramBinary:
            return try await transcribeDeepgram(
                unifiedRequest: unifiedRequest,
                runtime: runtime,
                audioURL: audioURL
            )
        case .deepgramStreaming:
            return try await transcribeDeepgramStreaming(
                unifiedRequest: unifiedRequest,
                runtime: runtime,
                audioURL: audioURL
            )
        case .assemblyAI:
            return try await transcribeAssemblyAI(
                unifiedRequest: unifiedRequest,
                runtime: runtime,
                audioURL: audioURL
            )
        case .geminiMultimodal:
            return try await transcribeGeminiMultimodal(
                unifiedRequest: unifiedRequest,
                runtime: runtime,
                audioURL: audioURL,
                state: state
            )
        }
    }


    func makeUnifiedASRRequest(_ request: InferenceRequest) -> UnifiedASRRequest {
        let configuredLanguage = request.state.cloudASRLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultLanguage = request.state.asrEngine == .deepgram
            ? DeepgramLanguageStrategy.chineseSimplified.rawValue
            : "auto"
        let resolvedLanguage: String
        if request.state.asrEngine == .deepgram {
            let candidate = configuredLanguage.isEmpty ? defaultLanguage : configuredLanguage
            resolvedLanguage = DeepgramConfig.normalizedLanguageCode(candidate)
        } else {
            resolvedLanguage = configuredLanguage.isEmpty ? defaultLanguage : configuredLanguage.lowercased()
        }

        return UnifiedASRRequest(
            requestID: UUID().uuidString,
            audio: UnifiedAudioInput(
                path: request.audioURL.path,
                mimeType: mimeType(for: request.audioURL),
                durationMS: nil
            ),
            language: resolvedLanguage,
            timestamps: UnifiedASRTimestamps(enabled: false, granularity: "segment"),
            diarization: false
        )
    }


    func asrRuntimeConfig(for state: AppState) throws -> ASRRuntimeConfig {
        let configuredBase = state.cloudASRBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelInput = state.cloudASRModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeoutSeconds = max(15, min(1800, state.cloudASRTimeoutSec))
        let maxRetries = max(0, min(8, state.cloudASRMaxRetries))
        let maxInFlight = max(1, min(8, state.cloudASRMaxInFlight))
        let streamingEnabled = state.cloudASRStreamingEnabled

        switch state.asrEngine {
        case .localHTTPOpenAIAudio:
            let configuredLocalBase = state.localHTTPASRBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let localBaseRaw = configuredLocalBase.isEmpty
                ? LocalASRModelCatalog.defaultLocalHTTPBaseURL
                : configuredLocalBase
            let candidateBase = localBaseRaw.contains("://")
                ? localBaseRaw
                : "http://\(localBaseRaw)"
            let baseURL = try normalizedBaseURL(candidateBase)
            let configuredModel = state.localHTTPASRModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = configuredModel.isEmpty
                ? state.localASRProvider.defaultHTTPModelName
                : configuredModel
            let providerName = state.localASRProvider.rawValue
            let providerIDSuffix = providerName.lowercased().map { character -> Character in
                (character.isLetter || character.isNumber) ? character : "_"
            }
            let providerID = "local_http_asr_\(String(providerIDSuffix))"
            return ASRRuntimeConfig(
                providerID: providerID,
                providerName: providerName,
                baseURL: baseURL,
                modelName: model,
                apiKey: "",
                requestPath: ASRProviderRequestConfig.openAIDefault.path,
                requestKind: .openAIMultipart,
                timeoutSeconds: timeoutSeconds,
                maxRetries: maxRetries,
                maxInFlight: maxInFlight,
                streamingEnabled: streamingEnabled,
                extraHeaders: [:],
                deepgramQueryConfig: nil
            )
        case .openAIWhisper:
            let key = try requiredAPIKey(.asrOpenAI, providerName: "Cloud OpenAI Whisper")
            let baseURL = try normalizedBaseURL(configuredBase.isEmpty ? ASREngineOption.openAIWhisper.defaultBaseURL : configuredBase)
            let model = modelInput.isEmpty ? ASREngineOption.openAIWhisper.defaultModelName : modelInput
            return makeOpenAIMultipartASRRuntime(
                providerID: "openai_whisper",
                providerName: "OpenAI Whisper",
                baseURL: baseURL,
                modelName: model,
                apiKey: key,
                timeoutSeconds: timeoutSeconds,
                maxRetries: maxRetries,
                maxInFlight: maxInFlight,
                streamingEnabled: streamingEnabled
            )
        case .groq:
            let key = try requiredAPIKey(.asrGroq, providerName: "Cloud Groq ASR")
            let baseURL = try normalizedBaseURL(configuredBase.isEmpty ? ASREngineOption.groq.defaultBaseURL : configuredBase)
            let model = modelInput.isEmpty ? ASREngineOption.groq.defaultModelName : modelInput
            return makeOpenAIMultipartASRRuntime(
                providerID: "groq_asr",
                providerName: "Groq ASR",
                baseURL: baseURL,
                modelName: model,
                apiKey: key,
                timeoutSeconds: timeoutSeconds,
                maxRetries: maxRetries,
                maxInFlight: maxInFlight,
                streamingEnabled: streamingEnabled
            )
        case .deepgram:
            let key = try requiredAPIKey(.asrDeepgram, providerName: "Cloud Deepgram")
            let resolvedBaseRaw = configuredBase.isEmpty ? state.deepgram.region.defaultHTTPSBaseURL : configuredBase
            let baseURL = try normalizedBaseURL(resolvedBaseRaw)
            let model = modelInput.isEmpty ? ASREngineOption.deepgram.defaultModelName : modelInput
            let deepgramMode = state.deepgram.transcriptionMode
            let deepgramQueryConfig = DeepgramQueryConfig(
                modelName: model,
                language: state.deepgramResolvedLanguage,
                endpointingMS: state.deepgramEndpointingValue,
                interimResults: state.deepgram.interimResults,
                smartFormat: state.deepgram.smartFormat,
                punctuate: state.deepgram.punctuate,
                paragraphs: state.deepgram.paragraphs,
                diarize: state.deepgram.diarize,
                terminologyRawValue: state.deepgramTerminologyRawValue,
                mode: deepgramMode
            )
            return ASRRuntimeConfig(
                providerID: "deepgram",
                providerName: "Deepgram",
                baseURL: baseURL,
                modelName: model,
                apiKey: key,
                requestPath: "/\(DeepgramConfig.endpointPath)",
                requestKind: deepgramMode == .streaming ? .deepgramStreaming : .deepgramBinary,
                timeoutSeconds: timeoutSeconds,
                maxRetries: maxRetries,
                maxInFlight: maxInFlight,
                streamingEnabled: streamingEnabled,
                extraHeaders: ["Authorization": "Token \(key)"],
                deepgramQueryConfig: deepgramQueryConfig
            )
        case .assemblyAI:
            let key = try requiredAPIKey(.asrAssemblyAI, providerName: "Cloud AssemblyAI")
            let baseURL = try normalizedBaseURL(configuredBase.isEmpty ? ASREngineOption.assemblyAI.defaultBaseURL : configuredBase)
            let model = modelInput.isEmpty ? ASREngineOption.assemblyAI.defaultModelName : modelInput
            return ASRRuntimeConfig(
                providerID: "assemblyai",
                providerName: "AssemblyAI",
                baseURL: baseURL,
                modelName: model,
                apiKey: key,
                requestPath: "/v2/transcript",
                requestKind: .assemblyAI,
                timeoutSeconds: timeoutSeconds,
                maxRetries: maxRetries,
                maxInFlight: maxInFlight,
                streamingEnabled: streamingEnabled,
                extraHeaders: ["Authorization": key],
                deepgramQueryConfig: nil
            )
        case .geminiMultimodal:
            let key = try requiredAPIKey(.llmGemini, providerName: "Cloud Gemini ASR (shared Gemini API key)")
            let baseURL = try normalizedBaseURL(configuredBase.isEmpty ? ASREngineOption.geminiMultimodal.defaultBaseURL : configuredBase)
            let model = modelInput.isEmpty ? ASREngineOption.geminiMultimodal.defaultModelName : modelInput
            return ASRRuntimeConfig(
                providerID: "gemini_asr",
                providerName: "Google Gemini ASR",
                baseURL: baseURL,
                modelName: model,
                apiKey: key,
                requestPath: "/v1beta/models/{model}:generateContent",
                requestKind: .geminiMultimodal,
                timeoutSeconds: timeoutSeconds,
                maxRetries: maxRetries,
                maxInFlight: maxInFlight,
                streamingEnabled: streamingEnabled,
                extraHeaders: ["x-goog-api-key": key],
                deepgramQueryConfig: nil
            )
        case .customOpenAICompatible:
            let providerName = "Custom OpenAI-compatible ASR"
            let baseURL = try normalizedBaseURL(configuredBase.isEmpty ? ASREngineOption.customOpenAICompatible.defaultBaseURL : configuredBase)
            let model = modelInput.isEmpty ? ASREngineOption.customOpenAICompatible.defaultModelName : modelInput
            let requestPath = normalizedEndpointPath(
                state.cloudASRRequestPath,
                fallback: ASRProviderRequestConfig.openAIDefault.path
            )
            let extraHeaderMap = parseHeaderDictionary(from: state.cloudASRHeadersJSON)
            let resolvedKey = try resolveAPIKey(
                mode: state.cloudASRAuthMode,
                keyRef: state.cloudASRApiKeyRef,
                fallbackKey: nil,
                providerName: providerName
            )
            var headers = extraHeaderMap
            if let authHeader = authHeaderValue(
                mode: state.cloudASRAuthMode,
                apiKey: resolvedKey
            ) {
                headers["Authorization"] = authHeader
            }
            return ASRRuntimeConfig(
                providerID: "custom_openai_asr",
                providerName: providerName,
                baseURL: baseURL,
                modelName: model,
                apiKey: resolvedKey ?? "",
                requestPath: requestPath,
                requestKind: .openAIMultipart,
                timeoutSeconds: timeoutSeconds,
                maxRetries: maxRetries,
                maxInFlight: maxInFlight,
                streamingEnabled: streamingEnabled,
                extraHeaders: headers,
                deepgramQueryConfig: nil
            )
        case .localMLX:
            throw CloudInferenceError.unsupportedASREngine
        }
    }


    func asrFallbackRuntimeConfigs(excludingProviderID: String) -> [ASRRuntimeConfig] {
        var runtimes: [ASRRuntimeConfig] = []

        func append(
            providerID: String,
            providerName: String,
            baseURLRaw: String,
            modelName: String,
            keyType: APISecretKey,
            requestKind: ASRRequestKind,
            extraHeaders: @escaping (String) -> [String: String]
        ) {
            guard providerID != excludingProviderID else { return }
            guard let key = optionalAPIKey(keyType) else { return }
            guard let baseURL = try? normalizedBaseURL(baseURLRaw) else { return }
            runtimes.append(
                ASRRuntimeConfig(
                    providerID: providerID,
                    providerName: providerName,
                    baseURL: baseURL,
                    modelName: modelName,
                    apiKey: key,
                    requestPath: requestKind == .assemblyAI
                        ? "/v2/transcript"
                        : ASRProviderRequestConfig.openAIDefault.path,
                    requestKind: requestKind,
                    timeoutSeconds: 300,
                    maxRetries: ProviderAdvancedConfig.asrDefault.maxRetries,
                    maxInFlight: ProviderAdvancedConfig.asrDefault.maxInFlight,
                    streamingEnabled: ProviderAdvancedConfig.asrDefault.streamingEnabled,
                    extraHeaders: extraHeaders(key),
                    deepgramQueryConfig: nil
                )
            )
        }

        append(
            providerID: "openai_whisper",
            providerName: "OpenAI Whisper",
            baseURLRaw: ASREngineOption.openAIWhisper.defaultBaseURL,
            modelName: ASREngineOption.openAIWhisper.defaultModelName,
            keyType: .asrOpenAI,
            requestKind: .openAIMultipart,
            extraHeaders: { ["Authorization": "Bearer \($0)"] }
        )
        append(
            providerID: "groq_asr",
            providerName: "Groq ASR",
            baseURLRaw: ASREngineOption.groq.defaultBaseURL,
            modelName: ASREngineOption.groq.defaultModelName,
            keyType: .asrGroq,
            requestKind: .openAIMultipart,
            extraHeaders: { ["Authorization": "Bearer \($0)"] }
        )
        append(
            providerID: "assemblyai",
            providerName: "AssemblyAI",
            baseURLRaw: ASREngineOption.assemblyAI.defaultBaseURL,
            modelName: ASREngineOption.assemblyAI.defaultModelName,
            keyType: .asrAssemblyAI,
            requestKind: .assemblyAI,
            extraHeaders: { ["Authorization": $0] }
        )
        append(
            providerID: "gemini_asr",
            providerName: "Google Gemini ASR",
            baseURLRaw: ASREngineOption.geminiMultimodal.defaultBaseURL,
            modelName: ASREngineOption.geminiMultimodal.defaultModelName,
            keyType: .llmGemini,
            requestKind: .geminiMultimodal,
            extraHeaders: { ["x-goog-api-key": $0] }
        )

        return runtimes
    }


    func deepgramLanguageRetryCandidates(for state: AppState) -> [String] {
        var candidates: [String] = []

        if let forced = state.outputLanguage.forcedLanguageTag {
            let primaryCode = forced
                .split(separator: "-")
                .first
                .map(String.init)?
                .lowercased()
            if let primaryCode, !primaryCode.isEmpty {
                candidates.append(primaryCode)
                if primaryCode == "zh" {
                    candidates.append("en")
                } else {
                    candidates.append("zh")
                }
            }
        } else {
            switch state.uiLanguage {
            case .chineseSimplified:
                candidates.append("zh")
                candidates.append("en")
            case .english:
                candidates.append("en")
                candidates.append("zh")
            }
        }

        if let preferred = Locale.preferredLanguages.first {
            let localeCode = preferred
                .split(separator: "-")
                .first
                .map(String.init)?
                .lowercased()
            if let localeCode, !localeCode.isEmpty {
                candidates.append(localeCode)
            }
        }

        var seen = Set<String>()
        return candidates.filter { code in
            guard !code.isEmpty else { return false }
            guard !seen.contains(code) else { return false }
            seen.insert(code)
            return true
        }
    }


    func makeOpenAIMultipartASRRuntime(
        providerID: String,
        providerName: String,
        baseURL: URL,
        modelName: String,
        apiKey: String,
        timeoutSeconds: TimeInterval,
        maxRetries: Int,
        maxInFlight: Int,
        streamingEnabled: Bool
    ) -> ASRRuntimeConfig {
        ASRRuntimeConfig(
            providerID: providerID,
            providerName: providerName,
            baseURL: baseURL,
            modelName: modelName,
            apiKey: apiKey,
            requestPath: ASRProviderRequestConfig.openAIDefault.path,
            requestKind: .openAIMultipart,
            timeoutSeconds: timeoutSeconds,
            maxRetries: maxRetries,
            maxInFlight: maxInFlight,
            streamingEnabled: streamingEnabled,
            extraHeaders: ["Authorization": "Bearer \(apiKey)"],
            deepgramQueryConfig: nil
        )
    }


    func transcribeOpenAIMultipart(
        unifiedRequest: UnifiedASRRequest,
        runtime: ASRRuntimeConfig,
        audioURL: URL
    ) async throws -> UnifiedASRResponse {
        let endpoint = appendingPath(runtime.requestPath, to: runtime.baseURL)

        var body = Data()
        let boundary = "Boundary-\(UUID().uuidString)"

        func appendField(name: String, value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        let resolvedModel = runtime.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolvedModel.isEmpty {
            appendField(name: "model", value: resolvedModel)
        }
        if unifiedRequest.language != "auto" {
            appendField(name: "language", value: unifiedRequest.language)
        }

        let audioData = try Data(contentsOf: audioURL)
        let fileName = audioURL.lastPathComponent
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(unifiedRequest.audio.mimeType)\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n".utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint, timeoutInterval: runtime.timeoutSeconds)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        for (key, value) in runtime.extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, _) = try await dataResponse(
            for: request,
            providerID: runtime.providerID,
            providerName: runtime.providerName,
            maxRetries: runtime.maxRetries
        )
        let object = try parseJSONObject(from: data)
        let text = extractTranscriptionText(from: object)
        if text.isEmpty {
            appLogger.log(
                "Cloud ASR response missing transcript payload. provider=\(runtime.providerName), keys=\(object.keys.sorted().joined(separator: ","))",
                type: .error
            )
        }

        return UnifiedASRResponse(
            requestID: unifiedRequest.requestID,
            provider: runtime.providerID,
            model: runtime.modelName,
            text: text,
            segments: [],
            languageDetected: object["language"] as? String,
            latencyMS: nil,
            rawProviderResponse: jsonValue(from: object)
        )
    }

    func transcribeDeepgram(
        unifiedRequest: UnifiedASRRequest,
        runtime: ASRRuntimeConfig,
        audioURL: URL
    ) async throws -> UnifiedASRResponse {
        let fallbackConfig = DeepgramQueryConfig(
            modelName: runtime.modelName,
            language: unifiedRequest.language,
            endpointingMS: nil,
            interimResults: false,
            smartFormat: true,
            punctuate: true,
            paragraphs: true,
            diarize: false,
            terminologyRawValue: "",
            mode: .batch
        )
        let savedConfig = runtime.deepgramQueryConfig ?? fallbackConfig
        let queryConfig = DeepgramQueryConfig(
            modelName: savedConfig.modelName,
            language: savedConfig.language,
            endpointingMS: nil,
            interimResults: false,
            smartFormat: savedConfig.smartFormat,
            punctuate: savedConfig.punctuate,
            paragraphs: savedConfig.paragraphs,
            diarize: savedConfig.diarize,
            terminologyRawValue: savedConfig.terminologyRawValue,
            mode: .batch
        )

        guard let baseEndpoint = DeepgramConfig.endpointURL(
            baseURLRaw: runtime.baseURL.absoluteString,
            mode: .batch,
            fallbackRegion: .standard
        ) else {
            throw CloudInferenceError.invalidURL(runtime.baseURL.absoluteString)
        }
        var components = URLComponents(url: baseEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = DeepgramConfig.buildQueryItems(config: queryConfig)
        guard let endpoint = components?.url else {
            throw CloudInferenceError.invalidURL(baseEndpoint.absoluteString)
        }

        let audioData = try Data(contentsOf: audioURL)
        var request = URLRequest(url: endpoint, timeoutInterval: runtime.timeoutSeconds)
        request.httpMethod = "POST"
        request.httpBody = audioData
        request.setValue(unifiedRequest.audio.mimeType, forHTTPHeaderField: "Content-Type")
        for (key, value) in runtime.extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, _) = try await dataResponse(
            for: request,
            providerID: runtime.providerID,
            providerName: runtime.providerName,
            maxRetries: runtime.maxRetries
        )
        let object = try parseJSONObject(from: data)
        var text = extractDeepgramTranscriptionText(from: object)
        if text.isEmpty {
            text = extractTranscriptionText(from: object)
        }
        if text.isEmpty {
            text = extractTranscriptFallback(from: object)
        }
        if text.isEmpty {
            let payloadDetails = privacyModeEnabled ? "[REDACTED] \(redactedBodySummary(jsonSnippet(object)))" : jsonSnippet(object)
            appLogger.log(
                "Cloud ASR response missing transcript payload. provider=\(runtime.providerName), keys=\(object.keys.sorted().joined(separator: ",")); summary=\(deepgramResponseSummary(object)); payload=\(payloadDetails)",
                type: .error
            )
        }
        return UnifiedASRResponse(
            requestID: unifiedRequest.requestID,
            provider: runtime.providerID,
            model: runtime.modelName,
            text: text,
            segments: [],
            languageDetected: extractDetectedLanguageTag(from: object),
            latencyMS: nil,
            rawProviderResponse: jsonValue(from: object)
        )
    }


    func transcribeDeepgramStreaming(
        unifiedRequest: UnifiedASRRequest,
        runtime: ASRRuntimeConfig,
        audioURL: URL
    ) async throws -> UnifiedASRResponse {
        let fallbackConfig = DeepgramQueryConfig(
            modelName: runtime.modelName,
            language: unifiedRequest.language,
            endpointingMS: nil,
            interimResults: true,
            smartFormat: true,
            punctuate: true,
            paragraphs: true,
            diarize: false,
            terminologyRawValue: "",
            mode: .streaming
        )
        let savedConfig = runtime.deepgramQueryConfig ?? fallbackConfig
        let queryConfig = DeepgramQueryConfig(
            modelName: savedConfig.modelName,
            language: savedConfig.language,
            endpointingMS: savedConfig.endpointingMS,
            interimResults: savedConfig.interimResults,
            smartFormat: savedConfig.smartFormat,
            punctuate: savedConfig.punctuate,
            paragraphs: savedConfig.paragraphs,
            diarize: savedConfig.diarize,
            terminologyRawValue: savedConfig.terminologyRawValue,
            mode: .streaming
        )

        guard let baseEndpoint = DeepgramConfig.endpointURL(
            baseURLRaw: runtime.baseURL.absoluteString,
            mode: .streaming,
            fallbackRegion: .standard
        ) else {
            throw CloudInferenceError.invalidURL(runtime.baseURL.absoluteString)
        }
        var components = URLComponents(url: baseEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = DeepgramConfig.buildQueryItems(config: queryConfig)
        guard let endpoint = components?.url else {
            throw CloudInferenceError.invalidURL(baseEndpoint.absoluteString)
        }

        var request = URLRequest(url: endpoint, timeoutInterval: runtime.timeoutSeconds)
        for (header, value) in runtime.extraHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
        }

        let audioData = try Data(contentsOf: audioURL)
        try await sendDeepgramStreamingAudio(audioData, over: socket)

        let streamPayload = try await collectDeepgramStreamingPayload(
            from: socket,
            timeoutSeconds: min(runtime.timeoutSeconds, 15)
        )
        let text = streamPayload.text
        if text.isEmpty {
            let payloadDetails = privacyModeEnabled
                ? "[REDACTED] \(redactedBodySummary(jsonSnippet(streamPayload.rawObject)))"
                : jsonSnippet(streamPayload.rawObject)
            appLogger.log(
                "Deepgram streaming returned empty transcript. provider=\(runtime.providerName), keys=\(streamPayload.rawObject.keys.sorted().joined(separator: ",")); payload=\(payloadDetails)",
                type: .warning
            )
        }

        return UnifiedASRResponse(
            requestID: unifiedRequest.requestID,
            provider: runtime.providerID,
            model: runtime.modelName,
            text: text,
            segments: [],
            languageDetected: extractDetectedLanguageTag(from: streamPayload.rawObject),
            latencyMS: nil,
            rawProviderResponse: jsonValue(from: streamPayload.rawObject)
        )
    }

    private func sendDeepgramStreamingAudio(
        _ audioData: Data,
        over socket: URLSessionWebSocketTask
    ) async throws {
        var offset = 0
        while offset < audioData.count {
            let chunkEnd = min(audioData.count, offset + audioStreamChunkSize)
            let chunk = Data(audioData[offset..<chunkEnd])
            try await socket.send(.data(chunk))
            offset = chunkEnd
        }
        try await socket.send(.string("{\"type\":\"CloseStream\"}"))
    }

    private func collectDeepgramStreamingPayload(
        from socket: URLSessionWebSocketTask,
        timeoutSeconds: TimeInterval
    ) async throws -> (text: String, rawObject: [String: Any]) {
        var latestPayload: [String: Any] = [:]
        var finalText = ""
        var receivedJSONObject = false
        let receiveTimeout = max(1, min(timeoutSeconds, 8))

        for _ in 0..<400 {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await receiveWebSocketMessage(from: socket, timeoutSeconds: receiveTimeout)
            } catch {
                break
            }

            guard let payload = deepgramJSONObject(from: message) else {
                continue
            }
            receivedJSONObject = true
            latestPayload = payload

            let candidate = extractDeepgramTranscriptionText(from: payload).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                finalText = candidate
            }

            let speechFinal = payload["speech_final"] as? Bool ?? false
            let isFinal = payload["is_final"] as? Bool ?? false
            let messageType = (payload["type"] as? String ?? "").lowercased()
            if !finalText.isEmpty && (speechFinal || isFinal || messageType == "final") {
                break
            }
        }

        if !receivedJSONObject {
            throw CloudInferenceError.invalidJSONResponse("Deepgram streaming returned no JSON payload.")
        }
        return (finalText, latestPayload)
    }

    private func receiveWebSocketMessage(
        from socket: URLSessionWebSocketTask,
        timeoutSeconds: TimeInterval
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask {
                try await socket.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw CloudInferenceError.invalidJSONResponse("Deepgram streaming receive timed out.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CloudInferenceError.invalidJSONResponse("Deepgram streaming receive failed.")
            }
            return first
        }
    }

    private func deepgramJSONObject(from message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        let data: Data
        switch message {
        case .string(let text):
            guard let textData = text.data(using: .utf8) else { return nil }
            data = textData
        case .data(let binary):
            data = binary
        @unknown default:
            return nil
        }
        return try? parseJSONObject(from: data)
    }


    func transcribeAssemblyAI(
        unifiedRequest: UnifiedASRRequest,
        runtime: ASRRuntimeConfig,
        audioURL: URL
    ) async throws -> UnifiedASRResponse {
        let uploadURL = runtime.baseURL.appendingPathComponent("v2/upload")

        let audioData = try Data(contentsOf: audioURL)
        var uploadRequest = URLRequest(url: uploadURL, timeoutInterval: runtime.timeoutSeconds)
        uploadRequest.httpMethod = "POST"
        uploadRequest.httpBody = audioData
        uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        for (key, value) in runtime.extraHeaders {
            uploadRequest.setValue(value, forHTTPHeaderField: key)
        }

        let (uploadData, _) = try await dataResponse(
            for: uploadRequest,
            providerID: runtime.providerID,
            providerName: runtime.providerName,
            maxRetries: runtime.maxRetries
        )
        let uploadObject = try parseJSONObject(from: uploadData)
        guard let uploadedAudioURL = uploadObject["upload_url"] as? String, !uploadedAudioURL.isEmpty else {
            throw CloudInferenceError.invalidJSONResponse(String(data: uploadData, encoding: .utf8) ?? "")
        }

        let transcriptURL = runtime.baseURL.appendingPathComponent("v2/transcript")
        var transcriptBody: [String: Any] = [
            "audio_url": uploadedAudioURL,
            "speech_model": runtime.modelName,
            "word_timestamps": false,
        ]
        if unifiedRequest.language != "auto" {
            transcriptBody["language_code"] = unifiedRequest.language
        }

        var createRequest = try jsonRequest(
            url: transcriptURL,
            method: "POST",
            body: transcriptBody,
            timeout: runtime.timeoutSeconds,
            headers: [:]
        )
        for (key, value) in runtime.extraHeaders {
            createRequest.setValue(value, forHTTPHeaderField: key)
        }

        let (createData, _) = try await dataResponse(
            for: createRequest,
            providerID: runtime.providerID,
            providerName: runtime.providerName,
            maxRetries: runtime.maxRetries
        )
        let createObject = try parseJSONObject(from: createData)
        guard let transcriptID = createObject["id"] as? String, !transcriptID.isEmpty else {
            throw CloudInferenceError.invalidJSONResponse(String(data: createData, encoding: .utf8) ?? "")
        }

        let pollURL = runtime.baseURL.appendingPathComponent("v2/transcript").appendingPathComponent(transcriptID)

        for _ in 0..<120 {
            if Task.isCancelled {
                throw CancellationError()
            }

            var pollRequest = URLRequest(url: pollURL, timeoutInterval: runtime.timeoutSeconds)
            pollRequest.httpMethod = "GET"
            for (key, value) in runtime.extraHeaders {
                pollRequest.setValue(value, forHTTPHeaderField: key)
            }

            let (pollData, pollResponse) = try await dataResponse(
                for: pollRequest,
                providerID: runtime.providerID,
                providerName: runtime.providerName,
                maxRetries: runtime.maxRetries
            )
            let pollObject = try parseJSONObject(from: pollData)
            let status = (pollObject["status"] as? String ?? "").lowercased()

            if status == "completed" {
                let text = extractTranscriptionText(from: pollObject)
                if text.isEmpty {
                    appLogger.log(
                        "Cloud ASR response missing transcript payload. provider=\(runtime.providerName), keys=\(pollObject.keys.sorted().joined(separator: ","))",
                        type: .error
                    )
                }
                return UnifiedASRResponse(
                    requestID: unifiedRequest.requestID,
                    provider: runtime.providerID,
                    model: runtime.modelName,
                    text: text,
                    segments: [],
                    languageDetected: pollObject["language_code"] as? String,
                    latencyMS: nil,
                    rawProviderResponse: jsonValue(from: pollObject)
                )
            }

            if status == "error" {
                let message = (pollObject["error"] as? String) ?? "AssemblyAI transcription failed."
                throw providerFailure(
                    providerID: runtime.providerID,
                    providerName: runtime.providerName,
                    statusCode: pollResponse.statusCode,
                    body: message,
                    requestID: extractRequestID(pollResponse)
                )
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        throw providerFailure(
            providerID: runtime.providerID,
            providerName: runtime.providerName,
            statusCode: 408,
            body: "AssemblyAI transcription polling timed out.",
            requestID: nil
        )
    }


    func transcribeGeminiMultimodal(
        unifiedRequest: UnifiedASRRequest,
        runtime: ASRRuntimeConfig,
        audioURL: URL,
        state: AppState
    ) async throws -> UnifiedASRResponse {
        let candidateModels = geminiASRModelCandidates(primary: runtime.modelName)
        var lastError: Error?
        for candidateModel in candidateModels {
            do {
                return try await transcribeGeminiMultimodal(
                    unifiedRequest: unifiedRequest,
                    runtime: runtime,
                    audioURL: audioURL,
                    overrideModel: candidateModel,
                    state: state
                )
            } catch {
                if shouldRetryGeminiWithAnotherModel(error: error) {
                    appLogger.log(
                        "Gemini ASR model \(candidateModel) unavailable. Trying next fallback model.",
                        type: .warning
                    )
                    lastError = error
                    continue
                }
                throw error
            }
        }
        if let lastError {
            throw lastError
        }
        throw CloudInferenceError.invalidJSONResponse("Gemini ASR model fallback exhausted.")
    }


    func transcribeGeminiMultimodal(
        unifiedRequest: UnifiedASRRequest,
        runtime: ASRRuntimeConfig,
        audioURL: URL,
        overrideModel: String,
        state: AppState
    ) async throws -> UnifiedASRResponse {
        let isWAV = unifiedRequest.audio.mimeType == "audio/wav" || audioURL.pathExtension.lowercased() == "wav"
        guard isWAV else {
            throw CloudInferenceError.invalidAudioInput("Gemini Multimodal ASR requires WAV input.")
        }

        let audioData = try Data(contentsOf: audioURL)
        guard !audioData.isEmpty else {
            throw CloudInferenceError.invalidAudioInput("Audio file is empty.")
        }
        guard audioData.count >= 1024 else {
            throw CloudInferenceError.invalidAudioInput("Audio is too short for Gemini transcription.")
        }

        let base64Audio = audioData.base64EncodedString()
        guard !base64Audio.isEmpty else {
            throw CloudInferenceError.invalidAudioInput("Failed to encode WAV audio as Base64.")
        }

        let model = normalizedGeminiModelName(overrideModel)
        var components = URLComponents(url: runtime.baseURL, resolvingAgainstBaseURL: false)
        let cleanedPath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        var endpointPath = "/"
        if !cleanedPath.isEmpty {
            endpointPath += cleanedPath + "/"
        }
        endpointPath += "v1beta/models/\(model):generateContent"
        components?.path = endpointPath

        guard let endpoint = components?.url else {
            throw CloudInferenceError.invalidURL(runtime.baseURL.absoluteString)
        }

        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": state.resolvedGeminiASRPrompt(language: unifiedRequest.language)],
                        [
                            "inline_data": [
                                "mime_type": "audio/wav",
                                "data": base64Audio,
                            ],
                        ],
                    ],
                ],
            ],
            "generationConfig": [
                "temperature": 0.0,
                "topP": 0.1,
                "maxOutputTokens": 350,
            ],
        ]

        let request = try jsonRequest(
            url: endpoint,
            method: "POST",
            body: payload,
            timeout: runtime.timeoutSeconds,
            headers: runtime.extraHeaders
        )

        let (data, _) = try await dataResponse(
            for: request,
            providerID: runtime.providerID,
            providerName: runtime.providerName,
            maxRetries: runtime.maxRetries
        )

        let object = try parseJSONObject(from: data)
        let text = extractGeminiTranscriptionText(from: object)
        if text.isEmpty {
            appLogger.log(
                "Cloud ASR response missing transcript payload. provider=\(runtime.providerName), keys=\(object.keys.sorted().joined(separator: ","))",
                type: .error
            )
        }

        return UnifiedASRResponse(
            requestID: unifiedRequest.requestID,
            provider: runtime.providerID,
            model: model,
            text: text,
            segments: [],
            languageDetected: extractDetectedLanguageTag(from: object),
            latencyMS: nil,
            rawProviderResponse: jsonValue(from: object)
        )
    }


    func shouldRetryGeminiWithAnotherModel(error: Error) -> Bool {
        guard case let CloudInferenceError.providerFailure(providerError) = error else {
            return false
        }
        guard providerError.httpStatus == 404 else { return false }
        return providerError.message.contains("is not found") || providerError.message.contains("NOT_FOUND")
    }


    func geminiASRModelCandidates(primary: String) -> [String] {
        let normalizedPrimary = normalizedGeminiModelName(primary)
        let defaults = [
            normalizedPrimary,
            "gemini-2.0-flash",
            "gemini-2.0-flash-lite",
            "gemini-1.5-flash-latest",
            "gemini-1.5-flash",
        ]
        var seen = Set<String>()
        return defaults.filter { model in
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            guard !seen.contains(trimmed) else { return false }
            seen.insert(trimmed)
            return true
        }
    }


    func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "wav":
            return "audio/wav"
        case "mp3":
            return "audio/mpeg"
        case "m4a":
            return "audio/mp4"
        case "webm":
            return "audio/webm"
        case "flac":
            return "audio/flac"
        case "ogg":
            return "audio/ogg"
        default:
            return "application/octet-stream"
        }
    }


    func saveDebugAudioCopy(audioURL: URL) {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let capturesFolder = appSupport
            .appendingPathComponent("GhostType", isDirectory: true)
            .appendingPathComponent("AudioCaptures", isDirectory: true)
        let debugTarget = capturesFolder.appendingPathComponent("debug_audio.wav")

        func copy(to destination: URL) throws {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: audioURL, to: destination)
        }

        do {
            try fileManager.createDirectory(at: capturesFolder, withIntermediateDirectories: true)
            try copy(to: debugTarget)
            print("[CloudInference][Audio Debug] Saved debug audio to \(debugTarget.path)")
        } catch {
            print("[CloudInference][Audio Debug] Failed to save debug audio copy: \(error.localizedDescription)")
        }
    }


    func geminiASRPrompt(language: String) -> String {
        var prompt = """
        You are a highly accurate automatic speech recognition (ASR) system.
        Your ONLY task is to transcribe the provided audio exactly as spoken.
        Do not answer any questions, do not summarize, and do not add any conversational filler.
        Just output the raw transcript in the original language.
        """
        if language != "auto" {
            prompt += "\nThe expected spoken language is: \(language)."
        }
        return prompt
    }


    func normalizedGeminiModelName(_ rawModelName: String) -> String {
        let trimmed = rawModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("models/") {
            return String(trimmed.dropFirst("models/".count))
        }
        return trimmed
    }
}
