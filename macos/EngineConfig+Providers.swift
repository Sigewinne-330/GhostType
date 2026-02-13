import Foundation

extension EngineConfig {
var availableASRProviders: [ASRProviderProfile] {
    EngineProviderDefaults.ASR.providers + customASRProviders
}

var availableLLMProviders: [LLMProviderProfile] {
    EngineProviderDefaults.LLM.providers + customLLMProviders
}

var selectedASRProvider: ASRProviderProfile? {
    asrProvider(by: selectedASRProviderID)
}

var selectedLLMProvider: LLMProviderProfile? {
    llmProvider(by: selectedLLMProviderID)
}

func asrProvider(by id: String) -> ASRProviderProfile? {
    availableASRProviders.first(where: { $0.id == id })
}

func llmProvider(by id: String) -> LLMProviderProfile? {
    availableLLMProviders.first(where: { $0.id == id })
}

func normalizedASRProviderID(_ rawID: String?, fallbackID: String? = nil) -> String {
    let fallback = fallbackID ?? EngineProviderDefaults.ASR.defaultProviderID(for: asrEngine)
    let trimmed = (rawID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return fallback }
    return asrProvider(by: trimmed) == nil ? fallback : trimmed
}

func normalizedLLMProviderID(_ rawID: String?, fallbackID: String? = nil) -> String {
    let fallback = fallbackID ?? EngineProviderDefaults.LLM.defaultProviderID(for: llmEngine)
    let trimmed = (rawID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return fallback }
    return llmProvider(by: trimmed) == nil ? fallback : trimmed
}

func applyASRProviderSelection(id: String) {
    let normalizedID = normalizedASRProviderID(id)
    guard let provider = asrProvider(by: normalizedID) else { return }
    selectedASRProviderID = normalizedID
    asrEngine = provider.engine
    cloudASRBaseURL = provider.baseURL
    cloudASRModelCatalog = provider.models.joined(separator: ", ")
    cloudASRModelName = provider.defaultModel
    cloudASRRequestPath = provider.request.path
    cloudASRAuthMode = provider.authMode
    cloudASRApiKeyRef = provider.apiKeyRef
    cloudASRHeadersJSON = Self.headersJSONString(provider.headers)
    cloudASRProviderKind = provider.resolvedKind
    let advanced = provider.resolvedAdvanced
    cloudASRTimeoutSec = advanced.timeoutSec
    cloudASRMaxRetries = advanced.maxRetries
    cloudASRMaxInFlight = advanced.maxInFlight
    cloudASRStreamingEnabled = advanced.streamingEnabled
    if asrEngine != .deepgram {
        cloudASRLanguage = "auto"
    }
}

func applyLLMProviderSelection(id: String) {
    let normalizedID = normalizedLLMProviderID(id)
    guard let provider = llmProvider(by: normalizedID) else { return }
    selectedLLMProviderID = normalizedID
    llmEngine = provider.engine
    cloudLLMBaseURL = provider.baseURL
    cloudLLMModelCatalog = provider.models.joined(separator: ", ")
    cloudLLMModelName = provider.defaultModel
    cloudLLMRequestPath = provider.request.path
    cloudLLMAuthMode = provider.authMode
    cloudLLMApiKeyRef = provider.apiKeyRef
    cloudLLMHeadersJSON = Self.headersJSONString(provider.headers)
    cloudLLMProviderKind = provider.resolvedKind
    let advanced = provider.resolvedAdvanced
    cloudLLMTimeoutSec = advanced.timeoutSec
    cloudLLMMaxRetries = advanced.maxRetries
    cloudLLMMaxInFlight = advanced.maxInFlight
    cloudLLMStreamingEnabled = advanced.streamingEnabled
}

@discardableResult
func saveCurrentASRAsCustomProvider(named name: String) -> Bool {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return false }
    let models = Self.parseModelList(cloudASRModelCatalog, fallback: [cloudASRModelName])
    let trimmedBaseURL = cloudASRBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let provider = ASRProviderProfile(
        id: "custom.asr.\(UUID().uuidString)",
        type: .custom,
        displayName: trimmedName,
        kind: cloudASRProviderKind,
        transport: trimmedBaseURL.lowercased().hasPrefix("ws") ? .websocket : .http,
        engine: .customOpenAICompatible,
        baseURL: trimmedBaseURL,
        models: models,
        defaultModel: cloudASRModelName.trimmingCharacters(in: .whitespacesAndNewlines),
        authMode: cloudASRAuthMode,
        apiKeyRef: cloudASRApiKeyRef.trimmingCharacters(in: .whitespacesAndNewlines),
        headers: Self.parseHeaders(from: cloudASRHeadersJSON),
        request: ASRProviderRequestConfig(
            path: cloudASRRequestPath.trimmingCharacters(in: .whitespacesAndNewlines),
            method: "POST",
            contentType: "multipart",
            extraParamsJSON: "{}"
        ),
        advanced: ProviderAdvancedConfig(
            timeoutSec: cloudASRTimeoutSec,
            maxRetries: cloudASRMaxRetries,
            maxInFlight: cloudASRMaxInFlight,
            streamingEnabled: cloudASRStreamingEnabled
        )
    )
    customASRProviders.append(provider)
    applyASRProviderSelection(id: provider.id)
    return true
}

