import Combine
import Foundation


@MainActor
final class EngineConfig: ObservableObject {
    private enum Keys {
        static let asrModel = "GhostType.asrModel"
        static let llmModel = "GhostType.llmModel"
        static let asrEngine = "GhostType.asrEngine"
        static let llmEngine = "GhostType.llmEngine"
        static let localASRModel = "GhostType.localASRModel"
        static let selectedLocalASRProvider = "GhostType.selectedLocalASRProvider"
        static let selectedLocalASRModelID = "GhostType.selectedLocalASRModelId"
        static let localASRShowAdvancedModels = "GhostType.localASRShowAdvancedModels"
        static let localLLMShowAdvancedQuantization = "GhostType.localLLMShowAdvancedQuantization"
        static let localHTTPASRBaseURL = "GhostType.localHTTPASRBaseURL"
        static let localHTTPASRModelName = "GhostType.localHTTPASRModelName"
        static let localASRFunASRVADEnabled = "GhostType.localASRFunASRVADEnabled"
        static let localASRFunASRPunctuationEnabled = "GhostType.localASRFunASRPunctuationEnabled"
        static let localASRWeNetModelType = "GhostType.localASRWeNetModelType"
        static let localASRWhisperCppBinaryPath = "GhostType.localASRWhisperCppBinaryPath"
        static let localASRWhisperCppModelPath = "GhostType.localASRWhisperCppModelPath"
        static let cloudASRBaseURL = "GhostType.cloudASRBaseURL"
        static let cloudASRModelName = "GhostType.cloudASRModelName"
        static let cloudASRModelCatalog = "GhostType.cloudASRModelCatalog"
        static let cloudASRLanguage = "GhostType.cloudASRLanguage"
        static let cloudASRRequestPath = "GhostType.cloudASRRequestPath"
        static let cloudASRAuthMode = "GhostType.cloudASRAuthMode"
        static let cloudASRApiKeyRef = "GhostType.cloudASRApiKeyRef"
        static let cloudASRHeadersJSON = "GhostType.cloudASRHeadersJSON"
        static let cloudASRProviderKind = "GhostType.cloudASRProviderKind"
        static let cloudASRTimeoutSec = "GhostType.cloudASRTimeoutSec"
        static let cloudASRMaxRetries = "GhostType.cloudASRMaxRetries"
        static let cloudASRMaxInFlight = "GhostType.cloudASRMaxInFlight"
        static let cloudASRStreamingEnabled = "GhostType.cloudASRStreamingEnabled"
        static let legacyASRLanguage = "asrLanguage"
        static let cloudLLMBaseURL = "GhostType.cloudLLMBaseURL"
        static let cloudLLMModelName = "GhostType.cloudLLMModelName"
        static let cloudLLMModelCatalog = "GhostType.cloudLLMModelCatalog"
        static let cloudLLMAPIVersion = "GhostType.cloudLLMAPIVersion"
        static let cloudLLMRequestPath = "GhostType.cloudLLMRequestPath"
        static let cloudLLMAuthMode = "GhostType.cloudLLMAuthMode"
        static let cloudLLMApiKeyRef = "GhostType.cloudLLMApiKeyRef"
        static let cloudLLMHeadersJSON = "GhostType.cloudLLMHeadersJSON"
        static let cloudLLMProviderKind = "GhostType.cloudLLMProviderKind"
        static let cloudLLMTimeoutSec = "GhostType.cloudLLMTimeoutSec"
        static let cloudLLMMaxRetries = "GhostType.cloudLLMMaxRetries"
        static let cloudLLMMaxInFlight = "GhostType.cloudLLMMaxInFlight"
        static let cloudLLMStreamingEnabled = "GhostType.cloudLLMStreamingEnabled"
        static let selectedASRProviderID = "GhostType.selectedASRProviderID"
        static let selectedLLMProviderID = "GhostType.selectedLLMProviderID"
        static let privacyModeEnabled = "GhostType.privacyModeEnabled"
        static let keychainDiagnosticsEnabled = "GhostType.keychainDiagnosticsEnabled"
        static let llmTemperature = "GhostType.llmTemperature"
        static let llmTopP = "GhostType.llmTopP"
        static let llmMaxTokens = "GhostType.llmMaxTokens"
        static let llmRepetitionPenalty = "GhostType.llmRepetitionPenalty"
        static let llmSeed = "GhostType.llmSeed"
        static let llmStopSequences = "GhostType.llmStopSequences"
        static let llmMemorySavingMode = "GhostType.llmMemorySavingMode"
        static let localLLMUseNewUI = "GhostType.localLLMUseNewUI"
    }

