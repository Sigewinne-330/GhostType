import Foundation

// MARK: - LLM Runtime
// Responsibility: Send cloud LLM requests and stream output tokens back to callers.
// Public entry point: streamGenerate(request:rawText:asrDetectedLanguage:onToken:).
extension CloudInferenceProvider {
    func streamGenerate(
        request: InferenceRequest,
        rawText: String,
        asrDetectedLanguage: String?,
        onToken: @escaping (String) -> Void
    ) async throws -> (output: String, firstTokenLatencyMS: Double?, outputLanguagePolicy: String) {
        let prompt = buildPrompt(
            request: request,
            rawText: rawText,
            asrDetectedLanguage: asrDetectedLanguage,
            state: request.state
        )
        appLogger.log("Cloud LLM output language policy: \(prompt.outputLanguagePolicy).")
        appLogger.log(
            "Cloud LLM prompt prepared. mode=\(request.mode.rawValue) systemChars=\(prompt.system.count) userChars=\(prompt.user.count) maxTokens=\(min(max(2048, rawText.count * 2), 4096)) dictationPreset=\(request.dictationContext?.preset.title ?? "n/a").",
            type: .debug
        )
        appLogger.log("Cloud LLM SYSTEM PROMPT:\n\(prompt.system)", type: .debug)
        appLogger.log("Cloud LLM USER PROMPT:\n\(prompt.user)", type: .debug)
        let unifiedRequest = makeUnifiedLLMRequest(
            prompt: (system: prompt.system, user: prompt.user),
            mode: request.mode,
            rawText: rawText,
            state: request.state
        )
        let runtime = try await llmRuntimeConfig(for: request.state, unifiedRequest: unifiedRequest)
        appLogger.log(
            "Cloud LLM runtime resolved. provider=\(runtime.providerName) model=\(runtime.modelName) requestKind=\(runtime.requestKind) endpoint=\(runtime.baseURL.absoluteString)",
            type: .debug
        )

        let streamRequest: URLRequest
        switch runtime.requestKind {
        case .openAIChat:
            streamRequest = try buildOpenAIChatRequest(runtime: runtime, unifiedRequest: unifiedRequest)
        case .openAIResponses:
            streamRequest = try buildOpenAIResponsesRequest(runtime: runtime, unifiedRequest: unifiedRequest)
        case .azureOpenAIChat:
            streamRequest = try buildAzureOpenAIChatRequest(runtime: runtime, unifiedRequest: unifiedRequest, state: request.state)
        case .anthropic:
            streamRequest = try buildAnthropicRequest(runtime: runtime, unifiedRequest: unifiedRequest)
        case .gemini:
            streamRequest = try buildGeminiRequest(runtime: runtime, unifiedRequest: unifiedRequest)
        }
        if let bodyData = streamRequest.httpBody, let bodyStr = String(data: bodyData, encoding: .utf8) {
            let truncated = bodyStr.count > 2000 ? String(bodyStr.prefix(2000)) + "...[truncated]" : bodyStr
            appLogger.log("Cloud LLM HTTP BODY:\n\(truncated)", type: .debug)
        }

        let (bytes, _) = try await performWithRetry(
            providerID: runtime.providerID,
            providerName: runtime.providerName,
            operationName: "LLM stream connect",
            maxRetries: runtime.maxRetries
        ) {
            let (bytes, response) = try await self.session.bytes(for: streamRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PythonRunError.invalidResponse("No HTTP response from cloud LLM stream.")
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let body = try await self.readResponseBody(from: bytes)
                throw self.providerFailure(
                    providerID: runtime.providerID,
                    providerName: runtime.providerName,
                    statusCode: httpResponse.statusCode,
                    body: body,
                    requestID: self.extractRequestID(httpResponse)
                )
            }
            return (bytes, httpResponse)
        }

        var output = ""
        var emittedText = ""
        var firstTokenLatencyMS: Double?
        let streamStartedAt = Date()

        for try await line in bytes.lines {
            if Task.isCancelled {
                throw CancellationError()
            }

            guard let event = sseDataPayload(from: line) else { continue }
            if event == "[DONE]" {
                break
            }

            if firstTokenLatencyMS == nil {
                let eventSnippet = event.count > 500 ? String(event.prefix(500)) + "..." : event
                appLogger.log("Cloud LLM first SSE event:\n\(eventSnippet)", type: .debug)
            }

            guard
                let token = parseToken(
                    parserKind: runtime.parserKind,
                    payloadLine: event,
                    emittedText: &emittedText
                ),
                !token.isEmpty
            else {
                continue
            }

            if firstTokenLatencyMS == nil {
                firstTokenLatencyMS = Date().timeIntervalSince(streamStartedAt) * 1000
            }

            if output.isEmpty {
                output = token
            } else if token.hasPrefix(output) {
                output = token
            } else if output.hasPrefix(token) {
                continue
            } else {
                output += token
            }
            await MainActor.run {
                onToken(token)
            }
        }

        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudInferenceError.emptyLLMResponse
        }

