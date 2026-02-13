import Foundation
import SwiftUI

@MainActor
extension EnginesSettingsPane {
    func applyASRDefaults(for option: ASREngineOption, force: Bool) {
        guard option != .localMLX, option != .localHTTPOpenAIAudio else { return }
        if option == .customOpenAICompatible {
            return
        }
        if option == .deepgram {
            if force || engine.cloudASRBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                engine.cloudASRBaseURL = engine.deepgram.region.defaultHTTPSBaseURL
            }
        } else {
            if force || engine.cloudASRBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                engine.cloudASRBaseURL = option.defaultBaseURL
            }
            if force || engine.cloudASRModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                engine.cloudASRModelName = option.defaultModelName
            }
            if force || engine.cloudASRLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                engine.cloudASRLanguage = defaultASRLanguage(for: option)
            }
        }
    }

    func normalizeASRLanguageSelection() {
        if engine.asrEngine == .deepgram {
            let normalized = DeepgramConfig.normalizedLanguageCode(engine.cloudASRLanguage)
            if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                engine.cloudASRLanguage = defaultASRLanguage(for: .deepgram)
                return
            }
            if engine.cloudASRLanguage != normalized {
                engine.cloudASRLanguage = normalized
            }
            return
        }

        let fallbackLanguage = defaultASRLanguage(for: engine.asrEngine)
        let normalized = engine.cloudASRLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else {
            engine.cloudASRLanguage = fallbackLanguage
            return
        }
        let supportedLanguageCodes = Self.supportedASRLanguageCodes
        guard supportedLanguageCodes.contains(normalized) else {
            engine.cloudASRLanguage = fallbackLanguage
            return
        }
        if engine.cloudASRLanguage != normalized {
            engine.cloudASRLanguage = normalized
        }
    }

    func defaultASRLanguage(for option: ASREngineOption) -> String {
        option == .deepgram ? DeepgramLanguageStrategy.chineseSimplified.rawValue : "auto"
    }

    func applyDeepgramDefaults(force: Bool) {
        guard engine.asrEngine == .deepgram else { return }

        let currentBase = engine.cloudASRBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentBase.isEmpty {
            engine.cloudASRBaseURL = engine.deepgram.region.defaultHTTPSBaseURL
        } else if let inferredRegion = inferDeepgramRegion(from: currentBase),
                  inferredRegion != engine.deepgram.region {
            engine.deepgram.region = inferredRegion
        }

        let normalizedLanguage = DeepgramConfig.normalizedLanguageCode(engine.cloudASRLanguage)
        if force || engine.cloudASRLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            engine.cloudASRLanguage = normalizedLanguage
        } else if engine.cloudASRLanguage != normalizedLanguage {
            engine.cloudASRLanguage = normalizedLanguage
        }

        applyDeepgramModelRecommendation(force: force || engine.cloudASRModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func applyDeepgramModelRecommendation(force: Bool) {
        guard engine.asrEngine == .deepgram else { return }
        let recommended = DeepgramConfig.recommendedModel(for: engine.deepgramResolvedLanguage)
        let current = engine.cloudASRModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if force || current.isEmpty {
            engine.cloudASRModelName = recommended
            return
        }

        let lower = current.lowercased()
        if lower.contains("nova-2") || lower.contains("nova-3") {
            engine.cloudASRModelName = recommended
        }
    }

    func applyDeepgramChinesePreset() {
        engine.cloudASRLanguage = DeepgramLanguageStrategy.chineseSimplified.rawValue
        engine.cloudASRModelName = "nova-2"
        engine.deepgram.smartFormat = true
        engine.deepgram.punctuate = true
        engine.deepgram.paragraphs = true
        engine.deepgram.endpointingEnabled = true
        engine.deepgram.endpointingMS = DeepgramConfig.defaultEndpointingMS
        engine.deepgram.interimResults = true
        engine.deepgram.diarize = false
    }

    func applyDeepgramEnglishMeetingPreset() {
        engine.cloudASRLanguage = DeepgramLanguageStrategy.englishUS.rawValue
        engine.cloudASRModelName = "nova-3"
        engine.deepgram.smartFormat = true
        engine.deepgram.punctuate = true
        engine.deepgram.paragraphs = true
        engine.deepgram.endpointingEnabled = true
        engine.deepgram.endpointingMS = DeepgramConfig.defaultEndpointingMS
        engine.deepgram.interimResults = true
        engine.deepgram.diarize = true
    }

    func inferDeepgramRegion(from baseURL: String) -> DeepgramRegionOption? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URLComponents(string: candidate)?.host?.lowercased() else { return nil }
        switch host {
        case DeepgramRegionOption.eu.host:
            return .eu
        case DeepgramRegionOption.standard.host:
            return .standard
        default:
            return nil
        }
    }

    func applyLLMDefaults(for option: LLMEngineOption, force: Bool) {
        guard option != .localMLX else { return }
        if option == .customOpenAICompatible {
            return
        }
        if force || engine.cloudLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            engine.cloudLLMBaseURL = option.defaultBaseURL
        }
        if force || engine.cloudLLMModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            engine.cloudLLMModelName = option.defaultModelName
        }
        if option == .azureOpenAI, (force || engine.cloudLLMAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            engine.cloudLLMAPIVersion = "2024-02-01"
        }
    }

    func saveButton(label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.borderedProminent)
            .cornerRadius(8)
            .shadow(radius: 2, y: 1)
    }

    func saveKey(_ rawValue: String, for key: APISecretKey, providerLabel: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if value.isEmpty {
                try AppKeychain.shared.deleteSecret(for: key)
                viewModel.keychain.status = "\(providerLabel) key removed."
            } else {
                try AppKeychain.shared.setSecret(value, for: key)
                viewModel.keychain.status = "\(providerLabel) key saved."
            }
            viewModel.keychain.savedCredentialCount = AppKeychain.shared.savedSecretCount()
            viewModel.keychain.healthStatus = prefs.ui(
                "凭据更新完成。如需诊断，请点击\"检查凭据状态\"。",
                "Credential updated. Click \"Check Credential Status\" for diagnostics."
            )
            viewModel.keychain.needsAttention = false
        } catch {
            viewModel.keychain.status = "Credential operation failed: \(error.localizedDescription)"
            viewModel.keychain.needsAttention = true
        }
    }

    func saveKeyRef(_ rawValue: String, keyRef: String, providerLabel: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRef = keyRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRef.isEmpty else {
            viewModel.keychain.status = "\(providerLabel) key reference is empty."
            viewModel.keychain.needsAttention = true
            return
        }

        do {
            if value.isEmpty {
                try AppKeychain.shared.deleteSecret(forRef: trimmedRef)
                viewModel.keychain.status = "\(providerLabel) key removed."
            } else {
                try AppKeychain.shared.setSecret(value, forRef: trimmedRef)
                viewModel.keychain.status = "\(providerLabel) key saved."
            }
            viewModel.keychain.savedCredentialCount = AppKeychain.shared.savedSecretCount()
            viewModel.keychain.healthStatus = prefs.ui(
                "凭据更新完成。如需诊断，请点击\"检查凭据状态\"。",
                "Credential updated. Click \"Check Credential Status\" for diagnostics."
            )
            viewModel.keychain.needsAttention = false
        } catch {
            viewModel.keychain.status = "Credential operation failed: \(error.localizedDescription)"
            viewModel.keychain.needsAttention = true
        }
    }

    func refreshCredentialStatus() {
        let report = AppKeychain.shared.runSelfCheck()
        viewModel.keychain.savedCredentialCount = AppKeychain.shared.savedSecretCount()
        viewModel.keychain.needsAttention = report.requiresAttention
        viewModel.keychain.healthStatus = report.summaryText
        var guidance = report.guidance
        if engine.keychainDiagnosticsEnabled {
            guidance.append(report.runtimeIdentity.summaryText)
        }
        viewModel.keychain.guidance = guidance.joined(separator: "\n")
    }

}