    private let defaults: UserDefaults
    let providerRegistryStore: ProviderRegistryStore
    private let localASRModelCatalogCacheURL: URL
    @Published var deepgram: DeepgramSettings
    private var deepgramCancellable: AnyCancellable?
    let localLLMCatalog: LocalLLMCatalogStore = LocalLLMCatalogStore()

    @Published var customASRProviders: [ASRProviderProfile] {
        didSet {
            persistProviderRegistry()
        }
    }

    @Published var customLLMProviders: [LLMProviderProfile] {
        didSet {
            persistProviderRegistry()
        }
    }

    @Published var selectedASRProviderID: String {
        didSet {
            defaults.set(selectedASRProviderID, forKey: Keys.selectedASRProviderID)
        }
    }

    @Published var selectedLLMProviderID: String {
        didSet {
            defaults.set(selectedLLMProviderID, forKey: Keys.selectedLLMProviderID)
        }
    }

    @Published var asrEngine: ASREngineOption {
        didSet {
            defaults.set(asrEngine.rawValue, forKey: Keys.asrEngine)
            if asrEngine == .localMLX || asrEngine == .localHTTPOpenAIAudio {
                let provider = LocalASRProviderOption.from(asrEngine: asrEngine)
                if localASRProvider != provider {
                    localASRProvider = provider
                }
            }
            notifyEngineConfigChanged()
        }
    }

    @Published var llmEngine: LLMEngineOption {
        didSet {
            defaults.set(llmEngine.rawValue, forKey: Keys.llmEngine)
            notifyEngineConfigChanged()
        }
    }

    @Published var localASRProvider: LocalASRProviderOption {
        didSet {
            defaults.set(localASRProvider.rawValue, forKey: Keys.selectedLocalASRProvider)
            if localASRProvider.runtimeKind == .localHTTP {
                let baseTrimmed = localHTTPASRBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if baseTrimmed.isEmpty {
                    localHTTPASRBaseURL = LocalASRModelCatalog.defaultLocalHTTPBaseURL
                }
                let modelTrimmed = localHTTPASRModelName.trimmingCharacters(in: .whitespacesAndNewlines)
                if modelTrimmed.isEmpty {
                    localHTTPASRModelName = localASRProvider.defaultHTTPModelName
                }
            }
            if (asrEngine == .localMLX || asrEngine == .localHTTPOpenAIAudio),
               asrEngine != localASRProvider.asrEngine {
                asrEngine = localASRProvider.asrEngine
            } else {
                notifyEngineConfigChanged()
            }
        }
    }

    @Published var selectedLocalASRModelID: String {
        didSet {
            let normalized = LocalASRModelCatalog.normalizeModelID(selectedLocalASRModelID)
            if selectedLocalASRModelID != normalized {
                selectedLocalASRModelID = normalized
                return
            }
            defaults.set(selectedLocalASRModelID, forKey: Keys.selectedLocalASRModelID)
            let descriptor = localASRModelDescriptor(for: normalized)
            if asrModel != descriptor.hfRepo {
                asrModel = descriptor.hfRepo
            } else {
                notifyEngineConfigChanged()
            }
        }
    }

    @Published var localASRShowAdvancedModels: Bool {
        didSet {
            defaults.set(localASRShowAdvancedModels, forKey: Keys.localASRShowAdvancedModels)
        }
    }

    @Published var localLLMShowAdvancedQuantization: Bool {
        didSet {
            defaults.set(localLLMShowAdvancedQuantization, forKey: Keys.localLLMShowAdvancedQuantization)
            notifyEngineConfigChanged()
        }
    }

