import Foundation

enum ProviderEntryType: String, Codable, CaseIterable {
    case builtIn
    case custom
}

enum ProviderAuthMode: String, Codable, CaseIterable, Identifiable {
    case none
    case bearer
    case headers
    case vendorSpecific

    var id: String { rawValue }
}

enum ProviderTransportProtocol: String, Codable, CaseIterable, Identifiable {
    case http
    case websocket

    var id: String { rawValue }
}

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case openAICompatible = "openai_compatible"
    case genericHTTP = "generic_http"

    var id: String { rawValue }
}

struct ProviderAdvancedConfig: Codable, Equatable {
    var timeoutSec: Double
    var maxRetries: Int
    var maxInFlight: Int
    var streamingEnabled: Bool

    static let asrDefault = ProviderAdvancedConfig(
        timeoutSec: 300,
        maxRetries: 3,
        maxInFlight: 1,
        streamingEnabled: false
    )

    static let llmDefault = ProviderAdvancedConfig(
        timeoutSec: 600,
        maxRetries: 3,
        maxInFlight: 1,
        streamingEnabled: true
    )
}

struct ProviderHeader: Codable, Equatable, Identifiable {
    var id: String
    var key: String
    var value: String

    init(id: String = UUID().uuidString, key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }
}

struct ASRProviderRequestConfig: Codable, Equatable {
    var path: String
    var method: String
    var contentType: String
    var extraParamsJSON: String

    static let openAIDefault = ASRProviderRequestConfig(
        path: "/v1/audio/transcriptions",
        method: "POST",
        contentType: "multipart",
        extraParamsJSON: "{}"
    )
}

struct LLMProviderRequestConfig: Codable, Equatable {
    var apiStyle: String
    var path: String
    var extraParamsJSON: String

    static let openAIDefault = LLMProviderRequestConfig(
        apiStyle: "openai_compatible",
        path: "/v1/chat/completions",
        extraParamsJSON: "{}"
    )
}

struct ASRProviderProfile: Codable, Equatable, Identifiable {
    var id: String
    var type: ProviderEntryType
    var displayName: String
    var kind: ProviderKind? = nil
    var transport: ProviderTransportProtocol
    var engine: ASREngineOption
    var baseURL: String
    var models: [String]
    var defaultModel: String
    var authMode: ProviderAuthMode
    var apiKeyRef: String
    var headers: [ProviderHeader]
    var request: ASRProviderRequestConfig
    var advanced: ProviderAdvancedConfig? = nil
}

struct LLMProviderProfile: Codable, Equatable, Identifiable {
    var id: String
    var type: ProviderEntryType
    var displayName: String
    var kind: ProviderKind? = nil
    var engine: LLMEngineOption
    var baseURL: String
    var models: [String]
    var defaultModel: String
    var authMode: ProviderAuthMode
    var apiKeyRef: String
    var headers: [ProviderHeader]
    var request: LLMProviderRequestConfig
    var advanced: ProviderAdvancedConfig? = nil
}

protocol CustomProviderEntry {
    var id: String { get set }
    var type: ProviderEntryType { get set }
    var displayName: String { get set }
    var baseURL: String { get set }
    var models: [String] { get set }
    var defaultModel: String { get set }
    var apiKeyRef: String { get set }
    var headers: [ProviderHeader] { get set }

    mutating func normalizeEngineForCustomProvider()
}

extension ASRProviderProfile: CustomProviderEntry {
    mutating func normalizeEngineForCustomProvider() {
        if engine == .localMLX || engine == .localHTTPOpenAIAudio {
            engine = .customOpenAICompatible
        }
    }
}

extension LLMProviderProfile: CustomProviderEntry {
    mutating func normalizeEngineForCustomProvider() {
        if engine == .localMLX {
            engine = .customOpenAICompatible
        }
    }
}

extension ASRProviderProfile {
    var resolvedKind: ProviderKind {
        kind ?? .openAICompatible
    }

    var resolvedAdvanced: ProviderAdvancedConfig {
        var advanced = advanced ?? .asrDefault
        advanced.timeoutSec = max(15, min(1_800, advanced.timeoutSec))
        advanced.maxRetries = max(0, min(8, advanced.maxRetries))
        advanced.maxInFlight = max(1, min(8, advanced.maxInFlight))
        return advanced
    }
}

extension LLMProviderProfile {
    var resolvedKind: ProviderKind {
        kind ?? .openAICompatible
    }

    var resolvedAdvanced: ProviderAdvancedConfig {
        var advanced = advanced ?? .llmDefault
        advanced.timeoutSec = max(15, min(3_600, advanced.timeoutSec))
        advanced.maxRetries = max(0, min(8, advanced.maxRetries))
        advanced.maxInFlight = max(1, min(8, advanced.maxInFlight))
        return advanced
    }
}