@MainActor
extension EnginesSettingsPane {
    var availableCloudASRProviders: [ASRProviderProfile] {
        engine.availableASRProviders.filter { $0.engine != .localMLX && $0.engine != .localHTTPOpenAIAudio }
    }

    var availableCloudLLMProviders: [LLMProviderProfile] {
        engine.availableLLMProviders.filter { $0.engine != .localMLX }
    }

    var asrRuntimeSelectionBinding: Binding<EngineRuntimeSelection> {
        Binding(
            get: {
                switch engine.asrEngine {
                case .localMLX, .localHTTPOpenAIAudio:
                    return .local
                default:
                    return .cloud
                }
            },
            set: { runtime in
                switch runtime {
                case .local:
                    engine.asrEngine = engine.localASRProvider.asrEngine
                case .cloud:
                    let fallbackID = EngineProviderDefaults.ASR.defaultProviderID(for: .openAIWhisper)
                    let providerID = engine.normalizedASRProviderID(engine.selectedASRProviderID, fallbackID: fallbackID)
                    engine.applyASRProviderSelection(id: providerID)
                }
            }
        )
    }

    var llmRuntimeSelectionBinding: Binding<EngineRuntimeSelection> {
        Binding(
            get: { engine.llmEngine == .localMLX ? .local : .cloud },
            set: { runtime in
                switch runtime {
                case .local:
                    engine.llmEngine = .localMLX
                case .cloud:
                    let fallbackID = EngineProviderDefaults.LLM.defaultProviderID(for: .openAI)
                    let providerID = engine.normalizedLLMProviderID(engine.selectedLLMProviderID, fallbackID: fallbackID)
                    engine.applyLLMProviderSelection(id: providerID)
                }
            }
        )
    }

