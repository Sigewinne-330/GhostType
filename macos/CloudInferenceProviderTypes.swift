import Foundation

enum CloudInferenceError: LocalizedError {
    case missingTextFromTranscription
    case invalidJSONResponse(String)
    case invalidURL(String)
    case invalidAudioInput(String)
    case unsupportedASREngine
    case unsupportedLLMEngine
    case emptyLLMResponse
    case providerFailure(UnifiedProviderError)
    case openAICompatiblePathDetectionFailed

    var errorDescription: String? {
        switch self {
        case .missingTextFromTranscription:
            return "Cloud ASR response does not include transcribed text."
        case .invalidJSONResponse(let body):
            return "Invalid cloud response: \(body)"
        case .invalidURL(let value):
            return "Invalid URL: \(value)"
        case .invalidAudioInput(let reason):
            return "Invalid audio input: \(reason)"
        case .unsupportedASREngine:
            return "Selected ASR engine is not supported in cloud mode."
        case .unsupportedLLMEngine:
            return "Selected LLM engine is not supported in cloud mode."
        case .emptyLLMResponse:
            return "Cloud LLM returned empty output."
        case .providerFailure(let providerError):
            return providerError.localizedDescription
        case .openAICompatiblePathDetectionFailed:
            return "OpenAI-compatible endpoint detection failed. Ensure /v1/chat/completions or /v1/responses is available."
        }
    }
}

enum OpenAICompatibleEndpointKind {
    case chatCompletions
    case responses
}

enum LLMRequestKind {
    case openAIChat
    case openAIResponses
    case azureOpenAIChat
    case anthropic
    case gemini
}

enum LLMTokenParserKind {
    case openAIChat
    case openAIResponses
    case anthropic
    case gemini
}

enum ASRRequestKind {
    case openAIMultipart
    case deepgramBinary
    case deepgramStreaming
    case assemblyAI
    case geminiMultimodal
}

enum DeepgramTranscriptionMode: String, CaseIterable, Identifiable {
    case batch = "Batch (HTTP)"
    case streaming = "Streaming (WebSocket)"

    var id: String { rawValue }
}

enum DeepgramRegionOption: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case eu = "EU"

    var id: String { rawValue }

    var host: String {
        switch self {
        case .standard:
            return "api.deepgram.com"
        case .eu:
            return "api.eu.deepgram.com"
        }
    }

    var defaultHTTPSBaseURL: String { "https://\(host)" }
    var defaultWSSBaseURL: String { "wss://\(host)" }
}

enum DeepgramLanguageStrategy: String, CaseIterable, Identifiable {
    case chineseSimplified = "zh-CN"
    case englishUS = "en-US"
    case multi = "multi"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chineseSimplified:
            return "Single Language: Chinese (Simplified)"
        case .englishUS:
            return "Single Language: English (US)"
        case .multi:
            return "Multi Language: Deepgram multi"
        }
    }
}

enum DeepgramTerminologyMode {
    case keywords
    case keyterm
}

struct DeepgramQueryConfig {
    let modelName: String
    let language: String
    let endpointingMS: Int?
    let interimResults: Bool
    let smartFormat: Bool
    let punctuate: Bool
    let paragraphs: Bool
    let diarize: Bool
    let terminologyRawValue: String
    let mode: DeepgramTranscriptionMode
}

enum DeepgramConfig {
    static let defaultEndpointingMS = 500
    static let endpointPath = "v1/listen"

    static let chineseLanguageCodes: Set<String> = [
        "zh",
        "zh-cn",
        "zh-hans",
        "zh-tw",
        "zh-hant",
        "zh-hk",
    ]

    static let deepgramMultiLanguageHint = "Deepgram multi currently does not include Chinese."

