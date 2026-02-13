import CryptoKit
import Foundation
import Security

protocol RetryPolicy {
    var maxAttempts: Int { get }
    func delayNanoseconds(forAttempt attempt: Int) -> UInt64
}

struct ExponentialBackoffRetryPolicy: RetryPolicy {
    let maxAttempts: Int
    let baseDelayMS: UInt64
    let maxDelayMS: UInt64
    let jitterRangeMS: ClosedRange<UInt64>

    func delayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        let exponent = max(0, attempt - 1)
        let expDelay = baseDelayMS << exponent
        let bounded = min(expDelay, maxDelayMS)
        let jitter = UInt64.random(in: jitterRangeMS)
        let totalMS = min(maxDelayMS, bounded + jitter)
        return totalMS * 1_000_000
    }
}

enum RetryExecutor {
    static func run<T>(
        policy: any RetryPolicy,
        shouldRetry: (Error) -> Bool,
        onRetry: (Int, Int, UInt64) -> Void = { _, _, _ in },
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var attempt = 0
        var lastError: Error?

        while attempt < policy.maxAttempts {
            if Task.isCancelled {
                throw CancellationError()
            }

            attempt += 1
            do {
                return try await operation()
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                lastError = error
                let hasNextAttempt = attempt < policy.maxAttempts
                guard hasNextAttempt, shouldRetry(error) else {
                    throw error
                }
                let delayNS = policy.delayNanoseconds(forAttempt: attempt)
                onRetry(attempt, policy.maxAttempts - 1, delayNS)
                try await Task.sleep(nanoseconds: delayNS)
            }
        }

        throw lastError ?? CloudInferenceError.invalidJSONResponse("Unknown cloud retry failure.")
    }
}

// MARK: - Shared Support
// Responsibility: Retry policies, HTTP helpers, request building, and key retrieval shared by ASR/LLM runtimes.
// Public entry points: performWithRetry, dataResponse, providerFailure, requiredAPIKey.
extension CloudInferenceProvider {
    func performWithRetry<T>(
        providerID: String,
        providerName: String,
        operationName: String,
        maxRetries: Int? = nil,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        let policy: any RetryPolicy = {
            guard let maxRetries else { return retryPolicy }
            let clamped = max(0, min(8, maxRetries))
            return ExponentialBackoffRetryPolicy(
                maxAttempts: clamped + 1,
                baseDelayMS: retryPolicy.baseDelayMS,
                maxDelayMS: retryPolicy.maxDelayMS,
                jitterRangeMS: retryPolicy.jitterRangeMS
            )
        }()
        return try await RetryExecutor.run(
            policy: policy,
            shouldRetry: { [weak self] error in
                self?.shouldRetry(error: error) ?? false
            },
            onRetry: { [weak self] attempt, maxRetries, delayNS in
                guard let self else { return }
                let delayMS = delayNS / 1_000_000
                self.appLogger.log(
                    "Cloud request retry \(attempt)/\(maxRetries) for \(providerName) [\(providerID)] \(operationName). Next delay: \(delayMS)ms.",
                    type: .warning
                )
            },
            operation: operation
        )
    }


    func shouldRetry(error: Error) -> Bool {
        if let cloudError = error as? CloudInferenceError,
           case .providerFailure(let providerError) = cloudError {
            return providerError.retryable
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
                 .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed:
                return true
            default:
                return false
            }
        }