    var asrProviderSelectionBinding: Binding<String> {
        Binding<String>(
            get: {
                let fallbackID = EngineProviderDefaults.ASR.defaultProviderID(for: .openAIWhisper)
                return engine.normalizedASRProviderID(engine.selectedASRProviderID, fallbackID: fallbackID)
            },
            set: { selectedID in
                if selectedID == Self.customASRProviderMenuID {
                    startCustomASRCreation()
                    return
                }
                if selectedID == Self.manageCustomASRProviderMenuID {
                    openCustomASRManager()
                    return
                }
                engine.applyASRProviderSelection(id: selectedID)
            }
        )
    }

    var llmProviderSelectionBinding: Binding<String> {
        Binding<String>(
            get: {
                let fallbackID = EngineProviderDefaults.LLM.defaultProviderID(for: .openAI)
                return engine.normalizedLLMProviderID(engine.selectedLLMProviderID, fallbackID: fallbackID)
            },
            set: { selectedID in
                if selectedID == Self.customLLMProviderMenuID {
                    startCustomLLMCreation()
                    return
                }
                if selectedID == Self.manageCustomLLMProviderMenuID {
                    openCustomLLMManager()
                    return
                }
                engine.applyLLMProviderSelection(id: selectedID)
            }
        )
    }

    func asrProviderDisplayName(_ provider: ASRProviderProfile) -> String {
        guard provider.type == .custom else { return provider.displayName }
        let suffix = prefs.ui("（自定义）", " (Custom)")
        return "\(provider.displayName)\(suffix)"
    }

    func llmProviderDisplayName(_ provider: LLMProviderProfile) -> String {
        guard provider.type == .custom else { return provider.displayName }
        let suffix = prefs.ui("（自定义）", " (Custom)")
        return "\(provider.displayName)\(suffix)"
    }

    var isSelectedASRProviderCustom: Bool {
        engine.selectedASRProvider?.type == .custom
    }

    var isSelectedLLMProviderCustom: Bool {
        engine.selectedLLMProvider?.type == .custom
    }

    var canSaveCustomASRProvider: Bool {
        asrCustomProviderValidationMessage.isEmpty
    }

    var canSaveCustomLLMProvider: Bool {
        llmCustomProviderValidationMessage.isEmpty
    }