    @Published var localHTTPASRBaseURL: String {
        didSet {
            defaults.set(localHTTPASRBaseURL, forKey: Keys.localHTTPASRBaseURL)
            notifyEngineConfigChanged()
        }
    }

    @Published var localHTTPASRModelName: String {
        didSet {
            defaults.set(localHTTPASRModelName, forKey: Keys.localHTTPASRModelName)
            notifyEngineConfigChanged()
        }
    }

    @Published var localASRFunASRVADEnabled: Bool {
        didSet {
            defaults.set(localASRFunASRVADEnabled, forKey: Keys.localASRFunASRVADEnabled)
            notifyEngineConfigChanged()
        }
    }

    @Published var localASRFunASRPunctuationEnabled: Bool {
        didSet {
            defaults.set(localASRFunASRPunctuationEnabled, forKey: Keys.localASRFunASRPunctuationEnabled)
            notifyEngineConfigChanged()
        }
    }

    @Published var localASRWeNetModelType: LocalASRWeNetModelType {
        didSet {
            defaults.set(localASRWeNetModelType.rawValue, forKey: Keys.localASRWeNetModelType)
            notifyEngineConfigChanged()
        }
    }

    @Published var localASRWhisperCppBinaryPath: String {
        didSet {
            defaults.set(localASRWhisperCppBinaryPath, forKey: Keys.localASRWhisperCppBinaryPath)
            notifyEngineConfigChanged()
        }
    }

    @Published var localASRWhisperCppModelPath: String {
        didSet {
            defaults.set(localASRWhisperCppModelPath, forKey: Keys.localASRWhisperCppModelPath)
            notifyEngineConfigChanged()
        }
    }

    @Published private(set) var localASRModelCatalog: [LocalASRModelDescriptor]
    @Published private(set) var isRefreshingLocalASRModelCatalog = false
    @Published private(set) var localASRModelCatalogStatus = ""

    @Published var asrModel: String {
        didSet {
            defaults.set(asrModel, forKey: Keys.asrModel)
            notifyEngineConfigChanged()
        }
    }