        return false
    }


    func readResponseBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            if Task.isCancelled {
                throw CancellationError()
            }
            data.append(byte)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }


    func dataResponse(
        for request: URLRequest,
        providerID: String,
        providerName: String,
        maxRetries: Int? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        try await performWithRetry(
            providerID: providerID,
            providerName: providerName,
            operationName: "HTTP request",
            maxRetries: maxRetries
        ) {
            let (data, response) = try await self.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PythonRunError.invalidResponse("No HTTP response from cloud provider.")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw self.providerFailure(
                    providerID: providerID,
                    providerName: providerName,
                    statusCode: httpResponse.statusCode,
                    body: body,
                    requestID: self.extractRequestID(httpResponse)
                )
            }

            return (data, httpResponse)
        }
    }


    func providerFailure(
        providerID: String,
        providerName: String,
        statusCode: Int,
        body: String,
        requestID: String?
    ) -> CloudInferenceError {
        let retryable = statusCode == 429 || (500...599).contains(statusCode)
        let suggestion: String
        switch statusCode {
        case 400:
            suggestion = "Bad request. Check audio encoding, headers, or required parameters."
        case 401:
            suggestion = "Check that your API key is correct."
        case 403:
            suggestion = "Check account permissions, project binding, or model access."
        case 404:
            suggestion = "Check Base URL, model name, or endpoint path."
        case 413:
            suggestion = "Audio file too large. Shorten recording or reduce sample rate."
        case 429:
            suggestion = "Rate limited. Reduce concurrency or try again later."
        case 500...599:
            suggestion = "Provider service error. Try again later."
        default:
            suggestion = "Check configuration and try again."
        }

        let summary = redactedBodySummary(body)
        let message: String
        if privacyModeEnabled {
            message = "\(providerName) request failed: HTTP \(statusCode). \(summary)"
        } else {
            message = "\(providerName) request failed: HTTP \(statusCode). \(body)"
        }

        let providerError = UnifiedProviderError(
            provider: providerID,
            httpStatus: statusCode,
            errorCode: nil,
            message: message,
            requestID: requestID,
            retryable: retryable,
            suggestion: suggestion
        )
        logHTTPErrorToConsole(
            providerName: providerName,
            statusCode: statusCode,
            requestID: requestID,
            body: body,
            summary: summary
        )
        return .providerFailure(providerError)
    }


    func logHTTPErrorToConsole(
        providerName: String,
        statusCode: Int,
        requestID: String?,
        body: String,
        summary: String
    ) {
        let bodyLog = privacyModeEnabled ? "[REDACTED] \(summary)" : body
        print(
            """
            [CloudInference][HTTP Error]
            provider=\(providerName)
            status=\(statusCode)
            request_id=\(requestID ?? "n/a")
            response_body=\(bodyLog)
            """
        )
    }


    func redactedBodySummary(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "response_body=empty"
        }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let keys = object.keys.sorted().joined(separator: ",")
            return "response_body_chars=\(trimmed.count),json_keys=[\(keys)]"
        }
        return "response_body_chars=\(trimmed.count),format=text"
    }


    func extractRequestID(_ response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "x-request-id")
            ?? response.value(forHTTPHeaderField: "request-id")
            ?? response.value(forHTTPHeaderField: "anthropic-request-id")
    }


    func parseJSONObject(from data: Data) throws -> [String: Any] {
        try parseJSONObjectPayload(data) { payload in
            CloudInferenceError.invalidJSONResponse(payload)
        }
    }


    func jsonRequest(
        url: URL,
        method: String,
        body: [String: Any],
        timeout: TimeInterval,
        headers: [String: String]
    ) throws -> URLRequest {
        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }


    func requiredAPIKey(_ keyType: APISecretKey, providerName: String) throws -> String {
        let keychain = AppKeychain.shared
        if keychain.presenceHint(for: keyType) == .missing {
            throw InferenceRoutingError.missingAPIKey(providerName)
        }

        let value = try keychain.getSecret(for: keyType, policy: .noUserInteraction)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            keychain.markCredentialMissing(for: keyType)
            throw InferenceRoutingError.missingAPIKey(providerName)
        }
        return value
    }

    func requiredAPIKey(forRef keyRef: String, providerName: String) throws -> String {
        let trimmedRef = keyRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRef.isEmpty else {
            throw InferenceRoutingError.missingAPIKey(providerName)
        }
        let value = try AppKeychain.shared.getSecret(forRef: trimmedRef, policy: .noUserInteraction)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw InferenceRoutingError.missingAPIKey(providerName)
        }
        return value
    }


    func optionalAPIKey(_ keyType: APISecretKey) -> String? {
        let value = (try? AppKeychain.shared.getSecret(for: keyType, policy: .noUserInteraction))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            appLogger.log(
                "optionalAPIKey returned nil: missing value for \(keyType.rawValue).",
                type: .warning
            )
            return nil
        }
        return value
    }

    func optionalAPIKey(forRef keyRef: String) -> String? {
        let trimmedRef = keyRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRef.isEmpty else {
            appLogger.log("optionalAPIKey(forRef:) returned nil: empty keyRef.", type: .warning)
            return nil
        }
        let value = (try? AppKeychain.shared.getSecret(forRef: trimmedRef, policy: .noUserInteraction))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            appLogger.log(
                "optionalAPIKey(forRef:) returned nil: missing value for keyRef=\(trimmedRef).",
                type: .warning
            )
            return nil
        }
        return value
    }

    func resolveAPIKey(
        mode: ProviderAuthMode,
        keyRef: String,
        fallbackKey: APISecretKey?,
        providerName: String
    ) throws -> String? {
        switch mode {
        case .none:
            return nil
        case .bearer:
            let trimmedRef = keyRef.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedRef.isEmpty {
                return try requiredAPIKey(forRef: trimmedRef, providerName: providerName)
            }
            if let fallbackKey {
                return try requiredAPIKey(fallbackKey, providerName: providerName)
            }
            throw InferenceRoutingError.missingAPIKey(providerName)
        case .headers:
            let trimmedRef = keyRef.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRef.isEmpty else { return nil }
            return optionalAPIKey(forRef: trimmedRef)
        case .vendorSpecific:
            let trimmedRef = keyRef.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRef.isEmpty else { return nil }
            return optionalAPIKey(forRef: trimmedRef)
        }
    }

    func authHeaderValue(mode: ProviderAuthMode, apiKey: String?) -> String? {
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        switch mode {
        case .bearer, .vendorSpecific:
            return "Bearer \(trimmed)"
        case .none, .headers:
            return nil
        }
    }

    func parseHeaderDictionary(from rawJSON: String) -> [String: String] {
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let data = trimmed.data(using: .utf8) else { return [:] }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            return object
        }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var mapped: [String: String] = [:]
            for (key, value) in object {
                let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedKey.isEmpty else { continue }
                if let valueString = value as? String {
                    mapped[trimmedKey] = valueString
                } else {
                    mapped[trimmedKey] = "\(value)"
                }
            }
            return mapped
        }

        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var mapped: [String: String] = [:]
            for item in array {
                guard let rawKey = item["key"] as? String else { continue }
                let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                mapped[key] = (item["value"] as? String) ?? ""
            }
            return mapped
        }

        return [:]
    }


    func normalizedBaseURL(_ rawValue: String) throws -> URL {
        let cleaned = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw InferenceRoutingError.missingBaseURL
        }
        let candidate = cleaned.contains("://") ? cleaned : "https://\(cleaned)"
        guard let components = URLComponents(string: candidate),
              components.host != nil,
              let url = components.url else {
            throw CloudInferenceError.invalidURL(cleaned)
        }
        return url
    }

    func normalizedEndpointPath(_ rawValue: String, fallback: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = trimmed.isEmpty ? fallback : trimmed
        guard !selected.isEmpty else { return "/" }
        if selected.hasPrefix("/") {
            return selected
        }
        return "/\(selected)"
    }

    func appendingPath(_ path: String, to baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let mergedPath: String
        if basePath.isEmpty {
            mergedPath = suffix
        } else if suffix.isEmpty {
            mergedPath = basePath
        } else if suffix.caseInsensitiveCompare(basePath) == .orderedSame
            || suffix.lowercased().hasPrefix(basePath.lowercased() + "/") {
            mergedPath = suffix
        } else {
            mergedPath = "\(basePath)/\(suffix)"
        }
        components?.path = mergedPath.isEmpty ? "/" : "/\(mergedPath)"
        return components?.url ?? baseURL
    }


    func jsonValue(from value: Any) -> JSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let int as Int:
            return .integer(int)
        case let double as Double:
            return .number(double)
        case let bool as Bool:
            return .bool(bool)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if String(cString: number.objCType) == "q" || String(cString: number.objCType) == "i" {
                return .integer(number.intValue)
            }
            return .number(number.doubleValue)
        case let dict as [String: Any]:
            var mapped: [String: JSONValue] = [:]
            mapped.reserveCapacity(dict.count)
            for (key, child) in dict {
                mapped[key] = jsonValue(from: child)
            }
            return .object(mapped)
        case let array as [Any]:
            return .array(array.map { jsonValue(from: $0) })
        default:
            return .null
        }
    }
}