    var asrCustomProviderValidationMessage: String {
        let baseURL = engine.cloudASRBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.isEmpty || !isProviderBaseURLValid(baseURL) {
            return prefs.ui(
                "Base URL 无效，请使用示例格式：https://api.example.com 或 wss://api.example.com",
                "Invalid Base URL. Use a valid URL such as https://api.example.com or wss://api.example.com."
            )
        }
        if !hasAtLeastOneModel(modelName: engine.cloudASRModelName, catalogRaw: engine.cloudASRModelCatalog) {
            return prefs.ui(
                "模型列表不能为空，请填写 Models 或 Default Model。",
                "Models cannot be empty. Provide Models or a Default Model."
            )
        }
        return ""
    }

    var llmCustomProviderValidationMessage: String {
        let baseURL = engine.cloudLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.isEmpty || !isProviderBaseURLValid(baseURL) {
            return prefs.ui(
                "Base URL 无效，请使用示例格式：https://api.example.com",
                "Invalid Base URL. Use a valid URL such as https://api.example.com."
            )
        }
        if !hasAtLeastOneModel(modelName: engine.cloudLLMModelName, catalogRaw: engine.cloudLLMModelCatalog) {
            return prefs.ui(
                "模型列表不能为空，请填写 Models 或 Default Model。",
                "Models cannot be empty. Provide Models or a Default Model."
            )
        }
        return ""
    }

    func startCustomASRCreation() {
        engine.applyASRProviderSelection(id: "builtin.asr.custom-openai-compatible")
        viewModel.credentialDrafts.asrCustomProviderName = "Custom ASR \(engine.customASRProviders.count + 1)"
        viewModel.probes.asrConnectionStatusIsError = false
        viewModel.probes.asrConnectionStatus = prefs.ui(
            "已进入自定义 ASR 创建模式。填写字段后点击“Save As New ASR Provider”。",
            "Custom ASR creation mode is active. Fill fields then click “Save As New ASR Provider”."
        )
    }

    func openCustomASRManager() {
        if let first = engine.customASRProviders.first {
            engine.applyASRProviderSelection(id: first.id)
            viewModel.credentialDrafts.asrCustomProviderName = first.displayName
            viewModel.probes.asrConnectionStatusIsError = false
            viewModel.probes.asrConnectionStatus = prefs.ui(
                "已切换到自定义 ASR。可编辑后点击“Update Current ASR Provider”或删除。",
                "Switched to a custom ASR provider. Edit and click “Update Current ASR Provider” or delete."
            )
            return
        }
        startCustomASRCreation()
    }

    func startCustomLLMCreation() {
        engine.applyLLMProviderSelection(id: "builtin.llm.custom-openai-compatible")
        viewModel.credentialDrafts.llmCustomProviderName = "Custom LLM \(engine.customLLMProviders.count + 1)"
        viewModel.probes.llmConnectionStatusIsError = false
        viewModel.probes.llmConnectionStatus = prefs.ui(
            "已进入自定义 LLM 创建模式。填写字段后点击“Save As New LLM Provider”。",
            "Custom LLM creation mode is active. Fill fields then click “Save As New LLM Provider”."
        )
    }

    func openCustomLLMManager() {
        if let first = engine.customLLMProviders.first {
            engine.applyLLMProviderSelection(id: first.id)
            viewModel.credentialDrafts.llmCustomProviderName = first.displayName
            viewModel.probes.llmConnectionStatusIsError = false
            viewModel.probes.llmConnectionStatus = prefs.ui(
                "已切换到自定义 LLM。可编辑后点击“Update Current LLM Provider”或删除。",
                "Switched to a custom LLM provider. Edit and click “Update Current LLM Provider” or delete."
            )
            return
        }
        startCustomLLMCreation()
    }

    func hasAtLeastOneModel(modelName: String, catalogRaw: String) -> Bool {
        let preferred = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty {
            return true
        }
        let parsed = catalogRaw
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return !parsed.isEmpty
    }

    func isProviderBaseURLValid(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty else {
            return false
        }
        return ["http", "https", "ws", "wss"].contains(scheme)
    }
}