    @Published var llmModel: String {
        didSet {
            defaults.set(llmModel, forKey: Keys.llmModel)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudLLMBaseURL: String {
        didSet {
            defaults.set(cloudLLMBaseURL, forKey: Keys.cloudLLMBaseURL)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudLLMModelName: String {
        didSet {
            defaults.set(cloudLLMModelName, forKey: Keys.cloudLLMModelName)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudLLMModelCatalog: String {
        didSet {
            defaults.set(cloudLLMModelCatalog, forKey: Keys.cloudLLMModelCatalog)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudLLMRequestPath: String {
        didSet {
            defaults.set(cloudLLMRequestPath, forKey: Keys.cloudLLMRequestPath)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudLLMAuthMode: ProviderAuthMode {
        didSet {
            defaults.set(cloudLLMAuthMode.rawValue, forKey: Keys.cloudLLMAuthMode)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudLLMApiKeyRef: String {
        didSet {
            defaults.set(cloudLLMApiKeyRef, forKey: Keys.cloudLLMApiKeyRef)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudLLMHeadersJSON: String {
        didSet {
            defaults.set(cloudLLMHeadersJSON, forKey: Keys.cloudLLMHeadersJSON)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudLLMProviderKind: ProviderKind {
        didSet {
            defaults.set(cloudLLMProviderKind.rawValue, forKey: Keys.cloudLLMProviderKind)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudLLMTimeoutSec: Double {
        didSet {
            let clamped = max(15, min(3_600, cloudLLMTimeoutSec))
            if cloudLLMTimeoutSec != clamped {
                cloudLLMTimeoutSec = clamped
                return
            }
            defaults.set(cloudLLMTimeoutSec, forKey: Keys.cloudLLMTimeoutSec)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudLLMMaxRetries: Int {
        didSet {
            let clamped = max(0, min(8, cloudLLMMaxRetries))
            if cloudLLMMaxRetries != clamped {
                cloudLLMMaxRetries = clamped
                return
            }
            defaults.set(cloudLLMMaxRetries, forKey: Keys.cloudLLMMaxRetries)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudLLMMaxInFlight: Int {
        didSet {
            let clamped = max(1, min(8, cloudLLMMaxInFlight))
            if cloudLLMMaxInFlight != clamped {
                cloudLLMMaxInFlight = clamped
                return
            }
            defaults.set(cloudLLMMaxInFlight, forKey: Keys.cloudLLMMaxInFlight)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudLLMStreamingEnabled: Bool {
        didSet {
            defaults.set(cloudLLMStreamingEnabled, forKey: Keys.cloudLLMStreamingEnabled)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudLLMAPIVersion: String {
        didSet {
            defaults.set(cloudLLMAPIVersion, forKey: Keys.cloudLLMAPIVersion)
            notifyEngineConfigChanged()
        }
    }

    @Published var privacyModeEnabled: Bool {
        didSet {
            defaults.set(privacyModeEnabled, forKey: Keys.privacyModeEnabled)
        }
    }

    @Published var keychainDiagnosticsEnabled: Bool {
        didSet {
            defaults.set(keychainDiagnosticsEnabled, forKey: Keys.keychainDiagnosticsEnabled)
        }
    }

    @Published var llmTemperature: Double {
        didSet {
            let clamped = max(0.0, min(2.0, llmTemperature))
            if llmTemperature != clamped {
                llmTemperature = clamped
                return
            }
            defaults.set(llmTemperature, forKey: Keys.llmTemperature)
            notifyEngineConfigChanged()
        }
    }

    @Published var llmTopP: Double {
        didSet {
            let clamped = max(0.0, min(1.0, llmTopP))
            if llmTopP != clamped {
                llmTopP = clamped
                return
            }
            defaults.set(llmTopP, forKey: Keys.llmTopP)
            notifyEngineConfigChanged()
        }
    }

    @Published var llmMaxTokens: Int {
        didSet {
            let clamped = max(1, min(32768, llmMaxTokens))
            if llmMaxTokens != clamped {
                llmMaxTokens = clamped
                return
            }
            defaults.set(llmMaxTokens, forKey: Keys.llmMaxTokens)
            notifyEngineConfigChanged()
        }
    }

    @Published var llmRepetitionPenalty: Double {
        didSet {
            let clamped = max(1.0, min(2.0, llmRepetitionPenalty))
            if llmRepetitionPenalty != clamped { llmRepetitionPenalty = clamped; return }
            defaults.set(llmRepetitionPenalty, forKey: Keys.llmRepetitionPenalty)
            notifyEngineConfigChanged()
        }
    }

    @Published var llmSeed: Int {
        didSet {
            defaults.set(llmSeed, forKey: Keys.llmSeed)
            notifyEngineConfigChanged()
        }
    }

    @Published var llmStopSequences: String {
        didSet {
            defaults.set(llmStopSequences, forKey: Keys.llmStopSequences)
            notifyEngineConfigChanged()
        }
    }

    @Published var llmMemorySavingMode: Bool {
        didSet {
            defaults.set(llmMemorySavingMode, forKey: Keys.llmMemorySavingMode)
            notifyEngineConfigChanged()
        }
    }

    @Published var localLLMUseNewUI: Bool {
        didSet {
            defaults.set(localLLMUseNewUI, forKey: Keys.localLLMUseNewUI)
        }
    }

    @Published var cloudASRBaseURL: String {
        didSet {
            defaults.set(cloudASRBaseURL, forKey: Keys.cloudASRBaseURL)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudASRModelName: String {
        didSet {
            defaults.set(cloudASRModelName, forKey: Keys.cloudASRModelName)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudASRModelCatalog: String {
        didSet {
            defaults.set(cloudASRModelCatalog, forKey: Keys.cloudASRModelCatalog)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudASRLanguage: String {
        didSet {
            defaults.set(cloudASRLanguage, forKey: Keys.cloudASRLanguage)
            defaults.set(cloudASRLanguage, forKey: Keys.legacyASRLanguage)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudASRRequestPath: String {
        didSet {
            defaults.set(cloudASRRequestPath, forKey: Keys.cloudASRRequestPath)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudASRAuthMode: ProviderAuthMode {
        didSet {
            defaults.set(cloudASRAuthMode.rawValue, forKey: Keys.cloudASRAuthMode)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudASRApiKeyRef: String {
        didSet {
            defaults.set(cloudASRApiKeyRef, forKey: Keys.cloudASRApiKeyRef)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudASRHeadersJSON: String {
        didSet {
            defaults.set(cloudASRHeadersJSON, forKey: Keys.cloudASRHeadersJSON)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudASRProviderKind: ProviderKind {
        didSet {
            defaults.set(cloudASRProviderKind.rawValue, forKey: Keys.cloudASRProviderKind)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudASRTimeoutSec: Double {
        didSet {
            let clamped = max(15, min(1_800, cloudASRTimeoutSec))
            if cloudASRTimeoutSec != clamped {
                cloudASRTimeoutSec = clamped
                return
            }
            defaults.set(cloudASRTimeoutSec, forKey: Keys.cloudASRTimeoutSec)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudASRMaxRetries: Int {
        didSet {
            let clamped = max(0, min(8, cloudASRMaxRetries))
            if cloudASRMaxRetries != clamped {
                cloudASRMaxRetries = clamped
                return
            }
            defaults.set(cloudASRMaxRetries, forKey: Keys.cloudASRMaxRetries)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudASRMaxInFlight: Int {
        didSet {
            let clamped = max(1, min(8, cloudASRMaxInFlight))
            if cloudASRMaxInFlight != clamped {
                cloudASRMaxInFlight = clamped
                return
            }
            defaults.set(cloudASRMaxInFlight, forKey: Keys.cloudASRMaxInFlight)
            notifyEngineConfigChanged()
        }
    }

    @Published var cloudASRStreamingEnabled: Bool {
        didSet {
            defaults.set(cloudASRStreamingEnabled, forKey: Keys.cloudASRStreamingEnabled)
            notifyEngineConfigChanged()
        }
    }

    init(defaults: UserDefaults = .standard, providerRegistryStore: ProviderRegistryStore = .shared) {
        self.defaults = defaults
        self.providerRegistryStore = providerRegistryStore
        localASRModelCatalogCacheURL = Self.resolveLocalASRModelCatalogCacheURL()

        let cachedLocalCatalog = LocalASRModelCatalog.loadCache(from: localASRModelCatalogCacheURL) ?? []
        let mergedLocalCatalog = LocalASRModelCatalog.mergedModels(
            local: LocalASRModelCatalog.builtInModels,
            remote: cachedLocalCatalog
        )
        localASRModelCatalog = mergedLocalCatalog
        isRefreshingLocalASRModelCatalog = false
        localASRModelCatalogStatus = ""

        let registry = providerRegistryStore.load()
        customASRProviders = Self.normalizedCustomASRProviders(registry.customASRProviders)
        customLLMProviders = Self.normalizedCustomLLMProviders(registry.customLLMProviders)
        selectedASRProviderID = defaults.string(forKey: Keys.selectedASRProviderID) ?? ""
        selectedLLMProviderID = defaults.string(forKey: Keys.selectedLLMProviderID) ?? ""

        let loadedASREngine = ASREngineOption(rawValue: defaults.string(forKey: Keys.asrEngine) ?? "") ?? .localMLX
        asrEngine = loadedASREngine
        llmEngine = LLMEngineOption(rawValue: defaults.string(forKey: Keys.llmEngine) ?? "") ?? .localMLX

        let storedLocalProvider = LocalASRProviderOption(
            rawValue: defaults.string(forKey: Keys.selectedLocalASRProvider) ?? ""
        )
        let initialLocalASRProvider = storedLocalProvider ?? LocalASRProviderOption.from(asrEngine: loadedASREngine)
        localASRProvider = initialLocalASRProvider

        let storedLocalModelID = defaults.string(forKey: Keys.selectedLocalASRModelID)
            ?? Self.legacyLocalASRModelID(from: defaults.string(forKey: Keys.localASRModel))
            ?? defaults.string(forKey: Keys.asrModel)
        let fallbackLocalModel = LocalASRModelCatalog.fallbackDescriptor(in: mergedLocalCatalog).id
        let initialSelectedLocalASRModelID = LocalASRModelCatalog.normalizeModelID(
            storedLocalModelID ?? fallbackLocalModel
        )
        selectedLocalASRModelID = initialSelectedLocalASRModelID
        localASRShowAdvancedModels = defaults.object(forKey: Keys.localASRShowAdvancedModels) as? Bool ?? false
        localLLMShowAdvancedQuantization = defaults.object(forKey: Keys.localLLMShowAdvancedQuantization) as? Bool ?? false
        localHTTPASRBaseURL = defaults.string(forKey: Keys.localHTTPASRBaseURL) ?? LocalASRModelCatalog.defaultLocalHTTPBaseURL
        localHTTPASRModelName = defaults.string(forKey: Keys.localHTTPASRModelName) ?? initialLocalASRProvider.defaultHTTPModelName
        localASRFunASRVADEnabled = defaults.object(forKey: Keys.localASRFunASRVADEnabled) as? Bool ?? true
        localASRFunASRPunctuationEnabled = defaults.object(forKey: Keys.localASRFunASRPunctuationEnabled) as? Bool ?? true
        localASRWeNetModelType = LocalASRWeNetModelType(
            rawValue: defaults.string(forKey: Keys.localASRWeNetModelType) ?? ""
        ) ?? .checkpoint
        localASRWhisperCppBinaryPath = defaults.string(forKey: Keys.localASRWhisperCppBinaryPath) ?? ""
        localASRWhisperCppModelPath = defaults.string(forKey: Keys.localASRWhisperCppModelPath) ?? ""

        let storedASRModel = defaults.string(forKey: Keys.asrModel)
            ?? LocalASRModelCatalog.descriptor(
                for: initialSelectedLocalASRModelID,
                in: mergedLocalCatalog
            )?.hfRepo
            ?? fallbackLocalModel
        asrModel = storedASRModel
        llmModel = defaults.string(forKey: Keys.llmModel) ?? "mlx-community/Qwen2.5-1.5B-Instruct-4bit"

        let storedCloudASRBaseURL = defaults.string(forKey: Keys.cloudASRBaseURL) ?? loadedASREngine.defaultBaseURL
        cloudASRBaseURL = storedCloudASRBaseURL
        cloudASRModelName = defaults.string(forKey: Keys.cloudASRModelName) ?? loadedASREngine.defaultModelName
        cloudASRModelCatalog = defaults.string(forKey: Keys.cloudASRModelCatalog) ?? ""

        let initialCloudASRLanguage: String
        if let storedASRLanguage = defaults.string(forKey: Keys.cloudASRLanguage)
            ?? defaults.string(forKey: Keys.legacyASRLanguage) {
            initialCloudASRLanguage = storedASRLanguage
        } else {
            initialCloudASRLanguage = loadedASREngine == .deepgram
                ? DeepgramLanguageStrategy.chineseSimplified.rawValue
                : "auto"
        }
        cloudASRLanguage = loadedASREngine == .deepgram
            ? DeepgramConfig.normalizedLanguageCode(initialCloudASRLanguage)
            : initialCloudASRLanguage
        cloudASRRequestPath = defaults.string(forKey: Keys.cloudASRRequestPath) ?? ASRProviderRequestConfig.openAIDefault.path
        cloudASRAuthMode = ProviderAuthMode(rawValue: defaults.string(forKey: Keys.cloudASRAuthMode) ?? "") ?? .bearer
        cloudASRApiKeyRef = defaults.string(forKey: Keys.cloudASRApiKeyRef) ?? ""
        cloudASRHeadersJSON = defaults.string(forKey: Keys.cloudASRHeadersJSON) ?? "{}"
        cloudASRProviderKind = ProviderKind(rawValue: defaults.string(forKey: Keys.cloudASRProviderKind) ?? "") ?? .openAICompatible
        let storedASRTimeout = defaults.object(forKey: Keys.cloudASRTimeoutSec) as? Double
        cloudASRTimeoutSec = max(15, min(1_800, storedASRTimeout ?? ProviderAdvancedConfig.asrDefault.timeoutSec))
        let storedASRMaxRetries = defaults.object(forKey: Keys.cloudASRMaxRetries) as? Int
        cloudASRMaxRetries = max(0, min(8, storedASRMaxRetries ?? ProviderAdvancedConfig.asrDefault.maxRetries))
        let storedASRMaxInFlight = defaults.object(forKey: Keys.cloudASRMaxInFlight) as? Int
        cloudASRMaxInFlight = max(1, min(8, storedASRMaxInFlight ?? ProviderAdvancedConfig.asrDefault.maxInFlight))
        if defaults.object(forKey: Keys.cloudASRStreamingEnabled) == nil {
            cloudASRStreamingEnabled = ProviderAdvancedConfig.asrDefault.streamingEnabled
        } else {
            cloudASRStreamingEnabled = defaults.bool(forKey: Keys.cloudASRStreamingEnabled)
        }
        deepgram = DeepgramSettings(defaults: defaults, initialBaseURL: storedCloudASRBaseURL)

        cloudLLMBaseURL = defaults.string(forKey: Keys.cloudLLMBaseURL) ?? "https://api.openai.com/v1"
        cloudLLMModelName = defaults.string(forKey: Keys.cloudLLMModelName) ?? "gpt-4o-mini"
        cloudLLMModelCatalog = defaults.string(forKey: Keys.cloudLLMModelCatalog) ?? ""
        cloudLLMRequestPath = defaults.string(forKey: Keys.cloudLLMRequestPath) ?? LLMProviderRequestConfig.openAIDefault.path
        cloudLLMAuthMode = ProviderAuthMode(rawValue: defaults.string(forKey: Keys.cloudLLMAuthMode) ?? "") ?? .bearer
        cloudLLMApiKeyRef = defaults.string(forKey: Keys.cloudLLMApiKeyRef) ?? ""
        cloudLLMHeadersJSON = defaults.string(forKey: Keys.cloudLLMHeadersJSON) ?? "{}"
        cloudLLMProviderKind = ProviderKind(rawValue: defaults.string(forKey: Keys.cloudLLMProviderKind) ?? "") ?? .openAICompatible
        let storedLLMTimeout = defaults.object(forKey: Keys.cloudLLMTimeoutSec) as? Double
        cloudLLMTimeoutSec = max(15, min(3_600, storedLLMTimeout ?? ProviderAdvancedConfig.llmDefault.timeoutSec))
        let storedLLMMaxRetries = defaults.object(forKey: Keys.cloudLLMMaxRetries) as? Int
        cloudLLMMaxRetries = max(0, min(8, storedLLMMaxRetries ?? ProviderAdvancedConfig.llmDefault.maxRetries))
        let storedLLMMaxInFlight = defaults.object(forKey: Keys.cloudLLMMaxInFlight) as? Int
        cloudLLMMaxInFlight = max(1, min(8, storedLLMMaxInFlight ?? ProviderAdvancedConfig.llmDefault.maxInFlight))
        if defaults.object(forKey: Keys.cloudLLMStreamingEnabled) == nil {
            cloudLLMStreamingEnabled = ProviderAdvancedConfig.llmDefault.streamingEnabled
        } else {
            cloudLLMStreamingEnabled = defaults.bool(forKey: Keys.cloudLLMStreamingEnabled)
        }
        cloudLLMAPIVersion = defaults.string(forKey: Keys.cloudLLMAPIVersion) ?? "2024-02-01"
        privacyModeEnabled = defaults.object(forKey: Keys.privacyModeEnabled) as? Bool ?? true
        keychainDiagnosticsEnabled = defaults.object(forKey: Keys.keychainDiagnosticsEnabled) as? Bool ?? false

        let storedTemperature = defaults.object(forKey: Keys.llmTemperature) as? Double
        llmTemperature = storedTemperature ?? 0.4
        let storedTopP = defaults.object(forKey: Keys.llmTopP) as? Double
        llmTopP = storedTopP ?? 0.95
        let storedMaxTokens = defaults.integer(forKey: Keys.llmMaxTokens)
        llmMaxTokens = storedMaxTokens > 0 ? storedMaxTokens : 4096
        let storedRepetition = defaults.object(forKey: Keys.llmRepetitionPenalty) as? Double
        llmRepetitionPenalty = storedRepetition ?? 1.0
        let storedSeed = defaults.object(forKey: Keys.llmSeed) as? Int
        llmSeed = storedSeed ?? -1
        llmStopSequences = defaults.string(forKey: Keys.llmStopSequences) ?? ""
        llmMemorySavingMode = defaults.object(forKey: Keys.llmMemorySavingMode) as? Bool ?? false
        localLLMUseNewUI = defaults.object(forKey: Keys.localLLMUseNewUI) as? Bool ?? true

        let fallbackASRProviderID = EngineProviderDefaults.ASR.defaultProviderID(for: loadedASREngine)
        let fallbackLLMProviderID = EngineProviderDefaults.LLM.defaultProviderID(for: llmEngine)
        selectedASRProviderID = normalizedASRProviderID(selectedASRProviderID, fallbackID: fallbackASRProviderID)
        selectedLLMProviderID = normalizedLLMProviderID(selectedLLMProviderID, fallbackID: fallbackLLMProviderID)
        defaults.set(selectedASRProviderID, forKey: Keys.selectedASRProviderID)
        defaults.set(selectedLLMProviderID, forKey: Keys.selectedLLMProviderID)

        deepgram.onChange = { [weak self] in
            self?.notifyEngineConfigChanged()
        }
        deepgramCancellable = deepgram.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        alignSelectedLocalASRModelWithASRModel()
    }

    var localASRModelDescriptors: [LocalASRModelDescriptor] {
        localASRModelCatalog
    }

    func localASRModelDescriptor(for id: String? = nil) -> LocalASRModelDescriptor {
        if let descriptor = LocalASRModelCatalog.descriptor(
            for: id ?? selectedLocalASRModelID,
            in: localASRModelCatalog
        ) {
            return descriptor
        }
        return LocalASRModelCatalog.fallbackDescriptor(in: localASRModelCatalog)
    }

    func refreshLocalASRModelCatalog() async {
        guard !isRefreshingLocalASRModelCatalog else { return }
        isRefreshingLocalASRModelCatalog = true
        localASRModelCatalogStatus = "Refreshing local Whisper model catalog..."
        defer { isRefreshingLocalASRModelCatalog = false }

        do {
            let remote = try await LocalASRModelCatalog.remoteModels()
            let merged = LocalASRModelCatalog.mergedModels(
                local: LocalASRModelCatalog.builtInModels,
                remote: remote
            )
            localASRModelCatalog = merged
            alignSelectedLocalASRModelWithCatalog()
            try LocalASRModelCatalog.saveCache(merged, to: localASRModelCatalogCacheURL)
            localASRModelCatalogStatus = "Loaded \(remote.count) models from Hugging Face."
        } catch {
            localASRModelCatalogStatus = "Catalog refresh failed. Using built-in list."
        }
    }

    private func alignSelectedLocalASRModelWithCatalog() {
        let descriptor = localASRModelDescriptor(for: selectedLocalASRModelID)
        if selectedLocalASRModelID != descriptor.id {
            selectedLocalASRModelID = descriptor.id
        } else if asrModel != descriptor.hfRepo {
            asrModel = descriptor.hfRepo
        }
    }

    private func alignSelectedLocalASRModelWithASRModel() {
        if let descriptor = LocalASRModelCatalog.descriptor(for: asrModel, in: localASRModelCatalog) {
            selectedLocalASRModelID = descriptor.id
            return
        }
        alignSelectedLocalASRModelWithCatalog()
    }

    private static func resolveLocalASRModelCatalogCacheURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("GhostType", isDirectory: true)
            .appendingPathComponent("model_catalog.json")
    }

    private static func legacyLocalASRModelID(from rawValue: String?) -> String? {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "whisper-tiny":
            return "mlx-community/whisper-tiny-mlx"
        case "whisper-base":
            return "mlx-community/whisper-base-mlx"
        case "whisper-small":
            return "mlx-community/whisper-small-mlx"
        default:
            return nil
        }
    }
}
