import Foundation

enum LocalASRProviderRuntimeKind: String, Codable {
    case pythonInproc = "python_inproc"
    case localHTTP = "local_http"
    case localBinary = "local_binary"
}

enum LocalASRWeNetModelType: String, CaseIterable, Identifiable, Codable {
    case checkpoint = "checkpoint"
    case runtimeQuantized = "runtime_quantized"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .checkpoint:
            return "Checkpoint"
        case .runtimeQuantized:
            return "Runtime Quantized"
        }
    }
}

enum LocalASRProviderOption: String, CaseIterable, Identifiable, Codable {
    case mlxWhisper = "MLX Whisper"
    case funASRParaformer = "FunASR Paraformer"
    case senseVoice = "SenseVoice"
    case weNet = "WeNet"
    case whisperKitLocalServer = "WhisperKit Local Server"
    case whisperCpp = "whisper.cpp"
    case fireRedASRExperimental = "FireRedASR (Experimental)"
    case localHTTPOpenAIAudio = "Local HTTP (OpenAI Audio API compatible)"

    var id: String { rawValue }

    var runtimeKind: LocalASRProviderRuntimeKind {
        switch self {
        case .mlxWhisper:
            return .pythonInproc
        case .whisperCpp:
            return .localBinary
        case .funASRParaformer, .senseVoice, .weNet, .whisperKitLocalServer, .fireRedASRExperimental, .localHTTPOpenAIAudio:
            return .localHTTP
        }
    }

    var supportsQuantizationMode: Bool {
        switch self {
        case .mlxWhisper, .weNet, .whisperCpp:
            return true
        case .funASRParaformer, .senseVoice, .whisperKitLocalServer, .fireRedASRExperimental, .localHTTPOpenAIAudio:
            return false
        }
    }

    var supportsStreaming: Bool {
        switch self {
        case .funASRParaformer, .senseVoice, .whisperKitLocalServer, .weNet:
            return true
        case .mlxWhisper, .whisperCpp, .fireRedASRExperimental, .localHTTPOpenAIAudio:
            return false
        }
    }

    var isExperimental: Bool {
        switch self {
        case .fireRedASRExperimental:
            return true
        default:
            return false
        }
    }

    var defaultHTTPModelName: String {
        switch self {
        case .mlxWhisper:
            return ""
        case .funASRParaformer:
            return "funasr/paraformer-zh"
        case .senseVoice:
            return "FunAudioLLM/SenseVoiceSmall"
        case .weNet:
            return "wenet/wenetspeech"
        case .whisperKitLocalServer:
            return "openai-whisper-large-v3"
        case .whisperCpp:
            return "ggml-large-v3"
        case .fireRedASRExperimental:
            return "FireRedTeam/FireRedASR-AED-L"
        case .localHTTPOpenAIAudio:
            return LocalASRModelCatalog.defaultLocalHTTPModelName
        }
    }

    var helperText: String {
        switch self {
        case .mlxWhisper:
            return "On-device MLX Whisper running in the bundled local backend."
        case .funASRParaformer:
            return "Chinese-first Paraformer route. For now, connect via a local OpenAI-compatible bridge service."
        case .senseVoice:
            return "SenseVoice ASR route. For now, connect via a local OpenAI-compatible bridge service."
        case .weNet:
            return "WeNet route with checkpoint/runtime-quantized model modes. Connect via local bridge service."
        case .whisperKitLocalServer:
            return "Use WhisperKit local server (OpenAI Audio API compatible endpoint)."
        case .whisperCpp:
            return "Use whisper.cpp local server/bridge. CLI direct mode can be added later."
        case .fireRedASRExperimental:
            return "Experimental provider. Connect through a local compatible service."
        case .localHTTPOpenAIAudio:
            return "Generic local HTTP ASR endpoint compatible with OpenAI Audio API."
        }
    }

    var asrEngine: ASREngineOption {
        switch self {
        case .mlxWhisper:
            return .localMLX
        case .funASRParaformer, .senseVoice, .weNet, .whisperKitLocalServer, .whisperCpp, .fireRedASRExperimental, .localHTTPOpenAIAudio:
            return .localHTTPOpenAIAudio
        }
    }

    static func from(asrEngine: ASREngineOption) -> LocalASRProviderOption {
        switch asrEngine {
        case .localHTTPOpenAIAudio:
            return .whisperKitLocalServer
        default:
            return .mlxWhisper
        }
    }
}