private struct ProbeModelCacheKey: Hashable {
    let provider: String
    let endpoint: String
    let apiKeyFingerprint: String

    init(provider: String, endpoint: URL, apiKey: String) {
        self.provider = provider
        self.endpoint = endpoint.absoluteString
        self.apiKeyFingerprint = Self.fingerprint(apiKey)
    }

    private static func fingerprint(_ value: String) -> String {
        let data = Data(value.utf8)
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

private actor ProbeModelCache {
    private struct Entry {
        let value: [String]
        let expiresAt: Date
    }

    private let ttlSeconds: TimeInterval
    private var store: [ProbeModelCacheKey: Entry] = [:]

    init(ttlSeconds: TimeInterval) {
        self.ttlSeconds = ttlSeconds
    }

    func value(for key: ProbeModelCacheKey) -> [String]? {
        guard let entry = store[key] else { return nil }
        if Date() > entry.expiresAt {
            store.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    func store(_ value: [String], for key: ProbeModelCacheKey) {
        store[key] = Entry(
            value: value,
            expiresAt: Date().addingTimeInterval(ttlSeconds)
        )
    }
}

enum EngineProbeClient {
    private static let probeRetryPolicy = ExponentialBackoffRetryPolicy(
        maxAttempts: 3,
        baseDelayMS: 250,
        maxDelayMS: 1_200,
        jitterRangeMS: 0...80
    )
    private static let modelCache = ProbeModelCache(ttlSeconds: 300)

    enum ProbeError: LocalizedError {
        case invalidBaseURL(String)
        case missingAPIKey(String)
        case invalidHTTPResponse
        case httpStatus(Int, String)
        case invalidPayload(String)

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL(let value):
                return "Invalid Base URL: \(value)"
            case .missingAPIKey(let label):
                return "\(label) API Key is empty."
            case .invalidHTTPResponse:
                return "API returned an invalid HTTP response."
            case .httpStatus(let code, let body):
                let summary = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if summary.isEmpty {
                    return "HTTP \(code)"
                }
                return "HTTP \(code): \(summary)"
            case .invalidPayload(let message):
                return message
            }
        }
    }

    static func fetchOpenAIModelIDs(baseURLRaw: String, apiKey: String) async throws -> [String] {
        let baseURL = try normalizedBaseURL(baseURLRaw)
        let endpoint = appendingPath("models", to: baseURL)
        let cacheKey = ProbeModelCacheKey(provider: "openai.models", endpoint: endpoint, apiKey: apiKey)
        if let cached = await modelCache.value(for: cacheKey) {
            return cached
        }
        let request = makeRequest(
            url: endpoint,
            headers: ["Authorization": "Bearer \(apiKey)"]
        )
        let data = try await performRequest(request)
        let object = try parseProbeJSONObject(data)
        let dataArray = object["data"] as? [[String: Any]] ?? []
        let ids = dataArray.compactMap { $0["id"] as? String }
        let normalized = uniqueModelIDs(ids)
        await modelCache.store(normalized, for: cacheKey)
        return normalized
    }

    static func fetchGeminiModelIDs(baseURLRaw: String, apiKey: String) async throws -> [String] {
        let baseURL = try normalizedBaseURL(baseURLRaw)
        let basePath = baseURL.path.lowercased()
        let suffix = basePath.contains("v1beta") ? "models" : "v1beta/models"
        var components = URLComponents(url: appendingPath(suffix, to: baseURL), resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "key", value: apiKey))
        components?.queryItems = queryItems
        guard let endpoint = components?.url else {
            throw ProbeError.invalidBaseURL(baseURLRaw)
        }
        let cacheKey = ProbeModelCacheKey(provider: "gemini.models", endpoint: endpoint, apiKey: apiKey)
        if let cached = await modelCache.value(for: cacheKey) {
            return cached
        }
        let request = makeRequest(url: endpoint, headers: [:])
        let data = try await performRequest(request)
        let object = try parseProbeJSONObject(data)
        let models = object["models"] as? [[String: Any]] ?? []
        let ids = models.compactMap { model -> String? in
            guard let name = model["name"] as? String else { return nil }
            if name.hasPrefix("models/") {
                return String(name.dropFirst("models/".count))
            }
            return name
        }
        let normalized = uniqueModelIDs(ids)
        await modelCache.store(normalized, for: cacheKey)
        return normalized
    }

    static func fetchAnthropicModelIDs(baseURLRaw: String, apiKey: String) async throws -> [String] {
        let baseURL = try normalizedBaseURL(baseURLRaw)
        let basePath = baseURL.path.lowercased()
        let suffix = basePath.contains("/v1") ? "models" : "v1/models"
        let endpoint = appendingPath(suffix, to: baseURL)
        let cacheKey = ProbeModelCacheKey(provider: "anthropic.models", endpoint: endpoint, apiKey: apiKey)
        if let cached = await modelCache.value(for: cacheKey) {
            return cached
        }
        let request = makeRequest(
            url: endpoint,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
            ]
        )
        let data = try await performRequest(request)
        let object = try parseProbeJSONObject(data)
        let dataArray = object["data"] as? [[String: Any]] ?? []
        let ids = dataArray.compactMap { $0["id"] as? String }
        let normalized = uniqueModelIDs(ids)
        await modelCache.store(normalized, for: cacheKey)
        return normalized
    }