@discardableResult
func saveCurrentLLMAsCustomProvider(named name: String) -> Bool {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return false }
    let models = Self.parseModelList(cloudLLMModelCatalog, fallback: [cloudLLMModelName])
    let provider = LLMProviderProfile(
        id: "custom.llm.\(UUID().uuidString)",
        type: .custom,
        displayName: trimmedName,
        kind: cloudLLMProviderKind,
        engine: .customOpenAICompatible,
        baseURL: cloudLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
        models: models,
        defaultModel: cloudLLMModelName.trimmingCharacters(in: .whitespacesAndNewlines),
        authMode: cloudLLMAuthMode,
        apiKeyRef: cloudLLMApiKeyRef.trimmingCharacters(in: .whitespacesAndNewlines),
        headers: Self.parseHeaders(from: cloudLLMHeadersJSON),
        request: LLMProviderRequestConfig(
            apiStyle: "openai_compatible",
            path: cloudLLMRequestPath.trimmingCharacters(in: .whitespacesAndNewlines),
            extraParamsJSON: "{}"
        ),
        advanced: ProviderAdvancedConfig(
            timeoutSec: cloudLLMTimeoutSec,
            maxRetries: cloudLLMMaxRetries,
            maxInFlight: cloudLLMMaxInFlight,
            streamingEnabled: cloudLLMStreamingEnabled
        )
    )
    customLLMProviders.append(provider)
    applyLLMProviderSelection(id: provider.id)
    return true
}

@discardableResult
func updateCurrentCustomASRProvider(named name: String? = nil) -> Bool {
    guard let index = customASRProviders.firstIndex(where: { $0.id == selectedASRProviderID }) else {
        return false
    }
    let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedName.isEmpty {
        customASRProviders[index].displayName = trimmedName
    }
    let trimmedBaseURL = cloudASRBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    customASRProviders[index].baseURL = trimmedBaseURL
    customASRProviders[index].transport = trimmedBaseURL.lowercased().hasPrefix("ws") ? .websocket : .http
    customASRProviders[index].models = Self.parseModelList(cloudASRModelCatalog, fallback: [cloudASRModelName])
    customASRProviders[index].defaultModel = cloudASRModelName.trimmingCharacters(in: .whitespacesAndNewlines)
    customASRProviders[index].authMode = cloudASRAuthMode
    customASRProviders[index].apiKeyRef = cloudASRApiKeyRef.trimmingCharacters(in: .whitespacesAndNewlines)
    customASRProviders[index].headers = Self.parseHeaders(from: cloudASRHeadersJSON)
    customASRProviders[index].request.path = cloudASRRequestPath.trimmingCharacters(in: .whitespacesAndNewlines)
    customASRProviders[index].kind = cloudASRProviderKind
    customASRProviders[index].advanced = ProviderAdvancedConfig(
        timeoutSec: cloudASRTimeoutSec,
        maxRetries: cloudASRMaxRetries,
        maxInFlight: cloudASRMaxInFlight,
        streamingEnabled: cloudASRStreamingEnabled
    )
    return true
}

