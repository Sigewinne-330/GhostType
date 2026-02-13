import Foundation

// MARK: - LLM Capability Probe
// Responsibility: Detect OpenAI-compatible endpoint behavior and cache probe results.
// Public entry point: detectOpenAICompatiblePath(baseURL:apiKey:modelName:).
extension CloudInferenceProvider {
    func detectOpenAICompatiblePath(
        baseURL: URL,
        apiKey: String,
        modelName: String
    ) async throws -> OpenAICompatibleEndpointKind {
        let cacheKey = "\(baseURL.absoluteString)#\(modelName)"
        if let cached = openAICompatiblePathCache[cacheKey] {
            return cached
        }

        if try await probeOpenAICompatiblePath(baseURL: baseURL, apiKey: apiKey, modelName: modelName, endpointKind: .chatCompletions) {
            openAICompatiblePathCache[cacheKey] = .chatCompletions
            return .chatCompletions
        }

        if try await probeOpenAICompatiblePath(baseURL: baseURL, apiKey: apiKey, modelName: modelName, endpointKind: .responses) {
            openAICompatiblePathCache[cacheKey] = .responses
            return .responses
        }

        throw CloudInferenceError.openAICompatiblePathDetectionFailed
    }


    private func probeOpenAICompatiblePath(
        baseURL: URL,
        apiKey: String,
        modelName: String,
        endpointKind: OpenAICompatibleEndpointKind
    ) async throws -> Bool {
        let endpoint: URL
        let payload: [String: Any]

        switch endpointKind {
        case .chatCompletions:
            endpoint = baseURL.appendingPathComponent("chat/completions")
            payload = [
                "model": modelName,
                "stream": false,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "ping"]],
            ]
        case .responses:
            endpoint = baseURL.appendingPathComponent("responses")
            payload = [
                "model": modelName,
                "stream": false,
                "max_output_tokens": 1,
                "input": "ping",
            ]
        }

        let request = try jsonRequest(
            url: endpoint,
            method: "POST",
            body: payload,
            timeout: 30,
            headers: ["Authorization": "Bearer \(apiKey)"]
        )

        do {
            let (data, response) = try await performWithRetry(
                providerID: "openai_compatible_probe",
                providerName: "OpenAI Compatible",
                operationName: endpointKind == .chatCompletions ? "Probe /chat/completions" : "Probe /responses"
            ) {
                let (data, response) = try await self.session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw PythonRunError.invalidResponse("No HTTP response from OpenAI-compatible probe.")
                }

                if (200...299).contains(httpResponse.statusCode) {
                    return (data, response)
                }

                if httpResponse.statusCode == 429 || (500...599).contains(httpResponse.statusCode) {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw self.providerFailure(
                        providerID: "openai_compatible_probe",
                        providerName: "OpenAI Compatible",
                        statusCode: httpResponse.statusCode,
                        body: body,
                        requestID: self.extractRequestID(httpResponse)
                    )
                }
                return (data, response)
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            if (200...299).contains(httpResponse.statusCode) {
                return true
            }
            if let body = String(data: data, encoding: .utf8), !body.isEmpty {
                let bodyDetails = privacyModeEnabled ? "[REDACTED] \(redactedBodySummary(body))" : body
                appLogger.log(
                    "OpenAI-compatible probe returned HTTP \(httpResponse.statusCode): \(bodyDetails)",
                    type: .warning
                )
            }
            return false
        } catch {
            return false
        }
    }
}