    static func normalizedLanguageCode(_ rawValue: String) -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return DeepgramLanguageStrategy.chineseSimplified.rawValue
        }
        if normalized == "multi" {
            return DeepgramLanguageStrategy.multi.rawValue
        }
        if normalized == "en" || normalized == "en-us" {
            return DeepgramLanguageStrategy.englishUS.rawValue
        }
        if chineseLanguageCodes.contains(normalized) || normalized == "auto" {
            return DeepgramLanguageStrategy.chineseSimplified.rawValue
        }
        return rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func recommendedModel(for languageCode: String) -> String {
        let normalizedLanguage = normalizedLanguageCode(languageCode).lowercased()
        if chineseLanguageCodes.contains(normalizedLanguage) || normalizedLanguage == "zh-cn" {
            return "nova-2"
        }
        return "nova-3"
    }

    static func isNova3Model(_ modelName: String) -> Bool {
        modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("nova-3")
    }

    static func terminologyMode(for modelName: String) -> DeepgramTerminologyMode {
        isNova3Model(modelName) ? .keyterm : .keywords
    }

    static func parsedTerms(from rawValue: String) -> [String] {
        rawValue
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func buildQueryItems(config: DeepgramQueryConfig) -> [URLQueryItem] {
        let languageCode = normalizedLanguageCode(config.language)
        let model = config.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? recommendedModel(for: languageCode)
            : config.modelName.trimmingCharacters(in: .whitespacesAndNewlines)

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "language", value: languageCode),
            URLQueryItem(name: "smart_format", value: boolString(config.smartFormat)),
            URLQueryItem(name: "paragraphs", value: boolString(config.paragraphs)),
        ]

        if !config.smartFormat {
            queryItems.append(URLQueryItem(name: "punctuate", value: boolString(config.punctuate)))
        }

        if config.mode == .streaming,
           let endpointingMS = config.endpointingMS,
           endpointingMS > 0 {
            queryItems.append(URLQueryItem(name: "endpointing", value: String(endpointingMS)))
        }

        if config.mode == .streaming {
            queryItems.append(URLQueryItem(name: "interim_results", value: boolString(config.interimResults)))
        }

        if config.diarize {
            queryItems.append(URLQueryItem(name: "diarize", value: "true"))
        }

        let terms = parsedTerms(from: config.terminologyRawValue)
        switch terminologyMode(for: model) {
        case .keywords:
            for term in terms {
                queryItems.append(URLQueryItem(name: "keywords", value: term))
            }
        case .keyterm:
            for term in terms {
                queryItems.append(URLQueryItem(name: "keyterm", value: term))
            }
        }

        return queryItems
    }

    static func endpointURL(
        baseURLRaw: String,
        mode: DeepgramTranscriptionMode,
        fallbackRegion: DeepgramRegionOption
    ) -> URL? {
        guard let baseURL = canonicalBaseURL(baseURLRaw, mode: mode, fallbackRegion: fallbackRegion) else {
            return nil
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let lowerPath = basePath.lowercased()
        let mergedPath: String
        if lowerPath == "v1" {
            mergedPath = endpointPath
        } else if lowerPath.hasSuffix("/v1") {
            mergedPath = "\(basePath)/listen"
        } else if lowerPath == endpointPath || lowerPath.hasSuffix("/\(endpointPath)") {
            mergedPath = basePath
        } else if basePath.isEmpty {
            mergedPath = endpointPath
        } else {
            mergedPath = "\(basePath)/\(endpointPath)"
        }
        components?.path = "/\(mergedPath)"
        components?.queryItems = nil
        components?.fragment = nil
        return components?.url
    }

    private static func canonicalBaseURL(
        _ rawValue: String,
        mode: DeepgramTranscriptionMode,
        fallbackRegion: DeepgramRegionOption
    ) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = mode == .streaming ? fallbackRegion.defaultWSSBaseURL : fallbackRegion.defaultHTTPSBaseURL
        let candidateRaw: String
        if trimmed.isEmpty {
            candidateRaw = fallback
        } else if trimmed.contains("://") {
            candidateRaw = trimmed
        } else {
            let scheme = mode == .streaming ? "wss" : "https"
            candidateRaw = "\(scheme)://\(trimmed)"
        }

        guard var components = URLComponents(string: candidateRaw), components.host != nil else {
            return nil
        }
        components.scheme = mode == .streaming ? "wss" : "https"
        return components.url
    }

    private static func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
    }
}

