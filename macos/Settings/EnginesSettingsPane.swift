import AppKit
import SwiftUI

// MARK: - Download Progress Model

struct ModelDownloadProgress: Equatable {
    var repoID: String = ""
    var status: String = "idle"  // idle, downloading, verifying, complete, error
    var progress: Double = 0.0  // 0-100
    var downloadedBytes: Int = 0
    var totalBytes: Int = 0
    var currentFile: String = ""
    var speedMbps: Double = 0.0
    var etaSeconds: Int = 0
    var errorMessage: String = ""
    
    var isDownloading: Bool {
        status == "downloading" || status == "verifying"
    }
    
    var isComplete: Bool {
        status == "complete"
    }
    
    var isFailed: Bool {
        status == "error"
    }
    
    var formattedDownloadedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(downloadedBytes), countStyle: .file)
    }
    
    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
    }
    
    var formattedSpeed: String {
        String(format: "%.1f MB/s", speedMbps)
    }
    
    var formattedETA: String {
        let minutes = etaSeconds / 60
        let seconds = etaSeconds % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

// MARK: - Fake Download Progress View
/// A progress bar that simulates download progress without knowing total size
/// Uses a logarithmic scale that slows down as it approaches 90%
struct FakeDownloadProgressView: View {
    let downloadedBytes: Int
    @State private var displayProgress: Double = 0.0
    
    // Model sizes for reference (approximate)
    private let modelSizeReference: Double = 1_500_000_000  // ~1.5GB as reference
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                    
                    // Progress bar
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * (displayProgress / 100))
                        .animation(.easeInOut(duration: 0.3), value: displayProgress)
                }
            }
            .frame(height: 6)
        }
        .onAppear {
            updateProgress()
        }
        .onChange(of: downloadedBytes) { _, _ in
            updateProgress()
        }
    }
    
    private func updateProgress() {
        // Calculate fake progress: logarithmic scale that never reaches 100%
        // This gives a realistic feeling without knowing actual total size
        let ratio = Double(downloadedBytes) / modelSizeReference
        // Use logarithmic scale: progress grows fast at start, slows down later
        // Max out at 90% until download actually completes
        let targetProgress = min(90.0, 20.0 * log10(1 + ratio * 10))
        
        withAnimation(.easeInOut(duration: 0.5)) {
            displayProgress = targetProgress
        }
    }
}

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
        // LLM Model Management
        var isDownloadingLocalLLMModel = false
        var isClearingLocalLLMModelCache = false
        var localLLMModelActionStatus = ""
        var localLLMModelActionStatusIsError = false
    }

    @Published var credentialDrafts = CredentialDrafts()
    @Published var keychain = KeychainUIState()
    @Published var probes = ProbeUIState()
    @Published var localASRModelSearch = ""
    @Published var pendingDownloadASRModelID: String = ""
    @Published var downloadProgress = ModelDownloadProgress()
    // LLM Model Management
    @Published var localLLMModelSearch = ""
    @Published var pendingDownloadLLMModelID: String = ""
    @Published var llmDownloadProgress = ModelDownloadProgress()
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
            Picker(prefs.ui("运行时", "Runtime"), selection: asrRuntimeSelectionBinding) {
                Text(prefs.ui("本地", "Local")).tag(EngineRuntimeSelection.local)
                Text(prefs.ui("云端", "Cloud")).tag(EngineRuntimeSelection.cloud)
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
                Picker(prefs.ui("引擎", "Engine"), selection: asrProviderSelectionBinding) {
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
            SecureField(prefs.ui("OpenAI API 密钥", "OpenAI API Key"), text: credentialBinding(\.asrOpenAIKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: prefs.ui("保存 OpenAI ASR 密钥", "Save OpenAI ASR Key")) {
                saveKey(viewModel.credentialDrafts.asrOpenAIKey, for: .asrOpenAI, providerLabel: "OpenAI ASR")
            }
        case .deepgram:
            cloudASRCommonFields
            SecureField(prefs.ui("Deepgram API 密钥", "Deepgram API Key"), text: credentialBinding(\.asrDeepgramKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: prefs.ui("保存 Deepgram ASR 密钥", "Save Deepgram ASR Key")) {
                saveKey(viewModel.credentialDrafts.asrDeepgramKey, for: .asrDeepgram, providerLabel: "Deepgram ASR")
            }
        case .assemblyAI:
            cloudASRCommonFields
            SecureField(prefs.ui("AssemblyAI API 密钥", "AssemblyAI API Key"), text: credentialBinding(\.asrAssemblyAIKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: prefs.ui("保存 AssemblyAI ASR 密钥", "Save AssemblyAI ASR Key")) {
                saveKey(viewModel.credentialDrafts.asrAssemblyAIKey, for: .asrAssemblyAI, providerLabel: "AssemblyAI ASR")
            }
        case .groq:
            cloudASRCommonFields
            SecureField(prefs.ui("Groq API 密钥", "Groq API Key"), text: credentialBinding(\.asrGroqKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: prefs.ui("保存 Groq ASR 密钥", "Save Groq ASR Key")) {
                saveKey(viewModel.credentialDrafts.asrGroqKey, for: .asrGroq, providerLabel: "Groq ASR")
            }
        case .geminiMultimodal:
            cloudASRCommonFields
            Text(prefs.ui("Gemini ASR 复用 LLM 设置中的 Gemini API 密钥。", "Gemini ASR reuses the Gemini API key from LLM settings."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            SecureField(prefs.ui("Gemini API 密钥（共享）", "Gemini API Key (Shared)"), text: credentialBinding(\.llmGeminiKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: prefs.ui("保存共享 Gemini 密钥", "Save Shared Gemini Key")) {
                saveKey(viewModel.credentialDrafts.llmGeminiKey, for: .llmGemini, providerLabel: "Gemini (Shared)")
            }
        case .customOpenAICompatible:
            cloudASRCommonFields
            TextField(prefs.ui("自定义 ASR 提供者名称", "Custom ASR Provider Name"), text: credentialBinding(\.asrCustomProviderName))
                .textFieldStyle(.roundedBorder)
            SecureField(prefs.ui("自定义 ASR API 密钥", "Custom ASR API Key"), text: credentialBinding(\.asrCustomProviderKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: prefs.ui("保存自定义 ASR 密钥", "Save Custom ASR Key")) {
                saveKeyRef(
                    viewModel.credentialDrafts.asrCustomProviderKey,
                    keyRef: engine.cloudASRApiKeyRef,
                    providerLabel: "Custom ASR"
                )
            }
            HStack(spacing: 8) {
                Button(prefs.ui("保存为新 ASR 提供者", "Save As New ASR Provider")) {
                    let fallback = "Custom ASR \(engine.customASRProviders.count + 1)"
                    _ = engine.saveCurrentASRAsCustomProvider(
                        named: viewModel.credentialDrafts.asrCustomProviderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? fallback
                            : viewModel.credentialDrafts.asrCustomProviderName
                    )
                }
                .buttonStyle(.bordered)
                .disabled(!canSaveCustomASRProvider)
                Button(prefs.ui("更新当前 ASR 提供者", "Update Current ASR Provider")) {
                    _ = engine.updateCurrentCustomASRProvider(named: viewModel.credentialDrafts.asrCustomProviderName)
                }
                .buttonStyle(.bordered)
                .disabled(!isSelectedASRProviderCustom || !canSaveCustomASRProvider)
                Button(prefs.ui("删除当前 ASR 提供者", "Delete Current ASR Provider"), role: .destructive) {
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
        Picker(prefs.ui("提供者", "Provider"), selection: $engine.localASRProvider) {
            ForEach(LocalASRProviderOption.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.menu)

        switch engine.localASRProvider {
        case .mlxWhisper:
            let selectedDescriptor = engine.localASRModelDescriptor()
            
            // MARK: - Active Configuration Section
            Text(prefs.ui("当前配置", "Active Configuration"))
                .font(.headline.weight(.semibold))
            
            if localInstalledASRModels.isEmpty {
                Text(prefs.ui("没有已安装的模型。请使用下方的模型管理器下载。", "No installed models. Use Model Manager below to download."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker(prefs.ui("选择模型（仅已安装）", "Select Model (installed only)"), selection: $engine.selectedLocalASRModelID) {
                    ForEach(localInstalledASRModels) { descriptor in
                        Text(descriptor.displayName).tag(descriptor.id)
                    }
                }
                .pickerStyle(.menu)
            }
            
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
                HStack {
                    Text(prefs.ui("选择量化：", "Choose quantization:"))
                    Text(selectedDescriptor.precisionLabel)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                }
            }
            .menuStyle(.borderlessButton)
            
            // Status Box
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle()
                            .fill(localWhisperStatusColor(for: selectedDescriptor))
                            .frame(width: 8, height: 8)
                        Text(prefs.ui("状态：", "Status:") + " \(localWhisperStatus(for: selectedDescriptor))")
                            .font(.caption)
                    }
                    Text(prefs.ui("仓库：", "Repo:") + " \(selectedDescriptor.hfRepo)")
                        .font(.caption)
                        .textSelection(.enabled)
                    Text(prefs.ui("变体：", "Variant:") + " \(selectedDescriptor.variantLabel)")
                        .font(.caption)
                    Text(prefs.ui("精度：", "Precision:") + " \(selectedDescriptor.precisionLabel)")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            
            
            // MARK: - Model Manager Section
            Text(prefs.ui("模型管理器", "Model Manager"))
                .font(.headline.weight(.semibold))
            
            TextField(prefs.ui("搜索本地 Whisper 模型", "Search Local Whisper Models"), text: $viewModel.localASRModelSearch)
                .textFieldStyle(.roundedBorder)
            
            HStack {
                Button(prefs.ui("刷新列表", "Refresh List")) {
                    viewModel.localASRModelSearch = ""
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Toggle(prefs.ui("显示高级模型（.en / fp32）", "Show advanced models (.en / fp32)"), isOn: $engine.localASRShowAdvancedModels)
                    .toggleStyle(.checkbox)
            }
            
            // Download New Model - separate from active model selection
            Picker(prefs.ui("下载新模型", "Download New Model"), selection: $viewModel.pendingDownloadASRModelID) {
                ForEach(downloadableLocalASRModels) { descriptor in
                    HStack {
                        Text(descriptor.displayName)
                        if hasLocalWhisperCache(for: descriptor.hfRepo) {
                            Text("(installed)")
                        }
                    }.tag(descriptor.id)
                }
            }
            .pickerStyle(.menu)
            .onAppear {
                if viewModel.pendingDownloadASRModelID.isEmpty {
                    viewModel.pendingDownloadASRModelID = downloadableLocalASRModels.first?.id ?? ""
                }
            }
            
            HStack(spacing: 8) {
                Button(
                    viewModel.downloadProgress.isDownloading
                        ? "Downloading..."
                        : "Download Model"
                ) {
                    Task {
                        await downloadPendingLocalASRModel()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.downloadProgress.isDownloading || viewModel.probes.isClearingLocalASRModelCache || viewModel.pendingDownloadASRModelID.isEmpty)
            }
            
            // Download Progress UI - always show during download
            if viewModel.downloadProgress.isDownloading || viewModel.downloadProgress.status == "verifying" || viewModel.downloadProgress.isComplete || viewModel.downloadProgress.isFailed {
                VStack(alignment: .leading, spacing: 8) {
                    // Status text with icon
                    HStack {
                        if viewModel.downloadProgress.status == "verifying" {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text(prefs.ui("正在验证文件...", "Verifying files..."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if viewModel.downloadProgress.isDownloading {
                            if viewModel.downloadProgress.downloadedBytes > 0 {
                                // Has actual download progress - show static icon
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundStyle(.blue)
                            } else {
                                // Still connecting - show spinning
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                            Text(viewModel.downloadProgress.currentFile.isEmpty ? prefs.ui("正在下载...", "Downloading...") : viewModel.downloadProgress.currentFile)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else if viewModel.downloadProgress.isComplete {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(prefs.ui("下载完成！", "Download complete!"))
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else if viewModel.downloadProgress.isFailed {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(viewModel.downloadProgress.errorMessage.isEmpty ? prefs.ui("下载失败", "Download failed") : viewModel.downloadProgress.errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    
                    // Progress bar - show during downloading or verifying
                    if viewModel.downloadProgress.isDownloading || viewModel.downloadProgress.status == "verifying" {
                        VStack(alignment: .leading, spacing: 4) {
                            if viewModel.downloadProgress.status == "verifying" {
                                // Verifying - indeterminate
                                ProgressView()
                                    .progressViewStyle(.linear)
                                Text(prefs.ui("正在验证完整性...", "Verifying integrity..."))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if viewModel.downloadProgress.downloadedBytes == 0 {
                                // No data yet - indeterminate progress bar
                                ProgressView()
                                    .progressViewStyle(.linear)
                                Text(prefs.ui("正在连接 Hugging Face...", "Connecting to Hugging Face..."))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                // Has download data - show simulated progress bar (no percentage)
                                FakeDownloadProgressView(downloadedBytes: viewModel.downloadProgress.downloadedBytes)
                                
                                // Download stats only (no percentage)
                                HStack(spacing: 16) {
                                    Text(viewModel.downloadProgress.formattedDownloadedSize)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    
                                    if viewModel.downloadProgress.speedMbps > 0 {
                                        Text(viewModel.downloadProgress.formattedSpeed)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.15))
                )
            }
            
            // Local Cache List
            Text(prefs.ui("本地缓存：", "Local Cache:"))
                .font(.headline.weight(.semibold))
            
            ForEach(localInstalledASRModels, id: \.id) { descriptor in
                HStack {
                    Text(descriptor.displayName)
                    Spacer()
                    Button(prefs.ui("删除", "Delete")) {
                        Task {
                            engine.selectedLocalASRModelID = descriptor.id
                            await clearSelectedLocalASRModelCache()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.probes.isDownloadingLocalASRModel || viewModel.probes.isClearingLocalASRModelCache)
                }
            }
            
            // Cache Actions
            HStack(spacing: 8) {
                Button(prefs.ui("在 Finder 中显示缓存", "Reveal Cache in Finder")) {
                    revealSelectedLocalASRModelCacheInFinder()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.probes.isDownloadingLocalASRModel || viewModel.probes.isClearingLocalASRModelCache)
                
                Button(prefs.ui("清除模型缓存", "Clear Model Cache")) {
                    Task {
                        await clearSelectedLocalASRModelCache()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.probes.isDownloadingLocalASRModel || viewModel.probes.isClearingLocalASRModelCache)
            }
            
            Button(
                engine.isRefreshingLocalASRModelCatalog
                    ? prefs.ui("正在刷新...", "Refreshing...")
                    : prefs.ui("刷新模型目录 (Hugging Face)", "Refresh Catalog (Hugging Face)")
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
        case .mlxQwen3ASR:
            let selectedDescriptor = qwen3ASRDescriptor()
            
            // MARK: - Active Configuration Section
            Text(prefs.ui("当前配置", "Active Configuration"))
                .font(.headline.weight(.semibold))
            
            if localInstalledQwen3ASRModels.isEmpty {
                Text(prefs.ui("没有已安装的 Qwen3 ASR 模型。请使用下方的模型管理器下载。", "No installed Qwen3 ASR models. Use Model Manager below to download."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker(prefs.ui("选择模型（仅已安装）", "Select Model (installed only)"), selection: $engine.selectedLocalASRModelID) {
                    ForEach(localInstalledQwen3ASRModels) { descriptor in
                        Text(descriptor.displayName).tag(descriptor.id)
                    }
                }
                .pickerStyle(.menu)
            }
            
            // Status Box
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle()
                            .fill(qwen3ASRStatusColor(for: selectedDescriptor))
                            .frame(width: 8, height: 8)
                        Text(prefs.ui("状态：", "Status:") + " \(qwen3ASRStatus(for: selectedDescriptor))")
                            .font(.caption)
                    }
                    Text(prefs.ui("仓库：", "Repo:") + " \(selectedDescriptor.hfRepo)")
                        .font(.caption)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            
            // Prompt optimization toggle
            Toggle(
                prefs.ui("使用 Prompt 优化", "Use Prompt Optimization"),
                isOn: $engine.qwen3ASRUsePrompt
            )
            
            Text(
                prefs.ui(
                    "启用后，转录结果将使用个性化词典和写作风格进行优化。",
                    "When enabled, transcription results will be optimized with personalization dictionary and writing style."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            
            // MARK: - Model Manager Section
            Text(prefs.ui("模型管理器", "Model Manager"))
                .font(.headline.weight(.semibold))
            
            // Download New Model
            Picker(prefs.ui("下载新模型", "Download New Model"), selection: $viewModel.pendingDownloadASRModelID) {
                ForEach(downloadableQwen3ASRModels) { descriptor in
                    HStack {
                        Text(descriptor.displayName)
                        if hasLocalWhisperCache(for: descriptor.hfRepo) {
                            Text("(installed)")
                        }
                    }.tag(descriptor.id)
                }
            }
            .pickerStyle(.menu)
            .onAppear {
                if viewModel.pendingDownloadASRModelID.isEmpty || !downloadableQwen3ASRModels.contains(where: { $0.id == viewModel.pendingDownloadASRModelID }) {
                    viewModel.pendingDownloadASRModelID = downloadableQwen3ASRModels.first?.id ?? ""
                }
            }
            
            HStack(spacing: 8) {
                Button(
                    viewModel.downloadProgress.isDownloading
                        ? "Downloading..."
                        : "Download Model"
                ) {
                    Task {
                        await downloadPendingLocalASRModel()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.downloadProgress.isDownloading || viewModel.probes.isClearingLocalASRModelCache || viewModel.pendingDownloadASRModelID.isEmpty)
            }
            
            // Download Progress UI
            if viewModel.downloadProgress.isDownloading || viewModel.downloadProgress.status == "verifying" || viewModel.downloadProgress.isComplete || viewModel.downloadProgress.isFailed {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if viewModel.downloadProgress.status == "verifying" {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text(prefs.ui("正在验证文件...", "Verifying files..."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if viewModel.downloadProgress.isDownloading {
                            if viewModel.downloadProgress.downloadedBytes > 0 {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundStyle(.blue)
                            } else {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                            Text(viewModel.downloadProgress.currentFile.isEmpty ? prefs.ui("正在下载...", "Downloading...") : viewModel.downloadProgress.currentFile)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else if viewModel.downloadProgress.isComplete {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(prefs.ui("下载完成！", "Download complete!"))
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else if viewModel.downloadProgress.isFailed {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(viewModel.downloadProgress.errorMessage.isEmpty ? prefs.ui("下载失败", "Download failed") : viewModel.downloadProgress.errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    
                    if viewModel.downloadProgress.isDownloading || viewModel.downloadProgress.status == "verifying" {
                        VStack(alignment: .leading, spacing: 4) {
                            if viewModel.downloadProgress.status == "verifying" {
                                ProgressView()
                                    .progressViewStyle(.linear)
                                Text(prefs.ui("正在验证完整性...", "Verifying integrity..."))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if viewModel.downloadProgress.downloadedBytes == 0 {
                                ProgressView()
                                    .progressViewStyle(.linear)
                                Text(prefs.ui("正在连接 Hugging Face...", "Connecting to Hugging Face..."))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                FakeDownloadProgressView(downloadedBytes: viewModel.downloadProgress.downloadedBytes)
                                HStack(spacing: 16) {
                                    Text(viewModel.downloadProgress.formattedDownloadedSize)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if viewModel.downloadProgress.speedMbps > 0 {
                                        Text(viewModel.downloadProgress.formattedSpeed)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.15))
                )
            }
            
            // Local Cache List
            Text(prefs.ui("本地缓存：", "Local Cache:"))
                .font(.headline.weight(.semibold))
            
            ForEach(localInstalledQwen3ASRModels, id: \.id) { descriptor in
                HStack {
                    Text(descriptor.displayName)
                    Spacer()
                    Button(prefs.ui("删除", "Delete")) {
                        Task {
                            engine.selectedLocalASRModelID = descriptor.id
                            await clearSelectedLocalASRModelCache()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.probes.isDownloadingLocalASRModel || viewModel.probes.isClearingLocalASRModelCache)
                }
            }
            
            // Cache Actions
            HStack(spacing: 8) {
                Button(prefs.ui("在 Finder 中显示缓存", "Reveal Cache in Finder")) {
                    revealSelectedLocalASRModelCacheInFinder()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.probes.isDownloadingLocalASRModel || viewModel.probes.isClearingLocalASRModelCache)
                
                Button(prefs.ui("清除模型缓存", "Clear Model Cache")) {
                    Task {
                        await clearSelectedLocalASRModelCache()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.probes.isDownloadingLocalASRModel || viewModel.probes.isClearingLocalASRModelCache)
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

    private var downloadableLocalASRModels: [LocalASRModelDescriptor] {
        let all = LocalASRModelCatalog.filteredModels(
            in: engine.localASRModelDescriptors,
            includeAdvanced: engine.localASRShowAdvancedModels,
            searchQuery: ""
        )
        return all
    }

    private var localInstalledASRModels: [LocalASRModelDescriptor] {
        engine.localASRModelDescriptors.filter { descriptor in
            hasLocalWhisperCache(for: descriptor.hfRepo)
        }
    }

    // MARK: - Qwen3 ASR Helper Variables
    private var qwen3ASRModels: [LocalASRModelDescriptor] {
        engine.localASRModelDescriptors.filter { descriptor in
            descriptor.hfRepo.lowercased().contains("qwen3-asr")
        }
    }

    private var downloadableQwen3ASRModels: [LocalASRModelDescriptor] {
        qwen3ASRModels
    }

    private var localInstalledQwen3ASRModels: [LocalASRModelDescriptor] {
        qwen3ASRModels.filter { descriptor in
            hasLocalWhisperCache(for: descriptor.hfRepo)
        }
    }

    private func qwen3ASRDescriptor() -> LocalASRModelDescriptor {
        if let descriptor = qwen3ASRModels.first(where: { $0.id == engine.selectedLocalASRModelID }) {
            return descriptor
        }
        return qwen3ASRModels.first ?? LocalASRModelDescriptor(
            id: "mlx-community/Qwen3-ASR-0.6B-4bit",
            displayName: "Qwen3 ASR 0.6B · 4bit",
            hfRepo: "mlx-community/Qwen3-ASR-0.6B-4bit",
            family: .small,
            variant: .multilingual,
            precision: .bit4,
            isAdvanced: false,
            estimatedDiskMB: nil,
            estimatedRAMMB: nil
        )
    }

    private func qwen3ASRStatus(for descriptor: LocalASRModelDescriptor) -> String {
        hasLocalWhisperCache(for: descriptor.hfRepo) ? "Ready" : "Not Downloaded"
    }

    private func qwen3ASRStatusColor(for descriptor: LocalASRModelDescriptor) -> Color {
        let status = qwen3ASRStatus(for: descriptor)
        switch status {
        case "Ready":
            return .green
        default:
            return .gray
        }
    }

    private func localWhisperStatusColor(for descriptor: LocalASRModelDescriptor) -> Color {
        let status = localWhisperStatus(for: descriptor)
        switch status {
        case "Ready":
            return .green
        case "Downloaded":
            return .orange
        default:
            return .gray
        }
    }

    private func estimatedModelSize(for descriptor: LocalASRModelDescriptor) -> String? {
        let sizes: [LocalASRModelFamily: [LocalASRModelPrecision: String]] = [
            .tiny: [.default: "~40MB", .bit8: "~20MB", .bit4: "~12MB", .fp32: "~150MB"],
            .base: [.default: "~75MB", .bit8: "~40MB", .bit4: "~25MB", .fp32: "~300MB"],
            .small: [.default: "~150MB", .bit8: "~75MB", .bit4: "~45MB", .fp32: "~600MB"],
            .medium: [.default: "~500MB", .bit8: "~250MB", .bit4: "~150MB", .fp32: "~2GB"],
            .large: [.default: "~1.5GB", .bit8: "~750MB", .bit4: "~450MB", .fp32: "~6GB"],
            .largeV2: [.default: "~1.5GB", .bit8: "~750MB", .bit4: "~450MB", .fp32: "~6GB"],
            .largeV3: [.default: "~1.5GB", .bit8: "~750MB", .bit4: "~450MB", .fp32: "~6GB"],
        ]
        return sizes[descriptor.family]?[descriptor.precision]
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

    private func downloadPendingLocalASRModel() async {
        guard !viewModel.downloadProgress.isDownloading else { return }
        let modelID = viewModel.pendingDownloadASRModelID
        guard !modelID.isEmpty else { return }
        
        let descriptor = engine.localASRModelDescriptor(for: modelID)
        viewModel.probes.isDownloadingLocalASRModel = true
        viewModel.probes.localASRModelActionStatusIsError = false
        
        // Reset progress with downloading status
        viewModel.downloadProgress = ModelDownloadProgress(
            repoID: descriptor.hfRepo,
            status: "downloading",
            currentFile: "Starting download..."
        )
        
        defer { 
            viewModel.probes.isDownloadingLocalASRModel = false
        }

        do {
            // Ensure backend is running
            try await ensureBackendReadyForModelManagement(asrModel: descriptor.hfRepo)
            
            // Start SSE download
            let repoID = descriptor.hfRepo
            let encodedRepoID = repoID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? repoID
            guard let url = URL(string: "http://127.0.0.1:8765/models/download?repo_id=\(encodedRepoID)") else {
                throw URLError(.badURL)
            }
            
            var request = URLRequest(url: url, timeoutInterval: 3600)  // 1 hour timeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }
            
            // Parse SSE events
            for try await line in bytes.lines {
                print("[download] Received line: \(line)", terminator: "")
                if line.hasPrefix("data: ") {
                    let jsonString = String(line.dropFirst(6))
                    if let data = jsonString.data(using: .utf8),
                       let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        print("[download] Parsed event: \(event)")
                        await MainActor.run {
                            handleDownloadEvent(event, descriptor: descriptor)
                        }
                    }
                }
            }
            
            print("[download] SSE stream ended")
            
            // Check if download was successful
            let downloaded = hasLocalWhisperCache(for: descriptor.hfRepo)
            if downloaded {
                viewModel.downloadProgress.status = "complete"
                viewModel.downloadProgress.progress = 100.0
                viewModel.probes.localASRModelActionStatus = "Model downloaded: \(descriptor.displayName)"
                
                // Show success for 3 seconds, then reset
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if viewModel.downloadProgress.status == "complete" {
                        viewModel.downloadProgress = ModelDownloadProgress()
                    }
                }
            } else {
                viewModel.downloadProgress.status = "error"
                viewModel.downloadProgress.errorMessage = "Download completed, but local cache not detected."
                viewModel.probes.localASRModelActionStatus = "Download completed, but local cache not detected."
                viewModel.probes.localASRModelActionStatusIsError = true
            }
        } catch {
            print("[download] Error: \(error)")
            viewModel.downloadProgress.status = "error"
            viewModel.downloadProgress.errorMessage = error.localizedDescription
            viewModel.probes.localASRModelActionStatusIsError = true
            viewModel.probes.localASRModelActionStatus = "Download failed: \(error.localizedDescription)"
        }
    }
    
    private func handleDownloadEvent(_ event: [String: Any], descriptor: LocalASRModelDescriptor) {
        guard let eventType = event["event"] as? String else { return }
        print("[download] Handling event: \(eventType) - \(event)")
        
        switch eventType {
        case "start":
            viewModel.downloadProgress.status = "downloading"
            viewModel.downloadProgress.repoID = event["repo_id"] as? String ?? descriptor.hfRepo
            viewModel.downloadProgress.currentFile = "Starting download..."
            
        case "info":
            viewModel.downloadProgress.currentFile = "Discovering files..."
            
        case "progress":
            if let progress = event["progress"] as? Double, progress > viewModel.downloadProgress.progress {
                viewModel.downloadProgress.progress = progress
            }
            if let downloaded = event["downloaded_bytes"] as? Int {
                viewModel.downloadProgress.downloadedBytes = downloaded
            }
            if let total = event["total_bytes"] as? Int, total > 0 {
                viewModel.downloadProgress.totalBytes = total
            }
            if let file = event["current_file"] as? String, !file.isEmpty {
                viewModel.downloadProgress.currentFile = file
            }
            if let speed = event["speed_mbps"] as? Double {
                viewModel.downloadProgress.speedMbps = speed
            }
            if let eta = event["eta_seconds"] as? Int {
                viewModel.downloadProgress.etaSeconds = eta
            }
            
        case "verifying":
            viewModel.downloadProgress.status = "verifying"
            viewModel.downloadProgress.currentFile = "Verifying files..."
            
        case "complete":
            viewModel.downloadProgress.status = "complete"
            viewModel.downloadProgress.progress = 100.0
            viewModel.probes.localASRModelActionStatus = "Model downloaded: \(descriptor.displayName)"
            print("[download] Complete event received")
            // Refresh model list after download
            engine.selectedLocalASRModelID = descriptor.id
            
        case "error":
            viewModel.downloadProgress.status = "error"
            viewModel.downloadProgress.errorMessage = event["message"] as? String ?? "Unknown error"
            viewModel.probes.localASRModelActionStatusIsError = true
            viewModel.probes.localASRModelActionStatus = "Download failed: \(viewModel.downloadProgress.errorMessage)"
            
        default:
            print("[download] Unknown event type: \(eventType)")
            break
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
            Picker(prefs.ui("运行时", "Runtime"), selection: llmRuntimeSelectionBinding) {
                Text(prefs.ui("本地", "Local")).tag(EngineRuntimeSelection.local)
                Text(prefs.ui("云端", "Cloud")).tag(EngineRuntimeSelection.cloud)
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
                Picker(prefs.ui("引擎", "Engine"), selection: llmProviderSelectionBinding) {
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
                prefs: prefs,
                viewModel: viewModel
            )
        case .openAI:
            cloudLLMCommonFields
            SecureField(prefs.ui("OpenAI API 密钥", "OpenAI API Key"), text: credentialBinding(\.llmOpenAIKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: prefs.ui("保存 OpenAI LLM 密钥", "Save OpenAI LLM Key")) {
                saveKey(viewModel.credentialDrafts.llmOpenAIKey, for: .llmOpenAI, providerLabel: "OpenAI LLM")
            }
        case .openAICompatible:
            cloudLLMCommonFields
            SecureField(prefs.ui("OpenAI 兼容 API 密钥", "OpenAI-compatible API Key"), text: credentialBinding(\.llmOpenAICompatibleKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: prefs.ui("保存 OpenAI 兼容 LLM 密钥", "Save OpenAI-Compatible LLM Key")) {
                saveKey(
                    viewModel.credentialDrafts.llmOpenAICompatibleKey,
                    for: .llmOpenAICompatible,
                    providerLabel: "OpenAI-compatible LLM"
                )
            }
        case .azureOpenAI:
            cloudLLMCommonFields
            TextField(prefs.ui("API 版本（如 2024-02-01）", "API Version (e.g. 2024-02-01)"), text: $engine.cloudLLMAPIVersion)
                .textFieldStyle(.roundedBorder)
            SecureField(prefs.ui("Azure OpenAI API 密钥", "Azure OpenAI API Key"), text: credentialBinding(\.llmAzureOpenAIKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: prefs.ui("保存 Azure OpenAI 密钥", "Save Azure OpenAI Key")) {
                saveKey(viewModel.credentialDrafts.llmAzureOpenAIKey, for: .llmAzureOpenAI, providerLabel: "Azure OpenAI LLM")
            }
        case .anthropic:
            cloudLLMCommonFields
            SecureField(prefs.ui("Anthropic API 密钥", "Anthropic API Key"), text: credentialBinding(\.llmAnthropicKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: prefs.ui("保存 Anthropic LLM 密钥", "Save Anthropic LLM Key")) {
                saveKey(viewModel.credentialDrafts.llmAnthropicKey, for: .llmAnthropic, providerLabel: "Anthropic LLM")
            }
        case .gemini:
            cloudLLMCommonFields
            SecureField(prefs.ui("Gemini API 密钥", "Gemini API Key"), text: credentialBinding(\.llmGeminiKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: prefs.ui("保存 Gemini LLM 密钥", "Save Gemini LLM Key")) {
                saveKey(viewModel.credentialDrafts.llmGeminiKey, for: .llmGemini, providerLabel: "Gemini LLM")
            }
        case .deepSeek:
            cloudLLMCommonFields
            SecureField(prefs.ui("DeepSeek API 密钥", "DeepSeek API Key"), text: credentialBinding(\.llmDeepSeekKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: prefs.ui("保存 DeepSeek LLM 密钥", "Save DeepSeek LLM Key")) {
                saveKey(viewModel.credentialDrafts.llmDeepSeekKey, for: .llmDeepSeek, providerLabel: "DeepSeek LLM")
            }
        case .groq:
            cloudLLMCommonFields
            SecureField(prefs.ui("Groq API 密钥", "Groq API Key"), text: credentialBinding(\.llmGroqKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: prefs.ui("保存 Groq LLM 密钥", "Save Groq LLM Key")) {
                saveKey(viewModel.credentialDrafts.llmGroqKey, for: .llmGroq, providerLabel: "Groq LLM")
            }
        case .ollama:
            cloudLLMCommonFields
            Text("No API key required. Make sure Ollama is running locally.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .lmStudio:
            cloudLLMCommonFields
            Text("No API key required. Make sure LM Studio server is running locally.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .customOpenAICompatible:
            cloudLLMCommonFields
            TextField(prefs.ui("自定义 LLM 提供者名称", "Custom LLM Provider Name"), text: credentialBinding(\.llmCustomProviderName))
                .textFieldStyle(.roundedBorder)
            SecureField(prefs.ui("自定义 LLM API 密钥", "Custom LLM API Key"), text: credentialBinding(\.llmCustomProviderKey))
                .textFieldStyle(.roundedBorder)
            saveButton(label: prefs.ui("保存自定义 LLM 密钥", "Save Custom LLM Key")) {
                saveKeyRef(
                    viewModel.credentialDrafts.llmCustomProviderKey,
                    keyRef: engine.cloudLLMApiKeyRef,
                    providerLabel: "Custom LLM"
                )
            }
            HStack(spacing: 8) {
                Button(prefs.ui("保存为新 LLM 提供者", "Save As New LLM Provider")) {
                    let fallback = "Custom LLM \(engine.customLLMProviders.count + 1)"
                    _ = engine.saveCurrentLLMAsCustomProvider(
                        named: viewModel.credentialDrafts.llmCustomProviderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? fallback
                            : viewModel.credentialDrafts.llmCustomProviderName
                    )
                }
                .buttonStyle(.bordered)
                .disabled(!canSaveCustomLLMProvider)
                Button(prefs.ui("更新当前 LLM 提供者", "Update Current LLM Provider")) {
                    _ = engine.updateCurrentCustomLLMProvider(named: viewModel.credentialDrafts.llmCustomProviderName)
                }
                .buttonStyle(.bordered)
                .disabled(!isSelectedLLMProviderCustom || !canSaveCustomLLMProvider)
                Button(prefs.ui("删除当前 LLM 提供者", "Delete Current LLM Provider"), role: .destructive) {
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