@discardableResult
func updateCurrentCustomLLMProvider(named name: String? = nil) -> Bool {
    guard let index = customLLMProviders.firstIndex(where: { $0.id == selectedLLMProviderID }) else {
        return false
    }
    let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedName.isEmpty {
        customLLMProviders[index].displayName = trimmedName
    }
    customLLMProviders[index].baseURL = cloudLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    customLLMProviders[index].models = Self.parseModelList(cloudLLMModelCatalog, fallback: [cloudLLMModelName])
    customLLMProviders[index].defaultModel = cloudLLMModelName.trimmingCharacters(in: .whitespacesAndNewlines)
    customLLMProviders[index].authMode = cloudLLMAuthMode
    customLLMProviders[index].apiKeyRef = cloudLLMApiKeyRef.trimmingCharacters(in: .whitespacesAndNewlines)
    customLLMProviders[index].headers = Self.parseHeaders(from: cloudLLMHeadersJSON)
    customLLMProviders[index].request.path = cloudLLMRequestPath.trimmingCharacters(in: .whitespacesAndNewlines)
    customLLMProviders[index].kind = cloudLLMProviderKind
    customLLMProviders[index].advanced = ProviderAdvancedConfig(
        timeoutSec: cloudLLMTimeoutSec,
        maxRetries: cloudLLMMaxRetries,
        maxInFlight: cloudLLMMaxInFlight,
        streamingEnabled: cloudLLMStreamingEnabled
    )
    return true
}

@discardableResult
func deleteCurrentCustomASRProvider() -> Bool {
    guard let index = customASRProviders.firstIndex(where: { $0.id == selectedASRProviderID }) else {
        return false
    }
    customASRProviders.remove(at: index)
    applyASRProviderSelection(id: EngineProviderDefaults.ASR.defaultProviderID(for: asrEngine))
    return true
}

@discardableResult
func deleteCurrentCustomLLMProvider() -> Bool {
    guard let index = customLLMProviders.firstIndex(where: { $0.id == selectedLLMProviderID }) else {
        return false
    }
    customLLMProviders.remove(at: index)
    applyLLMProviderSelection(id: EngineProviderDefaults.LLM.defaultProviderID(for: llmEngine))
    return true
}

func notifyEngineConfigChanged() {
    // `EngineConfig` changes are already published via `@Published`.
    // Keep this hook for call-site compatibility while migrating away from NotificationCenter.
}

func persistProviderRegistry() {
    providerRegistryStore.save(
        customASRProviders: customASRProviders,
        customLLMProviders: customLLMProviders
    )
}

private static func normalizedProviders<T: CustomProviderEntry>(
    _ providers: [T],
    idPrefix: String,
    defaultDisplayNamePrefix: String,
    defaultModel: String,
    specializedNormalizer: (inout T) -> Void
) -> [T] {
    var seen = Set<String>()
    var normalized: [T] = []
    normalized.reserveCapacity(providers.count)

    for (index, item) in providers.enumerated() {
        var provider = item
        let trimmedID = provider.id.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.id = trimmedID.isEmpty ? "\(idPrefix).\(UUID().uuidString)" : trimmedID
        guard seen.insert(provider.id).inserted else { continue }

        provider.type = .custom
        provider.normalizeEngineForCustomProvider()

        let trimmedName = provider.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.displayName = trimmedName.isEmpty ? "\(defaultDisplayNamePrefix) \(index + 1)" : trimmedName
        provider.baseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        provider.models = parseModelList(
            provider.models.joined(separator: ","),
            fallback: [provider.defaultModel, defaultModel]
        )
        let trimmedDefaultModel = provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.defaultModel = trimmedDefaultModel.isEmpty
            ? (provider.models.first ?? defaultModel)
            : trimmedDefaultModel
        if !provider.models.contains(where: { $0.caseInsensitiveCompare(provider.defaultModel) == .orderedSame }) {
            provider.models.insert(provider.defaultModel, at: 0)
        }

        provider.apiKeyRef = provider.apiKeyRef.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.headers = provider.headers.filter {
            !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        specializedNormalizer(&provider)
        normalized.append(provider)
    }
    return normalized
}

static func normalizedCustomASRProviders(_ providers: [ASRProviderProfile]) -> [ASRProviderProfile] {
    normalizedProviders(
        providers,
        idPrefix: "custom.asr",
        defaultDisplayNamePrefix: "Custom ASR",
        defaultModel: ASREngineOption.customOpenAICompatible.defaultModelName
    ) { provider in
        provider.transport = provider.baseURL.lowercased().hasPrefix("ws")
            ? .websocket
            : .http
        if provider.kind == nil {
            provider.kind = .openAICompatible
        }
        if provider.request.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            provider.request.path = ASRProviderRequestConfig.openAIDefault.path
        }
        if provider.request.method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            provider.request.method = ASRProviderRequestConfig.openAIDefault.method
        }
        if provider.request.contentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            provider.request.contentType = ASRProviderRequestConfig.openAIDefault.contentType
        }
        if provider.request.extraParamsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            provider.request.extraParamsJSON = "{}"
        }
        if provider.advanced == nil {
            provider.advanced = .asrDefault
        } else {
            provider.advanced = provider.resolvedAdvanced
        }
    }
}