enum LocalASRModelFamily: String, Codable, CaseIterable {
    case tiny
    case base
    case small
    case medium
    case large
    case largeV2 = "large-v2"
    case largeV3 = "large-v3"

    var displayName: String {
        switch self {
        case .tiny:
            return "Tiny"
        case .base:
            return "Base"
        case .small:
            return "Small"
        case .medium:
            return "Medium"
        case .large:
            return "Large"
        case .largeV2:
            return "Large v2"
        case .largeV3:
            return "Large v3"
        }
    }

    var sortOrder: Int {
        switch self {
        case .tiny: return 0
        case .base: return 1
        case .small: return 2
        case .medium: return 3
        case .large: return 4
        case .largeV2: return 5
        case .largeV3: return 6
        }
    }
}

enum LocalASRModelVariant: String, Codable, CaseIterable {
    case multilingual
    case englishOnly = "en"

    var displayName: String {
        switch self {
        case .multilingual:
            return "Multilingual"
        case .englishOnly:
            return "English-only"
        }
    }

    var sortOrder: Int {
        switch self {
        case .multilingual: return 0
        case .englishOnly: return 1
        }
    }
}

enum LocalASRModelPrecision: String, Codable, CaseIterable {
    case `default`
    case bit8 = "8bit"
    case bit4 = "4bit"
    case bit2 = "2bit"
    case fp32

    var displayName: String {
        switch self {
        case .default:
            return "Default"
        case .bit8:
            return "8bit"
        case .bit4:
            return "4bit"
        case .bit2:
            return "2bit"
        case .fp32:
            return "fp32"
        }
    }

    var sortOrder: Int {
        switch self {
        case .default: return 0
        case .bit8: return 1
        case .bit4: return 2
        case .bit2: return 3
        case .fp32: return 4
        }
    }
}

struct LocalASRModelDescriptor: Identifiable, Codable, Hashable {
    let id: String
    let displayName: String
    let hfRepo: String
    let family: LocalASRModelFamily
    let variant: LocalASRModelVariant
    let precision: LocalASRModelPrecision
    let isAdvanced: Bool
    let estimatedDiskMB: Int?
    let estimatedRAMMB: Int?

    var variantLabel: String {
        variant.displayName
    }

    var precisionLabel: String {
        precision.displayName
    }
}

private struct HuggingFaceWhisperCollectionResponse: Decodable {
    struct Item: Decodable {
        let id: String
    }

    let items: [Item]
}

private struct LocalASRModelCatalogCachePayload: Codable {
    let updatedAt: Date
    let models: [LocalASRModelDescriptor]
}

enum LocalASRModelCatalog {
    static let defaultModelID = "mlx-community/whisper-small-mlx"
    static let defaultLocalHTTPBaseURL = "http://127.0.0.1:8000"
    static let defaultLocalHTTPModelName = ""
    static let preferredQuantizationsWhenAdvancedHidden: [LocalASRModelPrecision] = [.default, .bit8, .bit4]

    static let providerHTTPModelPresets: [LocalASRProviderOption: [String]] = [
        .whisperKitLocalServer: [
            "openai-whisper-large-v3",
            "openai-whisper-large-v2",
            "openai-whisper-medium",
            "openai-whisper-small",
        ],
        .whisperCpp: [
            "ggml-large-v3",
            "ggml-large-v2",
            "ggml-medium",
            "ggml-small",
        ],
        .funASRParaformer: [
            "funasr/paraformer-zh",
            "funasr/paraformer-zh-streaming",
            "funasr/fsmn-vad",
            "funasr/ct-punc",
        ],
        .senseVoice: [
            "FunAudioLLM/SenseVoiceSmall",
            "FunAudioLLM/SenseVoiceLarge",
        ],
        .weNet: [
            "wenet/wenetspeech",
            "wenet/aishell",
            "wenet/runtime-quantized",
        ],
        .fireRedASRExperimental: [
            "FireRedTeam/FireRedASR-AED-L",
            "FireRedTeam/FireRedASR-LLM-L",
        ],
        .localHTTPOpenAIAudio: [
            "whisper-1",
            "transcribe-1",
        ],
    ]