struct LLMRuntimeConfig {
    let providerID: String
    let providerName: String
    let baseURL: URL
    let modelName: String
    let apiKey: String
    let requestPath: String
    let requestKind: LLMRequestKind
    let parserKind: LLMTokenParserKind
    let timeoutSeconds: TimeInterval
    let maxRetries: Int
    let maxInFlight: Int
    let streamingEnabled: Bool
    let extraHeaders: [String: String]
    let queryItems: [URLQueryItem]
}

struct ASRRuntimeConfig {
    let providerID: String
    let providerName: String
    let baseURL: URL
    let modelName: String
    let apiKey: String
    let requestPath: String
    let requestKind: ASRRequestKind
    let timeoutSeconds: TimeInterval
    let maxRetries: Int
    let maxInFlight: Int
    let streamingEnabled: Bool
    let extraHeaders: [String: String]
    let deepgramQueryConfig: DeepgramQueryConfig?
}

struct EngineASRLanguageOption: Identifiable {
    let code: String
    let name: String

    var id: String { code }
}

enum EngineSettingsCatalog {
    static let supportedASRLanguages: [EngineASRLanguageOption] = [
        .init(code: "auto", name: "Auto Detect"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "bg", name: "Bulgarian"),
        .init(code: "ca", name: "Catalan"),
        .init(code: "cs", name: "Czech"),
        .init(code: "da", name: "Danish"),
        .init(code: "de", name: "German"),
        .init(code: "el", name: "Greek"),
        .init(code: "en", name: "English"),
        .init(code: "es", name: "Spanish"),
        .init(code: "et", name: "Estonian"),
        .init(code: "fa", name: "Persian"),
        .init(code: "fi", name: "Finnish"),
        .init(code: "fil", name: "Filipino"),
        .init(code: "fr", name: "French"),
        .init(code: "he", name: "Hebrew"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "hr", name: "Croatian"),
        .init(code: "hu", name: "Hungarian"),
        .init(code: "id", name: "Indonesian"),
        .init(code: "it", name: "Italian"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "ko", name: "Korean"),
        .init(code: "lt", name: "Lithuanian"),
        .init(code: "lv", name: "Latvian"),
        .init(code: "ms", name: "Malay"),
        .init(code: "nl", name: "Dutch"),
        .init(code: "no", name: "Norwegian"),
        .init(code: "pl", name: "Polish"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "ro", name: "Romanian"),
        .init(code: "ru", name: "Russian"),
        .init(code: "sk", name: "Slovak"),
        .init(code: "sl", name: "Slovenian"),
        .init(code: "sv", name: "Swedish"),
        .init(code: "ta", name: "Tamil"),
        .init(code: "th", name: "Thai"),
        .init(code: "tr", name: "Turkish"),
        .init(code: "uk", name: "Ukrainian"),
        .init(code: "ur", name: "Urdu"),
        .init(code: "vi", name: "Vietnamese"),
        .init(code: "zh", name: "Chinese"),
    ]

    static let supportedASRLanguageCodes: Set<String> = Set(supportedASRLanguages.map(\.code))

