import Foundation

struct InferenceRequest {
    let state: AppState
    let mode: WorkflowMode
    let audioURL: URL
    let selectedText: String
    let dictationContext: DictationContextSelection?
    let audioProcessingProfile: AudioProcessingProfile

    init(
        state: AppState,
        mode: WorkflowMode,
        audioURL: URL,
        selectedText: String,
        dictationContext: DictationContextSelection?,
        audioProcessingProfile: AudioProcessingProfile = .standard
    ) {
        self.state = state
        self.mode = mode
        self.audioURL = audioURL
        self.selectedText = selectedText
        self.dictationContext = dictationContext
        self.audioProcessingProfile = audioProcessingProfile
    }
}

enum AudioProcessingProfile {
    case standard
    case fast
    case quality
}

enum ProviderEngineType: String, Codable {
    case asr = "ASR"
    case llm = "LLM"
}

enum ProviderMode: String, Codable {
    case native
    case openAICompatible = "openai_compatible"
}

enum ProviderAuthStrategy: String, Codable {
    case bearer
    case token
    case apiKeyHeader = "api_key_header"
    case anthropicHeader = "anthropic_header"
    case geminiHeader = "gemini_header"
    case awsSigV4 = "aws_sigv4"
    case oauth2
    case none
}

struct ProviderAuthConfig: Codable {
    let strategy: ProviderAuthStrategy
    let keychainID: String?
    let headerName: String?
}

struct ProviderNetworkConfig: Codable {
    let timeoutMS: Int
    let proxy: String?
    let tlsVerify: Bool

    enum CodingKeys: String, CodingKey {
        case timeoutMS = "timeout_ms"
        case proxy
        case tlsVerify = "tls_verify"
    }
}

struct ProviderRetryConfig: Codable {
    let maxRetries: Int
    let backoffMS: [Int]
    let retryOnHTTP: [Int]

    enum CodingKeys: String, CodingKey {
        case maxRetries = "max_retries"
        case backoffMS = "backoff_ms"
        case retryOnHTTP = "retry_on_http"
    }
}

struct ProviderCapability: Codable {
    let streaming: Bool
    let tools: Bool
    let vision: Bool
    let timestamps: Bool
}

struct ProviderConfig: Codable {
    let engineType: ProviderEngineType
    let provider: String
    let providerMode: ProviderMode
    let baseURL: String
    let model: String
    let auth: ProviderAuthConfig
    let network: ProviderNetworkConfig
    let retry: ProviderRetryConfig
    let headers: [String: String]
    let query: [String: String]
    let capabilities: ProviderCapability

    enum CodingKeys: String, CodingKey {
        case engineType = "engine_type"
        case provider
        case providerMode = "provider_mode"
        case baseURL = "base_url"
        case model
        case auth
        case network
        case retry
        case headers
        case query
        case capabilities
    }
}

struct UnifiedChatMessage: Codable {
    let role: String
    let content: String
}

struct UnifiedToolDefinition: Codable {
    let name: String
    let description: String
    let jsonSchema: JSONValue

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case jsonSchema = "json_schema"
    }
}

struct UnifiedResponseFormat: Codable {
    let type: String
    let jsonSchema: JSONValue?

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

struct UnifiedLLMParams: Codable {
    let stream: Bool
    let maxTokens: Int
    let temperature: Double
    let topP: Double
    let stop: [String]

    enum CodingKeys: String, CodingKey {
        case stream
        case maxTokens = "max_tokens"
        case temperature
        case topP = "top_p"
        case stop
    }
}

struct UnifiedRequestMetadata: Codable {
    let traceID: String
    let privacyMode: Bool

    enum CodingKeys: String, CodingKey {
        case traceID = "trace_id"
        case privacyMode = "privacy_mode"
    }
}

struct UnifiedLLMRequest: Codable {
    let requestID: String
    let mode: String
    let systemPrompt: String
    let messages: [UnifiedChatMessage]
    let params: UnifiedLLMParams
    let tools: [UnifiedToolDefinition]
    let toolChoice: String
    let responseFormat: UnifiedResponseFormat
    let metadata: UnifiedRequestMetadata

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case mode
        case systemPrompt = "system_prompt"
        case messages
        case params
        case tools
        case toolChoice = "tool_choice"
        case responseFormat = "response_format"
        case metadata
    }
}