    private static let remoteCatalogURL = URL(string: "https://huggingface.co/api/collections/mlx-community/whisper")!
    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    // Keep advanced entries available offline; online refresh merges and de-duplicates.
    private static let builtInRepoList: [String] = [
        "mlx-community/whisper-tiny-mlx",
        "mlx-community/whisper-base-mlx",
        "mlx-community/whisper-small-mlx",
        "mlx-community/whisper-medium-mlx",
        "mlx-community/whisper-large-mlx",
        "mlx-community/whisper-large-v2-mlx",
        "mlx-community/whisper-large-v3-mlx",
        "mlx-community/whisper-tiny.en-mlx",
        "mlx-community/whisper-base.en-mlx",
        "mlx-community/whisper-small.en-mlx",
        "mlx-community/whisper-medium.en-mlx",
        "mlx-community/whisper-tiny-mlx-8bit",
        "mlx-community/whisper-base-mlx-8bit",
        "mlx-community/whisper-small-mlx-8bit",
        "mlx-community/whisper-medium-mlx-8bit",
        "mlx-community/whisper-large-mlx-8bit",
        "mlx-community/whisper-large-v2-mlx-8bit",
        "mlx-community/whisper-tiny-mlx-4bit",
        "mlx-community/whisper-base-mlx-4bit",
        "mlx-community/whisper-small-mlx-4bit",
        "mlx-community/whisper-medium-mlx-4bit",
        "mlx-community/whisper-large-mlx-4bit",
        "mlx-community/whisper-large-v2-mlx-4bit",
        "mlx-community/whisper-base-mlx-2bit",
        "mlx-community/whisper-tiny-mlx-fp32",
        "mlx-community/whisper-base-mlx-fp32",
        "mlx-community/whisper-small-mlx-fp32",
        "mlx-community/whisper-medium-mlx-fp32",
        "mlx-community/whisper-large-v2-mlx-fp32",
    ]

    static let builtInModels: [LocalASRModelDescriptor] = normalizeModels(
        builtInRepoList.compactMap(descriptor(fromHFRepo:))
    )

    static func normalizeModelID(_ rawValue: String?) -> String {
        let trimmed = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModelID : trimmed
    }

    static func mergedModels(local: [LocalASRModelDescriptor], remote: [LocalASRModelDescriptor]) -> [LocalASRModelDescriptor] {
        normalizeModels(local + remote)
    }

    static func descriptor(for id: String?, in models: [LocalASRModelDescriptor]) -> LocalASRModelDescriptor? {
        let normalizedID = normalizeModelID(id)
        return models.first(where: { $0.id.caseInsensitiveCompare(normalizedID) == .orderedSame })
    }

    static func fallbackDescriptor(in models: [LocalASRModelDescriptor]) -> LocalASRModelDescriptor {
        if let descriptor = descriptor(for: defaultModelID, in: models) {
            return descriptor
        }
        if let first = models.first {
            return first
        }
        return builtInModels.first ?? LocalASRModelDescriptor(
            id: defaultModelID,
            displayName: "Whisper Small · Multilingual · Default",
            hfRepo: defaultModelID,
            family: .small,
            variant: .multilingual,
            precision: .default,
            isAdvanced: false,
            estimatedDiskMB: nil,
            estimatedRAMMB: nil
        )
    }

