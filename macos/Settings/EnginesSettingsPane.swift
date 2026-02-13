import AppKit
import SwiftUI

@MainActor
final class EnginesSettingsPaneViewModel: ObservableObject {
    struct CredentialDrafts: Equatable {
        var asrOpenAIKey = ""
        var asrDeepgramKey = ""
        var asrAssemblyAIKey = ""
        var asrGroqKey = ""
        var llmOpenAIKey = ""
        var llmOpenAICompatibleKey = ""
        var llmAzureOpenAIKey = ""
        var llmAnthropicKey = ""
        var llmGeminiKey = ""
        var llmDeepSeekKey = ""
        var llmGroqKey = ""
        var asrCustomProviderKey = ""
        var llmCustomProviderKey = ""
        var asrCustomProviderName = ""
        var llmCustomProviderName = ""
    }

    struct KeychainUIState {
        var status = ""
        var healthStatus = ""
        var guidance = ""
        var needsAttention = false
        var isResettingAllCredentials = false
        var isRunningKeychainRepair = false
        var isRunningLegacyMigration = false
        var savedCredentialCount = 0
    }

    struct ProbeUIState {
        var discoveredASRModels: [String] = []
        var discoveredLLMModels: [String] = []
        var isRefreshingASRModels = false
        var isRefreshingLLMModels = false
        var asrModelStatus = ""
        var llmModelStatus = ""
        var asrModelStatusIsError = false
        var llmModelStatusIsError = false
        var isTestingASRConnection = false
        var isTestingLLMConnection = false
        var asrConnectionStatus = ""
        var llmConnectionStatus = ""
        var asrConnectionStatusIsError = false
        var llmConnectionStatusIsError = false
        var isDownloadingLocalASRModel = false
        var isClearingLocalASRModelCache = false
        var localASRModelActionStatus = ""
        var localASRModelActionStatusIsError = false
    }

    @Published var credentialDrafts = CredentialDrafts()
    @Published var keychain = KeychainUIState()
    @Published var probes = ProbeUIState()
    @Published var localASRModelSearch = ""
}

@MainActor
struct EnginesSettingsPane: View {
    static let customASRProviderMenuID = "__ghosttype.custom_asr__"
    static let manageCustomASRProviderMenuID = "__ghosttype.manage_custom_asr__"
    static let customLLMProviderMenuID = "__ghosttype.custom_llm__"
    static let manageCustomLLMProviderMenuID = "__ghosttype.manage_custom_llm__"
    static let supportedASRLanguages = EngineSettingsCatalog.supportedASRLanguages
    static let supportedASRLanguageCodes = EngineSettingsCatalog.supportedASRLanguageCodes
    static let localLLMModelPresets = EngineSettingsCatalog.localLLMModelPresets
    static let cloudASRModelPresets = EngineSettingsCatalog.cloudASRModelPresets
    static let cloudLLMModelPresets = EngineSettingsCatalog.cloudLLMModelPresets
    static let deepgramASRLanguageOptions: [EngineASRLanguageOption] = DeepgramLanguageStrategy.allCases.map {
        EngineASRLanguageOption(code: $0.rawValue, name: $0.displayName)
    }

    enum EngineRuntimeSelection: String, CaseIterable, Identifiable {
        case local
        case cloud

        var id: String { rawValue }
    }