struct UnifiedToolCall: Codable {
    let id: String
    let name: String
    let arguments: JSONValue
}

struct UnifiedUsage: Codable {
    let inputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

struct UnifiedLatency: Codable {
    let firstToken: Double?
    let total: Double?

    enum CodingKeys: String, CodingKey {
        case firstToken = "first_token"
        case total
    }
}

struct UnifiedLLMResponse: Codable {
    let requestID: String
    let provider: String
    let model: String
    let outputText: String
    let toolCalls: [UnifiedToolCall]
    let usage: UnifiedUsage?
    let latencyMS: UnifiedLatency?
    let finishReason: String?
    let rawProviderResponse: JSONValue?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case provider
        case model
        case outputText = "output_text"
        case toolCalls = "tool_calls"
        case usage
        case latencyMS = "latency_ms"
        case finishReason = "finish_reason"
        case rawProviderResponse = "raw_provider_response"
    }
}

struct UnifiedASRTimestamps: Codable {
    let enabled: Bool
    let granularity: String
}

struct UnifiedAudioInput: Codable {
    let path: String
    let mimeType: String
    let durationMS: Int?

    enum CodingKeys: String, CodingKey {
        case path
        case mimeType = "mime_type"
        case durationMS = "duration_ms"
    }
}

struct UnifiedASRRequest: Codable {
    let requestID: String
    let audio: UnifiedAudioInput
    let language: String
    let timestamps: UnifiedASRTimestamps
    let diarization: Bool

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case audio
        case language
        case timestamps
        case diarization
    }
}

struct UnifiedASRSegment: Codable {
    let startMS: Int?
    let endMS: Int?
    let text: String
    let confidence: Double?

    enum CodingKeys: String, CodingKey {
        case startMS = "start_ms"
        case endMS = "end_ms"
        case text
        case confidence
    }
}

struct UnifiedASRResponse: Codable {
    let requestID: String
    let provider: String
    let model: String
    let text: String
    let segments: [UnifiedASRSegment]
    let languageDetected: String?
    let latencyMS: Double?
    let rawProviderResponse: JSONValue?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case provider
        case model
        case text
        case segments
        case languageDetected = "language_detected"
        case latencyMS = "latency_ms"
        case rawProviderResponse = "raw_provider_response"
    }
}

struct UnifiedProviderError: Codable, LocalizedError {
    let provider: String
    let httpStatus: Int?
    let errorCode: String?
    let message: String
    let requestID: String?
    let retryable: Bool
    let suggestion: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case httpStatus = "http_status"
        case errorCode = "error_code"
        case message
        case requestID = "request_id"
        case retryable
        case suggestion
    }

    var errorDescription: String? {
        if let suggestion, !suggestion.isEmpty {
            return "\(message) (\(suggestion))"
        }
        return message
    }
}

enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

@MainActor
protocol InferenceProvider: AnyObject {
    var providerID: String { get }
    func run(
        request: InferenceRequest,
        onToken: @escaping (String) -> Void,
        completion: @escaping (Result<StreamInferenceMeta, Error>) -> Void
    )
    func terminateIfRunning()
}

enum InferenceRoutingError: LocalizedError {
    case missingBaseURL
    case missingModelName
    case missingAPIKey(String)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "Cloud provider Base URL is required."
        case .missingModelName:
            return "Cloud LLM model name is required."
        case .missingAPIKey(let provider):
            return "Missing API key for \(provider). Please set it in Engines & Models."
        }
    }
}

enum InferenceProviderKind {
    case local
    case cloud
    case hybrid
}

struct InferenceProviderFactory {
    @MainActor
    static func providerKind(for state: AppState) throws -> InferenceProviderKind {
        let asrIsLocal = (state.asrEngine == .localMLX)
        let llmIsLocal = (state.llmEngine == .localMLX)
        if asrIsLocal && llmIsLocal {
            return .local
        }
        if !asrIsLocal && !llmIsLocal {
            return .cloud
        }
        return .hybrid
    }

    @MainActor
    static func makeProvider(
        for state: AppState,
        localProvider: InferenceProvider,
        cloudProvider: InferenceProvider
    ) throws -> InferenceProvider {
        switch try providerKind(for: state) {
        case .local:
            return localProvider
        case .cloud:
            return cloudProvider
        case .hybrid:
            return cloudProvider
        }
    }
}