    static func filteredModels(
        in models: [LocalASRModelDescriptor],
        includeAdvanced: Bool,
        searchQuery: String
    ) -> [LocalASRModelDescriptor] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return models.filter { descriptor in
            if !includeAdvanced && descriptor.isAdvanced {
                return false
            }
            guard !query.isEmpty else {
                return true
            }
            return descriptor.displayName.lowercased().contains(query)
                || descriptor.hfRepo.lowercased().contains(query)
                || descriptor.family.rawValue.lowercased().contains(query)
        }
    }

    static func httpModelPresets(for provider: LocalASRProviderOption) -> [String] {
        providerHTTPModelPresets[provider] ?? []
    }

    static func cacheDirectories(forHFRepo repo: String) -> [URL] {
        let normalized = repo.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "--")
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".cache/huggingface/hub/models--\(normalized)"),
            home.appendingPathComponent("Library/Caches/huggingface/hub/models--\(normalized)"),
        ]
    }

    static func hasLocalCache(forHFRepo repo: String) -> Bool {
        let fileManager = FileManager.default
        return cacheDirectories(forHFRepo: repo)
            .contains { fileManager.fileExists(atPath: $0.path) }
    }

    static func clearLocalCache(forHFRepo repo: String) throws -> Int {
        let fileManager = FileManager.default
        var removed = 0
        for directory in cacheDirectories(forHFRepo: repo) {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            try fileManager.removeItem(at: directory)
            removed += 1
        }
        return removed
    }

    static func remoteModels() async throws -> [LocalASRModelDescriptor] {
        let (data, response) = try await URLSession.shared.data(from: remoteCatalogURL)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try decoder.decode(HuggingFaceWhisperCollectionResponse.self, from: data)
        let parsed = decoded.items.compactMap { descriptor(fromHFRepo: $0.id) }
        return normalizeModels(parsed)
    }

    static func loadCache(from cacheURL: URL) -> [LocalASRModelDescriptor]? {
        guard let data = try? Data(contentsOf: cacheURL) else {
            return nil
        }
        if let payload = try? decoder.decode(LocalASRModelCatalogCachePayload.self, from: data) {
            return normalizeModels(payload.models)
        }
        if let directModels = try? decoder.decode([LocalASRModelDescriptor].self, from: data) {
            return normalizeModels(directModels)
        }
        return nil
    }

    static func saveCache(_ models: [LocalASRModelDescriptor], to cacheURL: URL) throws {
        let normalized = normalizeModels(models)
        let payload = LocalASRModelCatalogCachePayload(updatedAt: Date(), models: normalized)
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let parent = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
    }

    private static func normalizeModels(_ models: [LocalASRModelDescriptor]) -> [LocalASRModelDescriptor] {
        var byID: [String: LocalASRModelDescriptor] = [:]
        for descriptor in models {
            byID[descriptor.id.lowercased()] = descriptor
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.family.sortOrder != rhs.family.sortOrder {
                return lhs.family.sortOrder < rhs.family.sortOrder
            }
            if lhs.variant.sortOrder != rhs.variant.sortOrder {
                return lhs.variant.sortOrder < rhs.variant.sortOrder
            }
            if lhs.precision.sortOrder != rhs.precision.sortOrder {
                return lhs.precision.sortOrder < rhs.precision.sortOrder
            }
            if lhs.isAdvanced != rhs.isAdvanced {
                return lhs.isAdvanced == false
            }
            return lhs.hfRepo.localizedCaseInsensitiveCompare(rhs.hfRepo) == .orderedAscending
        }
    }

    private static func descriptor(fromHFRepo repo: String) -> LocalASRModelDescriptor? {
        let normalizedRepo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedRepo.hasPrefix("mlx-community/whisper-") else {
            return nil
        }

        let name = normalizedRepo.replacingOccurrences(of: "mlx-community/", with: "")
        if name.contains("turbo") {
            return nil
        }

        var suffix = name.replacingOccurrences(of: "whisper-", with: "")
        var precision: LocalASRModelPrecision = .default

        if suffix.hasSuffix("-fp32") {
            precision = .fp32
            suffix.removeLast("-fp32".count)
        } else if suffix.hasSuffix("-8bit") {
            precision = .bit8
            suffix.removeLast("-8bit".count)
        } else if suffix.hasSuffix("-4bit") || suffix.hasSuffix("-q4") {
            precision = .bit4
            if suffix.hasSuffix("-4bit") {
                suffix.removeLast("-4bit".count)
            } else {
                suffix.removeLast("-q4".count)
            }
        } else if suffix.hasSuffix("-2bit") {
            precision = .bit2
            suffix.removeLast("-2bit".count)
        }

        guard suffix.hasSuffix("-mlx") else {
            return nil
        }
        suffix.removeLast("-mlx".count)

        var variant: LocalASRModelVariant = .multilingual
        if suffix.contains(".en") {
            suffix = suffix.replacingOccurrences(of: ".en", with: "")
            variant = .englishOnly
        }

        let rawFamily = suffix
        let family: LocalASRModelFamily
        var derivedAdvanced = false
        switch rawFamily {
        case "tiny":
            family = .tiny
        case "base":
            family = .base
        case "small":
            family = .small
        case "medium":
            family = .medium
        case "large", "large-v1":
            family = .large
            derivedAdvanced = rawFamily == "large-v1"
        case "large-v2":
            family = .largeV2
        case "large-v3":
            family = .largeV3
        default:
            return nil
        }

        let isAdvanced = derivedAdvanced
            || variant != .multilingual
            || precision == .bit2
            || precision == .fp32
        let displayName = "Whisper \(family.displayName) · \(variant.displayName) · \(precision.displayName)"

        return LocalASRModelDescriptor(
            id: normalizedRepo,
            displayName: displayName,
            hfRepo: normalizedRepo,
            family: family,
            variant: variant,
            precision: precision,
            isAdvanced: isAdvanced,
            estimatedDiskMB: nil,
            estimatedRAMMB: nil
        )
    }
}