    static func fetchDeepgramProjectCount(baseURLRaw: String, apiKey: String) async throws -> Int {
        let baseURL = try normalizedBaseURL(baseURLRaw)
        let endpoint = appendingPath("v1/projects", to: baseURL)
        let request = makeRequest(
            url: endpoint,
            headers: ["Authorization": "Token \(apiKey)"]
        )
        let data = try await performRequest(request)
        let object = try parseProbeJSONObject(data)
        let projects = object["projects"] as? [[String: Any]] ?? []
        return projects.count
    }

    static func runDeepgramBatchProbe(
        baseURLRaw: String,
        apiKey: String,
        queryConfig: DeepgramQueryConfig,
        region: DeepgramRegionOption
    ) async throws -> String {
        guard let endpointBase = DeepgramConfig.endpointURL(
            baseURLRaw: baseURLRaw,
            mode: .batch,
            fallbackRegion: region
        ) else {
            throw ProbeError.invalidBaseURL(baseURLRaw)
        }

        let batchConfig = deepgramBatchConfig(from: queryConfig)
        var components = URLComponents(url: endpointBase, resolvingAgainstBaseURL: false)
        components?.queryItems = DeepgramConfig.buildQueryItems(config: batchConfig)
        guard let endpoint = components?.url else {
            throw ProbeError.invalidBaseURL(endpointBase.absoluteString)
        }

        let sampleAudio = makeSilentWAVSample(durationMS: 320)
        var request = makeRequest(
            url: endpoint,
            method: "POST",
            headers: [
                "Authorization": "Token \(apiKey)",
                "Content-Type": "audio/wav",
            ],
            timeout: 30
        )
        request.httpBody = sampleAudio

        let data = try await performRequest(request)
        let object = try parseProbeJSONObject(data)
        let transcript = extractDeepgramTranscript(from: object)
        if transcript.isEmpty {
            return "Batch OK: authenticated (empty transcript for silent sample)."
        }
        return "Batch OK: \"\(previewText(transcript))\""
    }