        appLogger.log("Cloud LLM OUTPUT (\(output.count) chars):\n\(output)", type: .debug)
        return (output, firstTokenLatencyMS, prompt.outputLanguagePolicy)
    }


    private func makeUnifiedLLMRequest(
        prompt: (system: String, user: String),
        mode: WorkflowMode,
        rawText: String,
        state: AppState
    ) -> UnifiedLLMRequest {
        let configuredMax = state.llmMaxTokens
        let dynamicMaxTokens = min(max(2048, rawText.count * 2), configuredMax)
        return UnifiedLLMRequest(
            requestID: UUID().uuidString,
            mode: mode.rawValue,
            systemPrompt: prompt.system,
            messages: [UnifiedChatMessage(role: "user", content: prompt.user)],
            params: UnifiedLLMParams(
                stream: true,
                maxTokens: dynamicMaxTokens,
                temperature: state.llmTemperature,
                topP: state.llmTopP,
                stop: []
            ),
            tools: [],
            toolChoice: "auto",
            responseFormat: UnifiedResponseFormat(type: "text", jsonSchema: nil),
            metadata: UnifiedRequestMetadata(traceID: UUID().uuidString, privacyMode: state.privacyModeEnabled)
        )
    }


    private func llmRuntimeConfig(for state: AppState, unifiedRequest: UnifiedLLMRequest) async throws -> LLMRuntimeConfig {
        let configuredBase = state.cloudLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelInput = state.cloudLLMModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeoutSeconds = max(15, min(3600, state.cloudLLMTimeoutSec))
        let maxRetries = max(0, min(8, state.cloudLLMMaxRetries))
        let maxInFlight = max(1, min(8, state.cloudLLMMaxInFlight))
        let streamingEnabled = state.cloudLLMStreamingEnabled

        switch state.llmEngine {
        case .openAI:
            let key = try requiredAPIKey(.llmOpenAI, providerName: "Cloud OpenAI")
            let baseURL = try normalizedBaseURL(configuredBase.isEmpty ? LLMEngineOption.openAI.defaultBaseURL : configuredBase)
            let model = modelInput.isEmpty ? LLMEngineOption.openAI.defaultModelName : modelInput
            return makeOpenAIStyleLLMRuntime(
                providerID: "openai",
                providerName: "OpenAI",
                baseURL: baseURL,
                modelName: model,
                apiKey: key,
                timeoutSeconds: timeoutSeconds,
                maxRetries: maxRetries,
                maxInFlight: maxInFlight,
                streamingEnabled: streamingEnabled
            )
        case .openAICompatible:
            let key = try requiredAPIKey(.llmOpenAICompatible, providerName: "Cloud OpenAI-compatible LLM")
            let baseURL = try normalizedBaseURL(configuredBase.isEmpty ? LLMEngineOption.openAICompatible.defaultBaseURL : configuredBase)
            let model = modelInput.isEmpty ? LLMEngineOption.openAICompatible.defaultModelName : modelInput
            let endpoint = try await detectOpenAICompatiblePath(baseURL: baseURL, apiKey: key, modelName: model)
            return LLMRuntimeConfig(
                providerID: "openai_compatible",
                providerName: "OpenAI Compatible",
                baseURL: baseURL,
                modelName: model,
                apiKey: key,
                requestPath: endpoint == .chatCompletions ? "/v1/chat/completions" : "/v1/responses",
                requestKind: endpoint == .chatCompletions ? .openAIChat : .openAIResponses,
                parserKind: endpoint == .chatCompletions ? .openAIChat : .openAIResponses,
                timeoutSeconds: timeoutSeconds,
                maxRetries: maxRetries,
                maxInFlight: maxInFlight,
                streamingEnabled: streamingEnabled,
                extraHeaders: ["Authorization": "Bearer \(key)"],
                queryItems: []
            )
        case .customOpenAICompatible:
            let providerName = "Custom OpenAI-compatible LLM"
            let baseURL = try normalizedBaseURL(
                configuredBase.isEmpty ? LLMEngineOption.customOpenAICompatible.defaultBaseURL : configuredBase
            )
            let model = modelInput.isEmpty ? LLMEngineOption.customOpenAICompatible.defaultModelName : modelInput
            let requestPath = normalizedEndpointPath(
                state.cloudLLMRequestPath,
                fallback: LLMProviderRequestConfig.openAIDefault.path
            )
            let resolvedRequestKind: LLMRequestKind = requestPath.lowercased().hasSuffix("/responses")
                ? .openAIResponses
                : .openAIChat
            let resolvedParser: LLMTokenParserKind = resolvedRequestKind == .openAIResponses ? .openAIResponses : .openAIChat
            let extraHeaderMap = parseHeaderDictionary(from: state.cloudLLMHeadersJSON)
            let resolvedKey = try resolveAPIKey(
                mode: state.cloudLLMAuthMode,
                keyRef: state.cloudLLMApiKeyRef,
                fallbackKey: nil,
                providerName: providerName
            )
            var headers = extraHeaderMap
            if let authHeader = authHeaderValue(
                mode: state.cloudLLMAuthMode,
                apiKey: resolvedKey
            ) {
                headers["Authorization"] = authHeader
            }
            return LLMRuntimeConfig(
                providerID: "custom_openai_llm",
                providerName: providerName,
                baseURL: baseURL,
                modelName: model,
                apiKey: resolvedKey ?? "",
                requestPath: requestPath,
                requestKind: resolvedRequestKind,
                parserKind: resolvedParser,
                timeoutSeconds: timeoutSeconds,
                maxRetries: maxRetries,
                maxInFlight: maxInFlight,
                streamingEnabled: streamingEnabled,
                extraHeaders: headers,
                queryItems: []
            )
        case .azureOpenAI:
            let key = try requiredAPIKey(.llmAzureOpenAI, providerName: "Cloud Azure OpenAI")
            let baseURL = try normalizedBaseURL(configuredBase.isEmpty ? LLMEngineOption.azureOpenAI.defaultBaseURL : configuredBase)
            let model = modelInput.isEmpty ? LLMEngineOption.azureOpenAI.defaultModelName : modelInput
            return LLMRuntimeConfig(
                providerID: "azure_openai",
                providerName: "Azure OpenAI",
                baseURL: baseURL,
                modelName: model,
                apiKey: key,
                requestPath: "/openai/deployments/{deployment}/chat/completions",
                requestKind: .azureOpenAIChat,
                parserKind: .openAIChat,
                timeoutSeconds: timeoutSeconds,
                maxRetries: maxRetries,
                maxInFlight: maxInFlight,
                streamingEnabled: streamingEnabled,
                extraHeaders: ["api-key": key],
                queryItems: [
                    URLQueryItem(
                        name: "api-version",
                        value: state.cloudLLMAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "2024-02-01"
                            : state.cloudLLMAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                ]
            )
        case .anthropic:
            let key = try requiredAPIKey(.llmAnthropic, providerName: "Cloud Anthropic LLM")
            let baseURL = try normalizedBaseURL(configuredBase.isEmpty ? LLMEngineOption.anthropic.defaultBaseURL : configuredBase)
            let model = modelInput.isEmpty ? LLMEngineOption.anthropic.defaultModelName : modelInput
            return LLMRuntimeConfig(
                providerID: "anthropic",
                providerName: "Anthropic",
                baseURL: baseURL,
                modelName: model,
                apiKey: key,
                requestPath: "/v1/messages",
                requestKind: .anthropic,
                parserKind: .anthropic,
                timeoutSeconds: timeoutSeconds,
                maxRetries: maxRetries,
                maxInFlight: maxInFlight,
                streamingEnabled: streamingEnabled,
                extraHeaders: [
                    "x-api-key": key,
                    "anthropic-version": "2023-06-01",
                ],
                queryItems: []
            )
        case .gemini:
            let key = try requiredAPIKey(.llmGemini, providerName: "Cloud Gemini")
            let baseURL = try normalizedBaseURL(configuredBase.isEmpty ? LLMEngineOption.gemini.defaultBaseURL : configuredBase)
            let model = modelInput.isEmpty ? LLMEngineOption.gemini.defaultModelName : modelInput
            return LLMRuntimeConfig(
                providerID: "gemini",
                providerName: "Google Gemini",
                baseURL: baseURL,
                modelName: model,
                apiKey: key,
                requestPath: "/v1beta/models/{model}:streamGenerateContent",
                requestKind: .gemini,
                parserKind: .gemini,
                timeoutSeconds: timeoutSeconds,
                maxRetries: maxRetries,
                maxInFlight: maxInFlight,
                streamingEnabled: streamingEnabled,
                extraHeaders: ["x-goog-api-key": key],
                queryItems: [URLQueryItem(name: "alt", value: "sse")]
            )
        case .deepSeek:
            let key = try requiredAPIKey(.llmDeepSeek, providerName: "Cloud DeepSeek")
            let baseURL = try normalizedBaseURL(configuredBase.isEmpty ? LLMEngineOption.deepSeek.defaultBaseURL : configuredBase)
            let model = modelInput.isEmpty ? LLMEngineOption.deepSeek.defaultModelName : modelInput
            return makeOpenAIStyleLLMRuntime(
                providerID: "deepseek",
                providerName: "DeepSeek",
                baseURL: baseURL,
                modelName: model,
                apiKey: key,
                timeoutSeconds: timeoutSeconds,
                maxRetries: maxRetries,
                maxInFlight: maxInFlight,
                streamingEnabled: streamingEnabled
            )
        case .groq:
            let key = try requiredAPIKey(.llmGroq, providerName: "Cloud Groq LLM")
            let baseURL = try normalizedBaseURL(configuredBase.isEmpty ? LLMEngineOption.groq.defaultBaseURL : configuredBase)
            let model = modelInput.isEmpty ? LLMEngineOption.groq.defaultModelName : modelInput
            return makeOpenAIStyleLLMRuntime(
                providerID: "groq_llm",
                providerName: "Groq LLM",
                baseURL: baseURL,
                modelName: model,
                apiKey: key,
                timeoutSeconds: timeoutSeconds,
                maxRetries: maxRetries,
                maxInFlight: maxInFlight,
                streamingEnabled: streamingEnabled
            )
        case .ollama:
            let baseURL = try normalizedBaseURL(configuredBase.isEmpty ? LLMEngineOption.ollama.defaultBaseURL : configuredBase)
            let model = modelInput.isEmpty ? LLMEngineOption.ollama.defaultModelName : modelInput
            return makeOpenAIStyleLLMRuntime(
                providerID: "ollama",
                providerName: "Ollama",
                baseURL: baseURL,
                modelName: model,
                apiKey: "",
                timeoutSeconds: timeoutSeconds,
                maxRetries: maxRetries,
                maxInFlight: maxInFlight,
                streamingEnabled: streamingEnabled
            )
        case .lmStudio:
            let baseURL = try normalizedBaseURL(configuredBase.isEmpty ? LLMEngineOption.lmStudio.defaultBaseURL : configuredBase)
            let model = modelInput.isEmpty ? LLMEngineOption.lmStudio.defaultModelName : modelInput
            return makeOpenAIStyleLLMRuntime(
                providerID: "lm_studio",
                providerName: "LM Studio",
                baseURL: baseURL,
                modelName: model,
                apiKey: "",
                timeoutSeconds: timeoutSeconds,
                maxRetries: maxRetries,
                maxInFlight: maxInFlight,
                streamingEnabled: streamingEnabled
            )
        case .localMLX:
            throw CloudInferenceError.unsupportedLLMEngine
        }
    }


    private func makeOpenAIStyleLLMRuntime(
        providerID: String,
        providerName: String,
        baseURL: URL,
        modelName: String,
        apiKey: String,
        timeoutSeconds: TimeInterval,
        maxRetries: Int,
        maxInFlight: Int,
        streamingEnabled: Bool
    ) -> LLMRuntimeConfig {
        LLMRuntimeConfig(
            providerID: providerID,
            providerName: providerName,
            baseURL: baseURL,
            modelName: modelName,
            apiKey: apiKey,
            requestPath: "/v1/chat/completions",
            requestKind: .openAIChat,
            parserKind: .openAIChat,
            timeoutSeconds: timeoutSeconds,
            maxRetries: maxRetries,
            maxInFlight: maxInFlight,
            streamingEnabled: streamingEnabled,
            extraHeaders: ["Authorization": "Bearer \(apiKey)"],
            queryItems: []
        )
    }


    private func buildOpenAIChatRequest(runtime: LLMRuntimeConfig, unifiedRequest: UnifiedLLMRequest) throws -> URLRequest {
        let endpoint = appendingPath(runtime.requestPath, to: runtime.baseURL)
        let payload: [String: Any] = [
            "model": runtime.modelName,
            "stream": unifiedRequest.params.stream,
            "max_tokens": unifiedRequest.params.maxTokens,
            "temperature": unifiedRequest.params.temperature,
            "top_p": unifiedRequest.params.topP,
            "stop": unifiedRequest.params.stop,
            "messages": [
                ["role": "system", "content": unifiedRequest.systemPrompt],
                ["role": "user", "content": unifiedRequest.messages.first?.content ?? ""],
            ],
        ]
        return try jsonRequest(
            url: endpoint,
            method: "POST",
            body: payload,
            timeout: runtime.timeoutSeconds,
            headers: runtime.extraHeaders
        )
    }


    private func buildOpenAIResponsesRequest(runtime: LLMRuntimeConfig, unifiedRequest: UnifiedLLMRequest) throws -> URLRequest {
        let endpoint = appendingPath(runtime.requestPath, to: runtime.baseURL)
        let payload: [String: Any] = [
            "model": runtime.modelName,
            "stream": unifiedRequest.params.stream,
            "max_output_tokens": unifiedRequest.params.maxTokens,
            "temperature": unifiedRequest.params.temperature,
            "top_p": unifiedRequest.params.topP,
            "input": [
                [
                    "role": "system",
                    "content": [["type": "input_text", "text": unifiedRequest.systemPrompt]],
                ],
                [
                    "role": "user",
                    "content": [["type": "input_text", "text": unifiedRequest.messages.first?.content ?? ""]],
                ],
            ],
        ]
        return try jsonRequest(
            url: endpoint,
            method: "POST",
            body: payload,
            timeout: runtime.timeoutSeconds,
            headers: runtime.extraHeaders
        )
    }


    private func buildAzureOpenAIChatRequest(
        runtime: LLMRuntimeConfig,
        unifiedRequest: UnifiedLLMRequest,
        state: AppState
    ) throws -> URLRequest {
        var components = URLComponents(url: runtime.baseURL, resolvingAgainstBaseURL: false)
        let cleanedPath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let deployment = runtime.modelName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runtime.modelName

        var endpointPath = "/"
        if !cleanedPath.isEmpty {
            endpointPath += cleanedPath + "/"
        }
        endpointPath += "openai/deployments/\(deployment)/chat/completions"
        components?.path = endpointPath

        let apiVersion = state.cloudLLMAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        components?.queryItems = [
            URLQueryItem(name: "api-version", value: apiVersion.isEmpty ? "2024-02-01" : apiVersion),
        ]

        guard let endpoint = components?.url else {
            throw CloudInferenceError.invalidURL(runtime.baseURL.absoluteString)
        }

        let payload: [String: Any] = [
            "stream": unifiedRequest.params.stream,
            "max_tokens": unifiedRequest.params.maxTokens,
            "temperature": unifiedRequest.params.temperature,
            "top_p": unifiedRequest.params.topP,
            "stop": unifiedRequest.params.stop,
            "messages": [
                ["role": "system", "content": unifiedRequest.systemPrompt],
                ["role": "user", "content": unifiedRequest.messages.first?.content ?? ""],
            ],
        ]

        return try jsonRequest(
            url: endpoint,
            method: "POST",
            body: payload,
            timeout: runtime.timeoutSeconds,
            headers: runtime.extraHeaders
        )
    }


    private func buildAnthropicRequest(runtime: LLMRuntimeConfig, unifiedRequest: UnifiedLLMRequest) throws -> URLRequest {
        let endpoint = runtime.baseURL.appendingPathComponent("v1/messages")
        let payload: [String: Any] = [
            "model": runtime.modelName,
            "max_tokens": unifiedRequest.params.maxTokens,
            "stream": unifiedRequest.params.stream,
            "temperature": unifiedRequest.params.temperature,
            "top_p": unifiedRequest.params.topP,
            "stop_sequences": unifiedRequest.params.stop,
            "system": unifiedRequest.systemPrompt,
            "messages": [
                ["role": "user", "content": unifiedRequest.messages.first?.content ?? ""],
            ],
        ]

        return try jsonRequest(
            url: endpoint,
            method: "POST",
            body: payload,
            timeout: runtime.timeoutSeconds,
            headers: runtime.extraHeaders
        )
    }


    private func buildGeminiRequest(runtime: LLMRuntimeConfig, unifiedRequest: UnifiedLLMRequest) throws -> URLRequest {
        var components = URLComponents(url: runtime.baseURL, resolvingAgainstBaseURL: false)
        let cleanedPath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""

        var endpointPath = "/"
        if !cleanedPath.isEmpty {
            endpointPath += cleanedPath + "/"
        }
        endpointPath += "v1beta/models/\(runtime.modelName):streamGenerateContent"
        components?.path = endpointPath
        components?.queryItems = runtime.queryItems

        guard let endpoint = components?.url else {
            throw CloudInferenceError.invalidURL(runtime.baseURL.absoluteString)
        }

        let payload: [String: Any] = [
            "system_instruction": [
                "parts": [
                    ["text": unifiedRequest.systemPrompt],
                ],
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": unifiedRequest.messages.first?.content ?? ""],
                    ],
                ],
            ],
            "generationConfig": [
                "maxOutputTokens": unifiedRequest.params.maxTokens,
                "temperature": unifiedRequest.params.temperature,
                "topP": unifiedRequest.params.topP,
                "stopSequences": unifiedRequest.params.stop,
            ],
        ]

        return try jsonRequest(
            url: endpoint,
            method: "POST",
            body: payload,
            timeout: runtime.timeoutSeconds,
            headers: runtime.extraHeaders
        )
    }
}