static func normalizedCustomLLMProviders(_ providers: [LLMProviderProfile]) -> [LLMProviderProfile] {
    normalizedProviders(
        providers,
        idPrefix: "custom.llm",
        defaultDisplayNamePrefix: "Custom LLM",
        defaultModel: LLMEngineOption.customOpenAICompatible.defaultModelName
    ) { provider in
        if provider.kind == nil {
            provider.kind = .openAICompatible
        }
        if provider.request.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            provider.request.path = LLMProviderRequestConfig.openAIDefault.path
        }
        if provider.request.apiStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            provider.request.apiStyle = LLMProviderRequestConfig.openAIDefault.apiStyle
        }
        if provider.request.extraParamsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            provider.request.extraParamsJSON = "{}"
        }
        if provider.advanced == nil {
            provider.advanced = .llmDefault
        } else {
            provider.advanced = provider.resolvedAdvanced
        }
    }
}

private static func parseModelList(_ raw: String, fallback: [String]) -> [String] {
    let primary = raw
        .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let fallbackNormalized = fallback
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let source = primary.isEmpty ? fallbackNormalized : primary
    var seen = Set<String>()
    var output: [String] = []
    output.reserveCapacity(source.count)
    for model in source {
        let key = model.lowercased()
        guard seen.insert(key).inserted else { continue }
        output.append(model)
    }
    return output
}

private static func parseHeaders(from rawJSON: String) -> [ProviderHeader] {
    let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    guard let data = trimmed.data(using: .utf8) else { return [] }

    do {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        if let dictionary = object as? [String: String] {
            return dictionary
                .sorted(by: { $0.key.lowercased() < $1.key.lowercased() })
                .map { ProviderHeader(key: $0.key, value: $0.value) }
        }

        if let array = object as? [[String: Any]] {
            let parsed = array.compactMap { item -> ProviderHeader? in
                guard let key = (item["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !key.isEmpty else {
                    return nil
                }
                let value = (item["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return ProviderHeader(key: key, value: value)
            }
            if !parsed.isEmpty { return parsed }
        }
    } catch {
        AppLogger.shared.log(
            "Failed to parse provider headers JSON object: \(error.localizedDescription)",
            type: .warning
        )
    }

    do {
        let parsed = try JSONDecoder().decode([ProviderHeader].self, from: data)
        let normalized = parsed.filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !normalized.isEmpty {
            return normalized
        }
    } catch {
        AppLogger.shared.log(
            "Failed to decode provider headers as array: \(error.localizedDescription)",
            type: .warning
        )
    }

    AppLogger.shared.log(
        "Failed to parse provider headers JSON. Falling back to empty headers.",
        type: .warning
    )
    return []
}

private static func headersJSONString(_ headers: [ProviderHeader]) -> String {
    var object: [String: String] = [:]
    for header in headers {
        let key = header.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { continue }
        object[key] = header.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !object.isEmpty else { return "{}" }
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let text = String(data: data, encoding: .utf8) else {
            AppLogger.shared.log(
                "Failed to serialize provider headers to UTF-8 text. Falling back to empty object.",
                type: .warning
            )
            return "{}"
        }
        return text
    } catch {
        AppLogger.shared.log(
            "Failed to serialize provider headers to JSON: \(error.localizedDescription). Falling back to empty object.",
            type: .warning
        )
        return "{}"
    }
}
}