    static func runDeepgramStreamingProbe(
        baseURLRaw: String,
        apiKey: String,
        queryConfig: DeepgramQueryConfig,
        region: DeepgramRegionOption
    ) async throws -> String {
        guard let endpointBase = DeepgramConfig.endpointURL(
            baseURLRaw: baseURLRaw,
            mode: .streaming,
            fallbackRegion: region
        ) else {
            throw ProbeError.invalidBaseURL(baseURLRaw)
        }

        var components = URLComponents(url: endpointBase, resolvingAgainstBaseURL: false)
        components?.queryItems = DeepgramConfig.buildQueryItems(
            config: DeepgramQueryConfig(
                modelName: queryConfig.modelName,
                language: queryConfig.language,
                endpointingMS: queryConfig.endpointingMS,
                interimResults: queryConfig.interimResults,
                smartFormat: queryConfig.smartFormat,
                punctuate: queryConfig.punctuate,
                paragraphs: queryConfig.paragraphs,
                diarize: queryConfig.diarize,
                terminologyRawValue: queryConfig.terminologyRawValue,
                mode: .streaming
            )
        )
        guard let endpoint = components?.url else {
            throw ProbeError.invalidBaseURL(endpointBase.absoluteString)
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
        }

        let sampleAudio = makeSilentWAVSample(durationMS: 1_000)
        try await socket.send(.data(sampleAudio))
        try await socket.send(.string("{\"type\":\"CloseStream\"}"))

        var receivedJSON = false
        var firstType = "unknown"
        var transcript = ""

        for _ in 0..<120 {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await receiveWebSocketMessage(from: socket, timeoutSeconds: 5)
            } catch {
                break
            }
            guard let payload = decodeWebSocketJSON(message: message) else {
                continue
            }
            receivedJSON = true
            if let type = payload["type"] as? String, !type.isEmpty {
                firstType = type
            }
            let candidate = extractDeepgramTranscript(from: payload)
            if !candidate.isEmpty {
                transcript = candidate
            }
            if (payload["speech_final"] as? Bool ?? false) || (payload["is_final"] as? Bool ?? false) {
                break
            }
        }