    static let localLLMModelPresets: [String] = [
        "mlx-community/Qwen2.5-0.5B-Instruct",
        "mlx-community/Qwen2.5-1.5B-Instruct",
        "mlx-community/Qwen2.5-3B-Instruct",
        "mlx-community/Qwen2.5-7B-Instruct",
        "mlx-community/Qwen2.5-14B-Instruct",
        "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
        "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
        "mlx-community/Qwen2.5-3B-Instruct-4bit",
        "mlx-community/Qwen2.5-7B-Instruct-4bit",
        "mlx-community/Qwen2.5-14B-Instruct-4bit",
        "mlx-community/Qwen2.5-32B-Instruct-4bit",
        "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
        "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit",
        "mlx-community/Qwen2.5-0.5B-Instruct-8bit",
        "mlx-community/Llama-3.2-1B-Instruct-4bit",
        "mlx-community/Llama-3.2-3B-Instruct-4bit",
        "mlx-community/Llama-3.2-1B-Instruct-8bit",
        "mlx-community/Llama-3.2-3B-Instruct-8bit",
        "mlx-community/Llama-3.2-1B-Instruct-fp16",
        "mlx-community/Llama-3.2-3B-Instruct-fp16",
        "mlx-community/Llama-3.1-8B-Instruct-4bit",
        "mlx-community/Llama-3.1-8B-Instruct-8bit",
        "mlx-community/Llama-3.1-8B-Instruct-fp16",
        "mlx-community/Llama-3.1-70B-Instruct-4bit",
        "mlx-community/Llama-3.3-70B-Instruct-4bit",
        "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
        "mlx-community/Mistral-7B-Instruct-v0.3-8bit",
        "mlx-community/Mistral-7B-Instruct-v0.3-fp16",
        "mlx-community/Mixtral-8x7B-Instruct-v0.1-4bit",
        "mlx-community/Ministral-8B-Instruct-2410-4bit",
        "mlx-community/gemma-2-2b-it",
        "mlx-community/gemma-2-9b-it",
        "mlx-community/gemma-2-2b-it-4bit",
        "mlx-community/gemma-2-9b-it-4bit",
        "mlx-community/gemma-2-2b-it-8bit",
        "mlx-community/gemma-2-9b-it-8bit",
        "mlx-community/gemma-2-2b-it-fp16",
        "mlx-community/gemma-2-9b-it-fp16",
        "mlx-community/Phi-3-mini-4k-instruct-4bit",
        "mlx-community/Phi-3-medium-4k-instruct-4bit",
        "mlx-community/Phi-3.5-mini-instruct-4bit",
        "mlx-community/Phi-3.5-mini-instruct-8bit",
        "mlx-community/Phi-3.5-mini-instruct-fp16",
        "mlx-community/Qwen2.5-1.5B-Instruct-8bit",
        "mlx-community/Qwen2.5-3B-Instruct-8bit",
        "mlx-community/Qwen2.5-7B-Instruct-8bit",
        "mlx-community/Qwen2.5-14B-Instruct-8bit",
        "mlx-community/Qwen2.5-32B-Instruct-8bit",
        "mlx-community/Qwen2.5-1.5B-Instruct-fp16",
        "mlx-community/Qwen2.5-3B-Instruct-fp16",
        "mlx-community/Qwen2.5-7B-Instruct-fp16",
        "mlx-community/Qwen2.5-14B-Instruct-fp16",
        "mlx-community/Qwen2.5-Coder-7B-Instruct-fp16",
        "mlx-community/Qwen2.5-Coder-14B-Instruct-fp16",
    ]

    static let cloudASRModelPresets: [ASREngineOption: [String]] = [
        .localHTTPOpenAIAudio: ["whisper-1", "transcribe-1"],
        .openAIWhisper: ["whisper-1", "gpt-4o-mini-transcribe", "gpt-4o-transcribe"],
        .deepgram: ["nova-3", "nova-3-general", "nova-2", "nova-2-general"],
        .assemblyAI: ["best", "nano"],
        .groq: ["whisper-large-v3-turbo", "distil-whisper-large-v3-en", "whisper-large-v3"],
        .geminiMultimodal: ["gemini-2.0-flash", "gemini-2.0-flash-lite", "gemini-1.5-flash-latest"],
        .customOpenAICompatible: ["whisper-1", "transcribe-1"],
    ]

    static let cloudLLMModelPresets: [LLMEngineOption: [String]] = [
        .openAI: ["gpt-4o-mini", "gpt-4.1-mini", "gpt-4.1"],
        .openAICompatible: ["gpt-4o-mini", "deepseek-chat", "llama-3.1-70b-versatile"],
        .customOpenAICompatible: ["gpt-4o-mini"],
        .azureOpenAI: ["gpt-4o-mini", "gpt-4.1-mini", "gpt-4.1"],
        .anthropic: ["claude-3-5-haiku-latest", "claude-3-7-sonnet-latest"],
        .gemini: ["gemini-2.0-flash", "gemini-2.0-flash-lite", "gemini-1.5-flash"],
        .deepSeek: ["deepseek-chat", "deepseek-reasoner"],
        .groq: ["llama-3.1-70b-versatile", "llama-3.3-70b-versatile", "mixtral-8x7b-32768"],
    ]
}