    private enum LocalASRModelManagementError: LocalizedError {
        case invalidBackendResponse
        case backendRequestFailed(statusCode: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidBackendResponse:
                return "Invalid response from local backend."
            case .backendRequestFailed(let statusCode, let body):
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return "Local backend request failed (HTTP \(statusCode))."
                }
                return "Local backend request failed (HTTP \(statusCode)): \(trimmed)"
            }
        }
    }

    @ObservedObject var engine: EngineConfig
    @ObservedObject var prefs: UserPreferences
    @StateObject var viewModel: EnginesSettingsPaneViewModel
    @State private var credentialAutosaveWorkItem: DispatchWorkItem?

    init(
        engine: EngineConfig,
        prefs: UserPreferences,
        viewModel: EnginesSettingsPaneViewModel? = nil
    ) {
        self.engine = engine
        self.prefs = prefs
        _viewModel = StateObject(wrappedValue: viewModel ?? EnginesSettingsPaneViewModel())
    }

    private func credentialBinding(_ keyPath: WritableKeyPath<EnginesSettingsPaneViewModel.CredentialDrafts, String>) -> Binding<String> {
        Binding(
            get: { viewModel.credentialDrafts[keyPath: keyPath] },
            set: { viewModel.credentialDrafts[keyPath: keyPath] = $0 }
        )
    }

    var body: some View {
        DetailContainer(
            icon: "cpu",
            title: prefs.ui("引擎与模型", "Engines & Models"),
            subtitle: prefs.ui("本地 MLX 与云端 API 配置", "Configure local MLX and cloud APIs")
        ) {
            settingsForm
        }
    }

    private var settingsForm: some View {
        Form {
            asrEngineSection
            llmEngineSection
            networkPrivacySection
            credentialsSection
            engineCombinationSection
            keychainStatusSection
        }
        .formStyle(.grouped)
        .onAppear(perform: handleAppear)
        .onDisappear {
            flushCredentialAutosave()
            persistCredentialInputFieldsToKeychain()
        }
        .onChange(of: viewModel.credentialDrafts) { _, _ in
            scheduleCredentialAutosave()
        }
        .onChange(of: engine.asrEngine) { _, value in
            handleASREngineChange(value)
        }
        .onChange(of: engine.llmEngine) { _, value in
            handleLLMEngineChange(value)
        }
        .onChange(of: engine.selectedASRProviderID) { _, _ in
            viewModel.probes.asrConnectionStatus = ""
            viewModel.probes.asrConnectionStatusIsError = false
            viewModel.credentialDrafts.asrCustomProviderName = engine.selectedASRProvider?.displayName ?? viewModel.credentialDrafts.asrCustomProviderName
            loadCredentialInputFieldsFromKeychain(overwriteExisting: false)
            loadCustomCredentialInputFieldsFromKeychain(overwriteExisting: true)
            syncASRModelPickerOptions()
        }
        .onChange(of: engine.selectedLLMProviderID) { _, _ in
            viewModel.probes.llmConnectionStatus = ""
            viewModel.probes.llmConnectionStatusIsError = false
            viewModel.credentialDrafts.llmCustomProviderName = engine.selectedLLMProvider?.displayName ?? viewModel.credentialDrafts.llmCustomProviderName
            loadCredentialInputFieldsFromKeychain(overwriteExisting: false)
            loadCustomCredentialInputFieldsFromKeychain(overwriteExisting: true)
            syncLLMModelPickerOptions()
        }
        .onChange(of: engine.cloudASRApiKeyRef) { _, _ in
            loadCredentialInputFieldsFromKeychain(overwriteExisting: false)
            loadCustomCredentialInputFieldsFromKeychain(overwriteExisting: true)
        }
        .onChange(of: engine.cloudLLMApiKeyRef) { _, _ in
            loadCredentialInputFieldsFromKeychain(overwriteExisting: false)
            loadCustomCredentialInputFieldsFromKeychain(overwriteExisting: true)
        }
        .onChange(of: engine.cloudASRBaseURL) { _, _ in
            viewModel.probes.asrModelStatus = ""
            viewModel.probes.asrModelStatusIsError = false
        }
        .onChange(of: engine.cloudASRLanguage) { _, _ in
            guard engine.asrEngine == .deepgram else { return }
            normalizeASRLanguageSelection()
            applyDeepgramModelRecommendation(force: true)
        }
        .onChange(of: engine.deepgram.region) { _, value in
            guard engine.asrEngine == .deepgram else { return }
            engine.cloudASRBaseURL = value.defaultHTTPSBaseURL
        }
        .onChange(of: engine.cloudLLMBaseURL) { _, _ in
            viewModel.probes.llmModelStatus = ""
            viewModel.probes.llmModelStatusIsError = false
        }
        .onChange(of: engine.localASRProvider) { _, provider in
            if provider.runtimeKind == .localHTTP {
                syncLocalHTTPASRModelSelection(for: provider)
            }
        }
        .onChange(of: engine.keychainDiagnosticsEnabled) { _, _ in
            viewModel.keychain.savedCredentialCount = AppKeychain.shared.savedSecretCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            persistCredentialsOnLifecycleEvent()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            persistCredentialsOnLifecycleEvent()
        }
    }

    private var credentialsBusy: Bool {
        viewModel.keychain.isResettingAllCredentials
    }

    private var asrEngineSection: some View {
        Section(prefs.ui("ASR 引擎", "ASR Engine")) {
            Picker("Runtime", selection: asrRuntimeSelectionBinding) {
                Text("Local").tag(EngineRuntimeSelection.local)
                Text("Cloud").tag(EngineRuntimeSelection.cloud)
            }
            .pickerStyle(.segmented)
            Text(
                isLocalASREngine
                    ? prefs.ui("音频仅在本机处理。", "Audio is processed locally on this Mac.")
                    : prefs.ui("音频会发送到所选服务进行转写。", "Audio is sent to the selected service for transcription.")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if !isLocalASREngine {
                Picker("Engine", selection: asrProviderSelectionBinding) {
                    ForEach(availableCloudASRProviders) { option in
                        Text(asrProviderDisplayName(option)).tag(option.id)
                    }
                    Divider()
                    Text(prefs.ui("自定义…", "Custom…")).tag(Self.customASRProviderMenuID)
                    Text(prefs.ui("管理自定义…", "Manage Custom…")).tag(Self.manageCustomASRProviderMenuID)
                }
            }
            asrEngineConfigurationView
        }
    }

    @ViewBuilder
    private var asrEngineConfigurationView: some View {
        switch engine.asrEngine {
        case .localMLX, .localHTTPOpenAIAudio:
            localASRConfigurationView
        case .openAIWhisper:
            cloudASRCommonFields
            SecureField("OpenAI API Key", text: credentialBinding(\.asrOpenAIKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: "Save OpenAI ASR Key") {
                saveKey(viewModel.credentialDrafts.asrOpenAIKey, for: .asrOpenAI, providerLabel: "OpenAI ASR")
            }
        case .deepgram:
            cloudASRCommonFields
            SecureField("Deepgram API Key", text: credentialBinding(\.asrDeepgramKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: "Save Deepgram ASR Key") {
                saveKey(viewModel.credentialDrafts.asrDeepgramKey, for: .asrDeepgram, providerLabel: "Deepgram ASR")
            }
        case .assemblyAI:
            cloudASRCommonFields
            SecureField("AssemblyAI API Key", text: credentialBinding(\.asrAssemblyAIKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: "Save AssemblyAI ASR Key") {
                saveKey(viewModel.credentialDrafts.asrAssemblyAIKey, for: .asrAssemblyAI, providerLabel: "AssemblyAI ASR")
            }
        case .groq:
            cloudASRCommonFields
            SecureField("Groq API Key", text: credentialBinding(\.asrGroqKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: "Save Groq ASR Key") {
                saveKey(viewModel.credentialDrafts.asrGroqKey, for: .asrGroq, providerLabel: "Groq ASR")
            }
        case .geminiMultimodal:
            cloudASRCommonFields
            Text("Gemini ASR reuses the Gemini API key from LLM settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            SecureField("Gemini API Key (Shared)", text: credentialBinding(\.llmGeminiKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: "Save Shared Gemini Key") {
                saveKey(viewModel.credentialDrafts.llmGeminiKey, for: .llmGemini, providerLabel: "Gemini (Shared)")
            }
        case .customOpenAICompatible:
            cloudASRCommonFields
            TextField("Custom ASR Provider Name", text: credentialBinding(\.asrCustomProviderName))
                .textFieldStyle(.roundedBorder)
            SecureField("Custom ASR API Key", text: credentialBinding(\.asrCustomProviderKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: "Save Custom ASR Key") {
                saveKeyRef(
                    viewModel.credentialDrafts.asrCustomProviderKey,
                    keyRef: engine.cloudASRApiKeyRef,
                    providerLabel: "Custom ASR"
                )
            }
            HStack(spacing: 8) {
                Button("Save As New ASR Provider") {
                    let fallback = "Custom ASR \(engine.customASRProviders.count + 1)"
                    _ = engine.saveCurrentASRAsCustomProvider(
                        named: viewModel.credentialDrafts.asrCustomProviderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? fallback
                            : viewModel.credentialDrafts.asrCustomProviderName
                    )
                }
                .buttonStyle(.bordered)
                .disabled(!canSaveCustomASRProvider)
                Button("Update Current ASR Provider") {
                    _ = engine.updateCurrentCustomASRProvider(named: viewModel.credentialDrafts.asrCustomProviderName)
                }
                .buttonStyle(.bordered)
                .disabled(!isSelectedASRProviderCustom || !canSaveCustomASRProvider)
                Button("Delete Current ASR Provider", role: .destructive) {
                    _ = engine.deleteCurrentCustomASRProvider()
                }
                .buttonStyle(.bordered)
                .disabled(!isSelectedASRProviderCustom)
            }
            if !asrCustomProviderValidationMessage.isEmpty {
                Text(asrCustomProviderValidationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var isLocalASREngine: Bool {
        engine.asrEngine == .localMLX || engine.asrEngine == .localHTTPOpenAIAudio
    }

    @ViewBuilder
    private var localASRConfigurationView: some View {
        Picker("Local ASR Provider", selection: $engine.localASRProvider) {
            ForEach(LocalASRProviderOption.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.menu)

        switch engine.localASRProvider {
        case .mlxWhisper:
            Toggle("Show advanced models (.en / 2bit / fp32)", isOn: $engine.localASRShowAdvancedModels)
            TextField("Search local Whisper models", text: $viewModel.localASRModelSearch)
                .textFieldStyle(.roundedBorder)

            if localWhisperModels.isEmpty {
                Text("No matching local Whisper model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("MLX Whisper Model", selection: $engine.selectedLocalASRModelID) {
                    ForEach(localWhisperModels) { descriptor in
                        Text(descriptor.displayName).tag(descriptor.id)
                    }
                }
                .pickerStyle(.menu)
            }

            let selectedDescriptor = engine.localASRModelDescriptor()
            Menu {
                ForEach(localASRPrecisionOptions(for: selectedDescriptor), id: \.self) { precision in
                    Button {
                        applyLocalASRPrecision(precision)
                    } label: {
                        if precision == selectedDescriptor.precision {
                            Label(precision.displayName, systemImage: "checkmark")
                        } else {
                            Text(precision.displayName)
                        }
                    }
                }
            } label: {
                Label(
                    prefs.ui(
                        "选择模型量化：\(selectedDescriptor.precisionLabel)",
                        "Choose quantization: \(selectedDescriptor.precisionLabel)"
                    ),
                    systemImage: "dial.medium"
                )
            }
            .menuStyle(.borderlessButton)
            Text("Repo: \(selectedDescriptor.hfRepo)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Variant: \(selectedDescriptor.variantLabel)  •  Precision: \(selectedDescriptor.precisionLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Status: \(localWhisperStatus(for: selectedDescriptor))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(prefs.ui("模型管理", "Model Management"))
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                Button(
                    viewModel.probes.isDownloadingLocalASRModel
                        ? prefs.ui("下载中...", "Downloading...")
                        : prefs.ui("下载并预热当前模型", "Download & Warm Up")
                ) {
                    Task {
                        await downloadSelectedLocalASRModel()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.probes.isDownloadingLocalASRModel || viewModel.probes.isClearingLocalASRModelCache)

                Button(
                    viewModel.probes.isClearingLocalASRModelCache
                        ? prefs.ui("清理中...", "Clearing...")
                        : prefs.ui("清理当前模型缓存", "Clear Model Cache"),
                    role: .destructive
                ) {
                    Task {
                        await clearSelectedLocalASRModelCache()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.probes.isDownloadingLocalASRModel || viewModel.probes.isClearingLocalASRModelCache)

                Button(prefs.ui("在 Finder 中显示缓存", "Reveal Cache in Finder")) {
                    revealSelectedLocalASRModelCacheInFinder()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.probes.isDownloadingLocalASRModel || viewModel.probes.isClearingLocalASRModelCache)
            }

            if !viewModel.probes.localASRModelActionStatus.isEmpty {
                Text(viewModel.probes.localASRModelActionStatus)
                    .font(.caption)
                    .foregroundStyle(viewModel.probes.localASRModelActionStatusIsError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }

            Button(
                engine.isRefreshingLocalASRModelCatalog
                    ? prefs.ui("刷新中...", "Refreshing...")
                    : prefs.ui("刷新模型目录（Hugging Face）", "Refresh Catalog (Hugging Face)")
            ) {
                Task {
                    await engine.refreshLocalASRModelCatalog()
                }
            }
            .buttonStyle(.bordered)
            .disabled(engine.isRefreshingLocalASRModelCatalog)

            if !engine.localASRModelCatalogStatus.isEmpty {
                Text(engine.localASRModelCatalogStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .funASRParaformer,
             .senseVoice,
             .weNet,
             .whisperKitLocalServer,
             .whisperCpp,
             .fireRedASRExperimental,
             .localHTTPOpenAIAudio:
            localHTTPASRProviderConfigurationView
        }
    }

    private var localWhisperModels: [LocalASRModelDescriptor] {
        let filtered = LocalASRModelCatalog.filteredModels(
            in: engine.localASRModelDescriptors,
            includeAdvanced: engine.localASRShowAdvancedModels,
            searchQuery: viewModel.localASRModelSearch
        )
        if filtered.isEmpty {
            return [engine.localASRModelDescriptor()]
        }
        return filtered
    }

    @ViewBuilder
    private var localHTTPASRProviderConfigurationView: some View {
        let provider = engine.localASRProvider
        let isExperimental = provider.isExperimental

        Text(provider.helperText)
            .font(.caption)
            .foregroundStyle(isExperimental ? Color.orange : Color.secondary)

        if provider.supportsStreaming {
            Text(prefs.ui("该 Provider 支持流式转写能力（依赖后端实现）。", "This provider supports streaming transcription (backend dependent)."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        if provider == .weNet {
            Picker("WeNet Model Type", selection: $engine.localASRWeNetModelType) {
                ForEach(LocalASRWeNetModelType.allCases) { modelType in
                    Text(modelType.displayName).tag(modelType)
                }
            }
            .pickerStyle(.menu)
        }

        if provider == .funASRParaformer {
            Toggle("Enable VAD (FunASR)", isOn: $engine.localASRFunASRVADEnabled)
            Toggle("Enable Punctuation (FunASR)", isOn: $engine.localASRFunASRPunctuationEnabled)
        }

        if provider == .whisperCpp {
            TextField("whisper.cpp Binary Path (optional)", text: $engine.localASRWhisperCppBinaryPath)
                .textFieldStyle(.roundedBorder)
            TextField("whisper.cpp Model Path (optional)", text: $engine.localASRWhisperCppModelPath)
                .textFieldStyle(.roundedBorder)
        }

        TextField("Base URL", text: $engine.localHTTPASRBaseURL)
            .textFieldStyle(.roundedBorder)

        Picker("Model", selection: $engine.localHTTPASRModelName) {
            ForEach(localHTTPASRModelOptions(for: provider), id: \.self) { model in
                Text(model).tag(model)
            }
        }
        .pickerStyle(.menu)

        Text(
            prefs.ui(
                "适用于本机运行的 OpenAI Audio API 兼容服务（如 WhisperKit server）。",
                "For local OpenAI Audio API compatible services (for example WhisperKit server)."
            )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Text("""
        http://127.0.0.1:8000
        """)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

        Button(
            viewModel.probes.isTestingASRConnection
                ? prefs.ui("测试中...", "Testing...")
                : prefs.ui("测试 Local HTTP ASR", "Test Local HTTP ASR")
        ) {
            Task {
                await testASRConnection()
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel.probes.isTestingASRConnection)

        if !viewModel.probes.asrConnectionStatus.isEmpty {
            Text(viewModel.probes.asrConnectionStatus)
                .font(.caption)
                .foregroundStyle(viewModel.probes.asrConnectionStatusIsError ? Color.red : Color.secondary)
                .textSelection(.enabled)
        }
    }

    private func localHTTPASRModelOptions(for provider: LocalASRProviderOption) -> [String] {
        let preset = LocalASRModelCatalog.httpModelPresets(for: provider)
        return mergedModelOptions(
            preset: preset,
            discovered: viewModel.probes.discoveredASRModels,
            selected: engine.localHTTPASRModelName
        )
    }

    private func syncLocalHTTPASRModelSelection(for provider: LocalASRProviderOption) {
        let options = localHTTPASRModelOptions(for: provider)
        guard let first = options.first else { return }
        let current = engine.localHTTPASRModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty || !options.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            engine.localHTTPASRModelName = first
        }
    }

    private func localASRPrecisionOptions(for descriptor: LocalASRModelDescriptor) -> [LocalASRModelPrecision] {
        let available = Set(
            engine.localASRModelDescriptors
                .filter { item in
                    item.family == descriptor.family && item.variant == descriptor.variant
                }
                .map(\.precision)
        )
        let preferred = engine.localASRShowAdvancedModels
            ? LocalASRModelPrecision.allCases
            : LocalASRModelCatalog.preferredQuantizationsWhenAdvancedHidden
        var options = preferred.filter { available.contains($0) }
        if options.isEmpty {
            options = LocalASRModelPrecision.allCases.filter { available.contains($0) }
        } else if !options.contains(descriptor.precision), available.contains(descriptor.precision) {
            options.append(descriptor.precision)
        }
        return options
    }

    private func applyLocalASRPrecision(_ precision: LocalASRModelPrecision) {
        let current = engine.localASRModelDescriptor()
        let sameFamilyAndVariant = engine.localASRModelDescriptors.filter { descriptor in
            descriptor.family == current.family
                && descriptor.variant == current.variant
                && descriptor.precision == precision
        }
        if let target = sameFamilyAndVariant.first {
            engine.selectedLocalASRModelID = target.id
            return
        }

        let familyFallback = engine.localASRModelDescriptors.first { descriptor in
            descriptor.family == current.family
                && descriptor.precision == precision
        }
        if let target = familyFallback {
            engine.selectedLocalASRModelID = target.id
        }
    }

    private struct LocalLLMQuantizationChoice: Identifiable {
        let value: String
        let displayName: String
        var id: String { value }
    }

    private var localLLMQuantizationChoices: [LocalLLMQuantizationChoice] {
        let currentModel = engine.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentModel.isEmpty else { return [] }
        let familyKey = localLLMFamilyKey(for: currentModel)
        let sameFamilyModels = localLLMModelOptions.filter {
            localLLMFamilyKey(for: $0).caseInsensitiveCompare(familyKey) == .orderedSame
        }

        var seen = Set<String>()
        var choices: [LocalLLMQuantizationChoice] = []
        for model in sameFamilyModels {
            let value = localLLMQuantizationValue(for: model)
            guard seen.insert(value).inserted else { continue }
            choices.append(
                LocalLLMQuantizationChoice(
                    value: value,
                    displayName: localLLMQuantizationDisplayName(value)
                )
            )
        }
        if choices.isEmpty {
            let value = localLLMQuantizationValue(for: currentModel)
            choices = [LocalLLMQuantizationChoice(value: value, displayName: localLLMQuantizationDisplayName(value))]
        }
        return choices.sorted { lhs, rhs in
            let leftOrder = localLLMQuantizationSortOrder(lhs.value)
            let rightOrder = localLLMQuantizationSortOrder(rhs.value)
            if leftOrder == rightOrder {
                return lhs.value < rhs.value
            }
            return leftOrder < rightOrder
        }
    }

    private func applyLocalLLMQuantization(_ quantization: String) {
        let currentModel = engine.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let familyKey = localLLMFamilyKey(for: currentModel)
        guard !familyKey.isEmpty else { return }

        if let matched = localLLMModelOptions.first(where: { model in
            localLLMFamilyKey(for: model).caseInsensitiveCompare(familyKey) == .orderedSame
                && localLLMQuantizationValue(for: model) == quantization
        }) {
            engine.llmModel = matched
        }
    }

    private func localLLMFamilyKey(for model: String) -> String {
        var trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let suffixes = ["-8bit", "-4bit", "-2bit", "-fp16", "-fp32", "-q8", "-q4", "-int8", "-int4"]
        let lower = trimmed.lowercased()
        if let suffix = suffixes.first(where: { lower.hasSuffix($0) }) {
            trimmed = String(trimmed.dropLast(suffix.count))
        }
        return trimmed
    }

    private func localLLMQuantizationValue(for model: String) -> String {
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let suffixes: [(String, String)] = [
            ("-8bit", "8bit"),
            ("-4bit", "4bit"),
            ("-2bit", "2bit"),
            ("-fp16", "fp16"),
            ("-fp32", "fp32"),
            ("-q8", "q8"),
            ("-q4", "q4"),
            ("-int8", "int8"),
            ("-int4", "int4"),
        ]
        for (suffix, value) in suffixes {
            if lower.hasSuffix(suffix) {
                return value
            }
        }
        return "default"
    }

    private func localLLMQuantizationDisplayName(_ value: String) -> String {
        switch value {
        case "default":
            return "Default"
        case "8bit":
            return "8bit"
        case "4bit":
            return "4bit"
        case "2bit":
            return "2bit"
        case "fp16":
            return "fp16"
        case "fp32":
            return "fp32"
        case "q8":
            return "q8"
        case "q4":
            return "q4"
        case "int8":
            return "int8"
        case "int4":
            return "int4"
        default:
            return value
        }
    }

    private func localLLMQuantizationSortOrder(_ value: String) -> Int {
        switch value {
        case "default":
            return 0
        case "8bit", "q8", "int8":
            return 1
        case "4bit", "q4", "int4":
            return 2
        case "2bit":
            return 3
        case "fp16":
            return 4
        case "fp32":
            return 5
        default:
            return 99
        }
    }

    private func localWhisperStatus(for descriptor: LocalASRModelDescriptor) -> String {
        let downloaded = hasLocalWhisperCache(for: descriptor.hfRepo)
        if engine.asrEngine == .localMLX,
           engine.asrModel.caseInsensitiveCompare(descriptor.hfRepo) == .orderedSame,
           downloaded {
            return "Ready"
        }
        if downloaded {
            return "Downloaded"
        }
        return "Not downloaded"
    }

    private func hasLocalWhisperCache(for hfRepo: String) -> Bool {
        LocalASRModelCatalog.hasLocalCache(forHFRepo: hfRepo)
    }

    private func downloadSelectedLocalASRModel() async {
        guard !viewModel.probes.isDownloadingLocalASRModel else { return }
        let descriptor = engine.localASRModelDescriptor()
        viewModel.probes.isDownloadingLocalASRModel = true
        viewModel.probes.localASRModelActionStatusIsError = false
        viewModel.probes.localASRModelActionStatus = prefs.ui(
            "正在下载并预热：\(descriptor.displayName)",
            "Downloading and warming up: \(descriptor.displayName)"
        )
        defer { viewModel.probes.isDownloadingLocalASRModel = false }

        do {
            try await ensureBackendReadyForModelManagement(asrModel: descriptor.hfRepo)
            try await warmupLocalASRModelDownload(asrModel: descriptor.hfRepo)
            let downloaded = hasLocalWhisperCache(for: descriptor.hfRepo)
            viewModel.probes.localASRModelActionStatus = downloaded
                ? prefs.ui("模型已下载并可用：\(descriptor.displayName)", "Model downloaded and ready: \(descriptor.displayName)")
                : prefs.ui("预热请求已完成，但未检测到本地缓存目录。", "Warm-up request completed, but local cache directory was not detected.")
            viewModel.probes.localASRModelActionStatusIsError = !downloaded
        } catch {
            viewModel.probes.localASRModelActionStatusIsError = true
            viewModel.probes.localASRModelActionStatus = prefs.ui(
                "模型下载失败：\(error.localizedDescription)",
                "Model download failed: \(error.localizedDescription)"
            )
        }
    }

    private func clearSelectedLocalASRModelCache() async {
        guard !viewModel.probes.isClearingLocalASRModelCache else { return }
        let descriptor = engine.localASRModelDescriptor()
        viewModel.probes.isClearingLocalASRModelCache = true
        viewModel.probes.localASRModelActionStatusIsError = false
        viewModel.probes.localASRModelActionStatus = prefs.ui(
            "正在清理模型缓存：\(descriptor.displayName)",
            "Clearing model cache: \(descriptor.displayName)"
        )
        defer { viewModel.probes.isClearingLocalASRModelCache = false }

        do {
            let removedCount = try LocalASRModelCatalog.clearLocalCache(forHFRepo: descriptor.hfRepo)
            if removedCount > 0 {
                viewModel.probes.localASRModelActionStatus = prefs.ui(
                    "已清理 \(removedCount) 处缓存目录。",
                    "Cleared \(removedCount) cache director\(removedCount == 1 ? "y" : "ies")."
                )
            } else {
                viewModel.probes.localASRModelActionStatus = prefs.ui(
                    "未发现可清理的本地缓存。",
                    "No local cache directory was found."
                )
            }
            viewModel.probes.localASRModelActionStatusIsError = false
        } catch {
            viewModel.probes.localASRModelActionStatusIsError = true
            viewModel.probes.localASRModelActionStatus = prefs.ui(
                "清理失败：\(error.localizedDescription)",
                "Failed to clear cache: \(error.localizedDescription)"
            )
        }
    }

    private func revealSelectedLocalASRModelCacheInFinder() {
        let descriptor = engine.localASRModelDescriptor()
        let candidates = LocalASRModelCatalog.cacheDirectories(forHFRepo: descriptor.hfRepo)
        let fileManager = FileManager.default
        if let existing = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.activateFileViewerSelecting([existing])
            viewModel.probes.localASRModelActionStatus = prefs.ui(
                "已在 Finder 中显示缓存目录。",
                "Opened cache directory in Finder."
            )
            viewModel.probes.localASRModelActionStatusIsError = false
            return
        }

        if let fallback = candidates.first?.deletingLastPathComponent() {
            NSWorkspace.shared.activateFileViewerSelecting([fallback])
            viewModel.probes.localASRModelActionStatus = prefs.ui(
                "当前模型尚未下载，已打开 Hugging Face 缓存目录。",
                "Model is not downloaded yet. Opened Hugging Face cache directory."
            )
            viewModel.probes.localASRModelActionStatusIsError = false
            return
        }

        viewModel.probes.localASRModelActionStatus = prefs.ui(
            "未找到可显示的缓存目录。",
            "No cache directory was found."
        )
        viewModel.probes.localASRModelActionStatusIsError = true
    }

    private func ensureBackendReadyForModelManagement(asrModel: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            BackendManager.shared.startIfNeeded(
                asrModel: asrModel,
                llmModel: engine.llmModel,
                idleTimeoutSeconds: prefs.memoryTimeoutSeconds
            ) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func warmupLocalASRModelDownload(asrModel: String) async throws {
        let sampleURL = try makeTemporarySilentWAVFile(durationMS: 320)
        defer { try? FileManager.default.removeItem(at: sampleURL) }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/asr/transcribe")!, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "audio_path": sampleURL.path,
                "inference_audio_profile": "standard",
                "asr_model": asrModel,
                "llm_model": engine.llmModel,
                "audio_enhancement_enabled": false,
            ]
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalASRModelManagementError.invalidBackendResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LocalASRModelManagementError.backendRequestFailed(statusCode: http.statusCode, body: body)
        }
    }

    private func makeTemporarySilentWAVFile(durationMS: Int) throws -> URL {
        let sampleRate = 16_000
        let channelCount = 1
        let bitsPerSample = 16
        let bytesPerFrame = channelCount * bitsPerSample / 8
        let sampleCount = max(1, (durationMS * sampleRate) / 1_000)
        let dataChunkSize = sampleCount * bytesPerFrame

        var wavData = Data()
        wavData.append(Data("RIFF".utf8))
        appendLittleEndianModelMgmt(UInt32(36 + dataChunkSize), to: &wavData)
        wavData.append(Data("WAVE".utf8))
        wavData.append(Data("fmt ".utf8))
        appendLittleEndianModelMgmt(UInt32(16), to: &wavData)
        appendLittleEndianModelMgmt(UInt16(1), to: &wavData) // PCM
        appendLittleEndianModelMgmt(UInt16(channelCount), to: &wavData)
        appendLittleEndianModelMgmt(UInt32(sampleRate), to: &wavData)
        appendLittleEndianModelMgmt(UInt32(sampleRate * bytesPerFrame), to: &wavData)
        appendLittleEndianModelMgmt(UInt16(bytesPerFrame), to: &wavData)
        appendLittleEndianModelMgmt(UInt16(bitsPerSample), to: &wavData)
        wavData.append(Data("data".utf8))
        appendLittleEndianModelMgmt(UInt32(dataChunkSize), to: &wavData)
        wavData.append(Data(repeating: 0, count: dataChunkSize))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosttype-local-asr-\(UUID().uuidString).wav")
        try wavData.write(to: url, options: .atomic)
        return url
    }

    private func appendLittleEndianModelMgmt(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private func appendLittleEndianModelMgmt(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private var llmEngineSection: some View {
        Section(prefs.ui("LLM 引擎", "LLM Engine")) {
            Picker("Runtime", selection: llmRuntimeSelectionBinding) {
                Text("Local").tag(EngineRuntimeSelection.local)
                Text("Cloud").tag(EngineRuntimeSelection.cloud)
            }
            .pickerStyle(.segmented)
            Text(
                engine.llmEngine == .localMLX
                    ? prefs.ui("文本仅在本机处理。", "Text is processed locally on this Mac.")
                    : prefs.ui("文本会发送到所选服务生成结果。", "Text is sent to the selected service for generation.")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if engine.llmEngine != .localMLX {
                Picker("Engine", selection: llmProviderSelectionBinding) {
                    ForEach(availableCloudLLMProviders) { option in
                        Text(llmProviderDisplayName(option)).tag(option.id)
                    }
                    Divider()
                    Text(prefs.ui("自定义…", "Custom…")).tag(Self.customLLMProviderMenuID)
                    Text(prefs.ui("管理自定义…", "Manage Custom…")).tag(Self.manageCustomLLMProviderMenuID)
                }
            }
            llmEngineConfigurationView
        }
    }

    @ViewBuilder
    private var llmEngineConfigurationView: some View {
        switch engine.llmEngine {
        case .localMLX:
            LocalLLMInlineConfigView(
                catalog: engine.localLLMCatalog,
                engine: engine,
                prefs: prefs
            )
        case .openAI:
            cloudLLMCommonFields
            SecureField("OpenAI API Key", text: credentialBinding(\.llmOpenAIKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: "Save OpenAI LLM Key") {
                saveKey(viewModel.credentialDrafts.llmOpenAIKey, for: .llmOpenAI, providerLabel: "OpenAI LLM")
            }
        case .openAICompatible:
            cloudLLMCommonFields
            SecureField("OpenAI-compatible API Key", text: credentialBinding(\.llmOpenAICompatibleKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: "Save OpenAI-Compatible LLM Key") {
                saveKey(
                    viewModel.credentialDrafts.llmOpenAICompatibleKey,
                    for: .llmOpenAICompatible,
                    providerLabel: "OpenAI-compatible LLM"
                )
            }
        case .azureOpenAI:
            cloudLLMCommonFields
            TextField("API Version (e.g. 2024-02-01)", text: $engine.cloudLLMAPIVersion)
                .textFieldStyle(.roundedBorder)
            SecureField("Azure OpenAI API Key", text: credentialBinding(\.llmAzureOpenAIKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: "Save Azure OpenAI Key") {
                saveKey(viewModel.credentialDrafts.llmAzureOpenAIKey, for: .llmAzureOpenAI, providerLabel: "Azure OpenAI LLM")
            }
        case .anthropic:
            cloudLLMCommonFields
            SecureField("Anthropic API Key", text: credentialBinding(\.llmAnthropicKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: "Save Anthropic LLM Key") {
                saveKey(viewModel.credentialDrafts.llmAnthropicKey, for: .llmAnthropic, providerLabel: "Anthropic LLM")
            }
        case .gemini:
            cloudLLMCommonFields
            SecureField("Gemini API Key", text: credentialBinding(\.llmGeminiKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: "Save Gemini LLM Key") {
                saveKey(viewModel.credentialDrafts.llmGeminiKey, for: .llmGemini, providerLabel: "Gemini LLM")
            }
        case .deepSeek:
            cloudLLMCommonFields
            SecureField("DeepSeek API Key", text: credentialBinding(\.llmDeepSeekKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: "Save DeepSeek LLM Key") {
                saveKey(viewModel.credentialDrafts.llmDeepSeekKey, for: .llmDeepSeek, providerLabel: "DeepSeek LLM")
            }
        case .groq:
            cloudLLMCommonFields
            SecureField("Groq API Key", text: credentialBinding(\.llmGroqKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: "Save Groq LLM Key") {
                saveKey(viewModel.credentialDrafts.llmGroqKey, for: .llmGroq, providerLabel: "Groq LLM")
            }
        case .customOpenAICompatible:
            cloudLLMCommonFields
            TextField("Custom LLM Provider Name", text: credentialBinding(\.llmCustomProviderName))
                .textFieldStyle(.roundedBorder)
            SecureField("Custom LLM API Key", text: credentialBinding(\.llmCustomProviderKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: "Save Custom LLM Key") {
                saveKeyRef(
                    viewModel.credentialDrafts.llmCustomProviderKey,
                    keyRef: engine.cloudLLMApiKeyRef,
                    providerLabel: "Custom LLM"
                )
            }
            HStack(spacing: 8) {
                Button("Save As New LLM Provider") {
                    let fallback = "Custom LLM \(engine.customLLMProviders.count + 1)"
                    _ = engine.saveCurrentLLMAsCustomProvider(
                        named: viewModel.credentialDrafts.llmCustomProviderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? fallback
                            : viewModel.credentialDrafts.llmCustomProviderName
                    )
                }
                .buttonStyle(.bordered)
                .disabled(!canSaveCustomLLMProvider)
                Button("Update Current LLM Provider") {
                    _ = engine.updateCurrentCustomLLMProvider(named: viewModel.credentialDrafts.llmCustomProviderName)
                }
                .buttonStyle(.bordered)
                .disabled(!isSelectedLLMProviderCustom || !canSaveCustomLLMProvider)
                Button("Delete Current LLM Provider", role: .destructive) {
                    _ = engine.deleteCurrentCustomLLMProvider()
                }
                .buttonStyle(.bordered)
                .disabled(!isSelectedLLMProviderCustom)
            }
            if !llmCustomProviderValidationMessage.isEmpty {
                Text(llmCustomProviderValidationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var networkPrivacySection: some View {
        Section(prefs.ui("网络与隐私", "Network & Privacy")) {
            Toggle(
                prefs.ui("隐私模式（脱敏云端错误日志）", "Privacy Mode (redacted cloud error logs)"),
                isOn: $engine.privacyModeEnabled
            )
            Text(
                engine.privacyModeEnabled
                    ? prefs.ui(
                        "当前为隐私模式：控制台只输出状态码与摘要，不输出完整响应正文。",
                        "Privacy mode is on: console only shows status codes and summaries, not full response bodies."
                    )
                    : prefs.ui(
                        "当前为调试模式：控制台会输出完整响应正文，请勿在敏感场景开启。",
                        "Debug mode is on: console may show full response bodies. Avoid using it for sensitive data."
                    )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var credentialsSection: some View {
        Section(prefs.ui("凭据管理", "Credentials Management")) {
            Toggle(
                prefs.ui("开启钥匙串诊断日志（仅调试）", "Enable Keychain diagnostic logs (debug only)"),
                isOn: $engine.keychainDiagnosticsEnabled
            )
            LabeledContent(
                prefs.ui("已保存凭据", "Saved Credentials"),
                value: "\(viewModel.keychain.savedCredentialCount)"
            )
            credentialActionButtons

            if !viewModel.keychain.healthStatus.isEmpty {
                Text(viewModel.keychain.healthStatus)
                    .font(.caption)
                    .foregroundStyle(viewModel.keychain.needsAttention ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
            if !viewModel.keychain.guidance.isEmpty {
                Text(viewModel.keychain.guidance)
                    .font(.caption)
                    .foregroundStyle(viewModel.keychain.needsAttention ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
            }
            if viewModel.keychain.needsAttention {
                Text(
                    prefs.ui(
                        "若仍反复弹窗：打开“钥匙串访问”，搜索 com.codeandchill.ghosttype，删除旧条目后回到应用重新保存 API Key。",
                        "If prompts persist: open Keychain Access, search com.codeandchill.ghosttype, delete stale entries, then return to the app and save API keys again."
                    )
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private var credentialActionButtons: some View {
        HStack(spacing: 10) {
            Button(prefs.ui("检查凭据状态", "Check Credential Status")) {
                refreshCredentialStatus()
            }
            .buttonStyle(.bordered)
            .disabled(credentialsBusy)

            Button(
                viewModel.keychain.isResettingAllCredentials
                    ? prefs.ui("重置中...", "Resetting...")
                    : prefs.ui("一键删除全部密钥", "One-Click Delete All Keys"),
                role: .destructive
            ) {
                resetAllCredentials()
            }
            .buttonStyle(.bordered)
            .disabled(credentialsBusy)
        }
    }

    private var engineCombinationSection: some View {
        Section(prefs.ui("组合路由", "Routing Combination")) {
            let asrLocal = engine.asrEngine == .localMLX || engine.asrEngine == .localHTTPOpenAIAudio
            Text(
                prefs.ui(
                    "当前组合：ASR \(asrLocal ? "Local" : "Cloud") + LLM \(engine.llmEngine == .localMLX ? "Local" : "Cloud")",
                    "Current route: ASR \(asrLocal ? "Local" : "Cloud") + LLM \(engine.llmEngine == .localMLX ? "Local" : "Cloud")"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var keychainStatusSection: some View {
        if !viewModel.keychain.status.isEmpty {
            Section {
                Text(viewModel.keychain.status)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func handleAppear() {
        resetCredentialInputFields()
        loadCredentialInputFieldsFromKeychain(overwriteExisting: true)
        viewModel.localASRModelSearch = ""
        viewModel.probes.localASRModelActionStatus = ""
        viewModel.probes.localASRModelActionStatusIsError = false
        viewModel.credentialDrafts.asrCustomProviderName = engine.selectedASRProvider?.displayName ?? ""
        viewModel.credentialDrafts.llmCustomProviderName = engine.selectedLLMProvider?.displayName ?? ""
        viewModel.keychain.savedCredentialCount = AppKeychain.shared.savedSecretCount()
        viewModel.keychain.healthStatus = prefs.ui(
            "凭据保存在本地加密文件中。进入设置页会自动回填已保存密钥。",
            "Credentials are stored locally. Saved keys are auto-filled when Settings opens."
        )
        viewModel.keychain.guidance = prefs.ui(
            "退出设置页时会自动保存你新输入的非空密钥。点击“一键删除全部密钥”可立即清空；也可留空后点击对应 Save 删除单条凭据。",
            "Non-empty keys you typed are auto-saved when leaving Settings. Use One-Click Delete All Keys to wipe all, or save an empty value to delete one credential."
        )
        viewModel.keychain.needsAttention = false
        applyASRDefaults(for: engine.asrEngine, force: false)
        applyDeepgramDefaults(force: false)
        applyLLMDefaults(for: engine.llmEngine, force: false)
        normalizeASRLanguageSelection()
        syncLocalLLMModelSelection()
        if engine.localASRProvider.runtimeKind == .localHTTP {
            syncLocalHTTPASRModelSelection(for: engine.localASRProvider)
        }
        syncASRModelPickerOptions()
        syncLLMModelPickerOptions()
        if engine.localASRModelCatalogStatus.isEmpty {
            Task {
                await engine.refreshLocalASRModelCatalog()
            }
        }
    }

    private func handleASREngineChange(_ value: ASREngineOption) {
        applyASRDefaults(for: value, force: false)
        applyDeepgramDefaults(force: false)
        normalizeASRLanguageSelection()
        loadCredentialInputFieldsFromKeychain(overwriteExisting: false)
        viewModel.probes.asrConnectionStatus = ""
        viewModel.probes.asrConnectionStatusIsError = false
        syncASRModelPickerOptions()
    }

    private func handleLLMEngineChange(_ value: LLMEngineOption) {
        applyLLMDefaults(for: value, force: false)
        loadCredentialInputFieldsFromKeychain(overwriteExisting: false)
        viewModel.probes.llmConnectionStatus = ""
        viewModel.probes.llmConnectionStatusIsError = false
        syncLocalLLMModelSelection()
        syncLLMModelPickerOptions()
    }

    private func scheduleCredentialAutosave() {
        credentialAutosaveWorkItem?.cancel()
        let item = DispatchWorkItem { [self] in
            persistCredentialInputFieldsToKeychain()
        }
        credentialAutosaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    private func flushCredentialAutosave() {
        guard let item = credentialAutosaveWorkItem else { return }
        item.cancel()
        credentialAutosaveWorkItem = nil
    }

    private func persistCredentialsOnLifecycleEvent() {
        flushCredentialAutosave()
        persistCredentialInputFieldsToKeychain()
    }

}