        guard receivedJSON else {
            throw ProbeError.invalidPayload("Deepgram streaming probe did not receive JSON messages.")
        }
        if transcript.isEmpty {
            return "Streaming OK: received JSON message (\(firstType))."
        }
        return "Streaming OK: \"\(previewText(transcript))\""
    }

    static func fetchAssemblyAITranscriptCount(baseURLRaw: String, apiKey: String) async throws -> Int {
        let baseURL = try normalizedBaseURL(baseURLRaw)
        var components = URLComponents(url: appendingPath("v2/transcript", to: baseURL), resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "limit", value: "1"))
        components?.queryItems = queryItems
        guard let endpoint = components?.url else {
            throw ProbeError.invalidBaseURL(baseURLRaw)
        }
        let request = makeRequest(
            url: endpoint,
            headers: ["Authorization": apiKey]
        )
        let data = try await performRequest(request)
        let object = try parseProbeJSONObject(data)
        if let transcripts = object["transcripts"] as? [[String: Any]] {
            return transcripts.count
        }
        return 0
    }

    static func runOpenAIChatProbe(
        baseURLRaw: String,
        apiKey: String,
        model: String,
        allowResponsesFallback: Bool
    ) async throws -> String {
        let baseURL = try normalizedBaseURL(baseURLRaw)
        let endpoint = appendingPath("chat/completions", to: baseURL)
        let payload: [String: Any] = [
            "model": model,
            "stream": false,
            "max_tokens": 24,
            "messages": [["role": "user", "content": "Reply with one short word: pong"]],
        ]
        let request = try makeJSONRequest(
            url: endpoint,
            body: payload,
            headers: ["Authorization": "Bearer \(apiKey)"]
        )
        do {
            let data = try await performRequest(request)
            let object = try parseProbeJSONObject(data)
            let text = extractOpenAIChatText(from: object)
            if text.isEmpty {
                return "Connected (empty response)"
            }
            return text
        } catch ProbeError.httpStatus(let code, _) where code == 404 && allowResponsesFallback {
            return try await runOpenAIResponsesProbe(baseURL: baseURL, apiKey: apiKey, model: model)
        }
    }

    static func runAzureOpenAIProbe(
        baseURLRaw: String,
        apiKey: String,
        deployment: String,
        apiVersion: String
    ) async throws -> String {
        let baseURL = try normalizedBaseURL(baseURLRaw)
        var endpoint = appendingPath("openai/deployments/\(deployment)/chat/completions", to: baseURL)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "api-version", value: apiVersion))
        components?.queryItems = queryItems
        guard let withQuery = components?.url else {
            throw ProbeError.invalidBaseURL(baseURLRaw)
        }
        endpoint = withQuery
        let payload: [String: Any] = [
            "stream": false,
            "max_tokens": 24,
            "messages": [["role": "user", "content": "Reply with one short word: pong"]],
        ]
        let request = try makeJSONRequest(
            url: endpoint,
            body: payload,
            headers: ["api-key": apiKey]
        )
        let data = try await performRequest(request)
        let object = try parseProbeJSONObject(data)
        let text = extractOpenAIChatText(from: object)
        return text.isEmpty ? "Connected (empty response)" : text
    }

    static func runAnthropicProbe(baseURLRaw: String, apiKey: String, model: String) async throws -> String {
        let baseURL = try normalizedBaseURL(baseURLRaw)
        let basePath = baseURL.path.lowercased()
        let suffix = basePath.contains("/v1") ? "messages" : "v1/messages"
        let endpoint = appendingPath(suffix, to: baseURL)
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 24,
            "messages": [["role": "user", "content": "Reply with one short word: pong"]],
        ]
        let request = try makeJSONRequest(
            url: endpoint,
            body: payload,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
            ]
        )
        let data = try await performRequest(request)
        let object = try parseProbeJSONObject(data)
        let content = object["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Connected (empty response)" : text
    }

    static func runGeminiProbe(baseURLRaw: String, apiKey: String, model: String) async throws -> String {
        let baseURL = try normalizedBaseURL(baseURLRaw)
        let normalizedModel: String = {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("models/") {
                return String(trimmed.dropFirst("models/".count))
            }
            return trimmed
        }()
        let basePath = baseURL.path.lowercased()
        let suffix = basePath.contains("v1beta")
            ? "models/\(normalizedModel):generateContent"
            : "v1beta/models/\(normalizedModel):generateContent"
        var components = URLComponents(url: appendingPath(suffix, to: baseURL), resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "key", value: apiKey))
        components?.queryItems = queryItems
        guard let endpoint = components?.url else {
            throw ProbeError.invalidBaseURL(baseURLRaw)
        }
        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": "Reply with one short word: pong"]],
                ],
            ],
            "generationConfig": ["maxOutputTokens": 24, "temperature": 0.0],
        ]
        let request = try makeJSONRequest(url: endpoint, body: payload, headers: [:])
        let data = try await performRequest(request)
        let object = try parseProbeJSONObject(data)
        let text = extractGeminiText(from: object)
        return text.isEmpty ? "Connected (empty response)" : text
    }

    private static func runOpenAIResponsesProbe(baseURL: URL, apiKey: String, model: String) async throws -> String {
        let endpoint = appendingPath("responses", to: baseURL)
        let payload: [String: Any] = [
            "model": model,
            "stream": false,
            "max_output_tokens": 24,
            "input": "Reply with one short word: pong",
        ]
        let request = try makeJSONRequest(
            url: endpoint,
            body: payload,
            headers: ["Authorization": "Bearer \(apiKey)"]
        )
        let data = try await performRequest(request)
        let object = try parseProbeJSONObject(data)
        if let output = object["output_text"] as? String,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let text = extractOpenAIResponsesText(from: object)
        return text.isEmpty ? "Connected (responses endpoint returned empty)" : text
    }

    private static func receiveWebSocketMessage(
        from socket: URLSessionWebSocketTask,
        timeoutSeconds: TimeInterval
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask {
                try await socket.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw ProbeError.invalidPayload("WebSocket probe timed out.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw ProbeError.invalidPayload("WebSocket probe failed to receive messages.")
            }
            return first
        }
    }

    private static func decodeWebSocketJSON(message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        let data: Data
        switch message {
        case .string(let text):
            guard let encoded = text.data(using: .utf8) else { return nil }
            data = encoded
        case .data(let binary):
            data = binary
        @unknown default:
            return nil
        }
        return try? parseProbeJSONObject(data)
    }

    private static func deepgramBatchConfig(from queryConfig: DeepgramQueryConfig) -> DeepgramQueryConfig {
        DeepgramQueryConfig(
            modelName: queryConfig.modelName,
            language: queryConfig.language,
            endpointingMS: nil,
            interimResults: false,
            smartFormat: queryConfig.smartFormat,
            punctuate: queryConfig.punctuate,
            paragraphs: queryConfig.paragraphs,
            diarize: queryConfig.diarize,
            terminologyRawValue: queryConfig.terminologyRawValue,
            mode: .batch
        )
    }

    private static func previewText(_ text: String, maxLength: Int = 60) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxLength else { return cleaned }
        let endIndex = cleaned.index(cleaned.startIndex, offsetBy: maxLength)
        return "\(cleaned[..<endIndex])..."
    }

    private static func makeSilentWAVSample(
        durationMS: Int,
        sampleRate: Int = 16_000,
        channels: Int = 1,
        bitsPerSample: Int = 16
    ) -> Data {
        let frameCount = max(1, durationMS * sampleRate / 1_000)
        let bytesPerSample = bitsPerSample / 8
        let dataSize = frameCount * channels * bytesPerSample
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample

        var wav = Data()
        wav.append(Data("RIFF".utf8))
        wav.append(littleEndianUInt32(UInt32(36 + dataSize)))
        wav.append(Data("WAVE".utf8))
        wav.append(Data("fmt ".utf8))
        wav.append(littleEndianUInt32(16))
        wav.append(littleEndianUInt16(1))
        wav.append(littleEndianUInt16(UInt16(channels)))
        wav.append(littleEndianUInt32(UInt32(sampleRate)))
        wav.append(littleEndianUInt32(UInt32(byteRate)))
        wav.append(littleEndianUInt16(UInt16(blockAlign)))
        wav.append(littleEndianUInt16(UInt16(bitsPerSample)))
        wav.append(Data("data".utf8))
        wav.append(littleEndianUInt32(UInt32(dataSize)))
        wav.append(Data(repeating: 0, count: dataSize))
        return wav
    }

    private static func littleEndianUInt16(_ value: UInt16) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: MemoryLayout<UInt16>.size)
    }

    private static func littleEndianUInt32(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: MemoryLayout<UInt32>.size)
    }

    private static func normalizedBaseURL(_ rawValue: String) throws -> URL {
        let cleaned = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if cleaned.isEmpty {
            candidate = ""
        } else if cleaned.contains("://") {
            candidate = cleaned
        } else {
            candidate = "https://\(cleaned)"
        }
        guard !candidate.isEmpty,
              let components = URLComponents(string: candidate),
              components.host != nil,
              let url = components.url else {
            throw ProbeError.invalidBaseURL(rawValue)
        }
        return url
    }

    private static func appendingPath(_ path: String, to baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let mergedPath: String
        if basePath.isEmpty {
            mergedPath = suffix
        } else if suffix.isEmpty {
            mergedPath = basePath
        } else {
            mergedPath = "\(basePath)/\(suffix)"
        }
        components?.path = "/\(mergedPath)"
        return components?.url ?? baseURL
    }

    private static func makeJSONRequest(
        url: URL,
        method: String = "POST",
        body: [String: Any],
        headers: [String: String],
        timeout: TimeInterval = 30
    ) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private static func makeRequest(
        url: URL,
        method: String = "GET",
        headers: [String: String],
        timeout: TimeInterval = 30
    ) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private static func performRequest(_ request: URLRequest) async throws -> Data {
        try await RetryExecutor.run(
            policy: probeRetryPolicy,
            shouldRetry: shouldRetry(error:)
        ) {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProbeError.invalidHTTPResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw ProbeError.httpStatus(
                    httpResponse.statusCode,
                    String(data: data, encoding: .utf8) ?? ""
                )
            }
            return data
        }
    }

    private static func shouldRetry(error: Error) -> Bool {
        if let probeError = error as? ProbeError {
            switch probeError {
            case .httpStatus(let statusCode, _):
                return statusCode == 429 || (500...599).contains(statusCode)
            case .invalidHTTPResponse:
                return true
            case .invalidBaseURL, .missingAPIKey, .invalidPayload:
                return false
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }

        return false
    }

    private static func parseProbeJSONObject(_ data: Data) throws -> [String: Any] {
        try parseJSONObjectPayload(data) { _ in
            ProbeError.invalidPayload("Response is not a valid JSON object.")
        }
    }

    private static func uniqueModelIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        output.reserveCapacity(ids.count)
        for raw in ids {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            output.append(trimmed)
        }
        return output
    }

}
