import AppKit
import Foundation

@MainActor
extension EnginesSettingsPane {
    private typealias CredentialDraftKeyPath = WritableKeyPath<EnginesSettingsPaneViewModel.CredentialDrafts, String>

    private var credentialDraftMappings: [(CredentialDraftKeyPath, APISecretKey)] {
        [
            (\.asrOpenAIKey, .asrOpenAI),
            (\.asrDeepgramKey, .asrDeepgram),
            (\.asrAssemblyAIKey, .asrAssemblyAI),
            (\.asrGroqKey, .asrGroq),
            (\.llmOpenAIKey, .llmOpenAI),
            (\.llmOpenAICompatibleKey, .llmOpenAICompatible),
            (\.llmAzureOpenAIKey, .llmAzureOpenAI),
            (\.llmAnthropicKey, .llmAnthropic),
            (\.llmGeminiKey, .llmGemini),
            (\.llmDeepSeekKey, .llmDeepSeek),
            (\.llmGroqKey, .llmGroq),
        ]
    }

    func resetAllCredentials() {
        guard !viewModel.keychain.isResettingAllCredentials else { return }
        viewModel.keychain.isResettingAllCredentials = true
        viewModel.keychain.status = prefs.ui("正在删除所有已保存凭据...", "Removing all saved credentials...")
        DispatchQueue.global(qos: .userInitiated).async {
            let report = AppKeychain.shared.deleteAllSecrets()
            let count = AppKeychain.shared.savedSecretCount()
            DispatchQueue.main.async {
                self.viewModel.keychain.isResettingAllCredentials = false
                self.viewModel.keychain.savedCredentialCount = count
                self.viewModel.keychain.needsAttention = report.requiresAttention
                self.viewModel.keychain.healthStatus = report.summaryText
                self.viewModel.keychain.guidance = report.guidance.joined(separator: "\n")
                self.viewModel.keychain.status = self.prefs.ui("全部凭据已重置。", "All credentials were reset.")
                self.resetCredentialInputFields()
            }
        }
    }

    func resetCredentialInputFields() {
        viewModel.credentialDrafts.asrOpenAIKey = ""
        viewModel.credentialDrafts.asrDeepgramKey = ""
        viewModel.credentialDrafts.asrAssemblyAIKey = ""
        viewModel.credentialDrafts.asrGroqKey = ""
        viewModel.credentialDrafts.llmOpenAIKey = ""
        viewModel.credentialDrafts.llmOpenAICompatibleKey = ""
        viewModel.credentialDrafts.llmAzureOpenAIKey = ""
        viewModel.credentialDrafts.llmAnthropicKey = ""
        viewModel.credentialDrafts.llmGeminiKey = ""
        viewModel.credentialDrafts.llmDeepSeekKey = ""
        viewModel.credentialDrafts.llmGroqKey = ""
        viewModel.credentialDrafts.asrCustomProviderKey = ""
        viewModel.credentialDrafts.llmCustomProviderKey = ""
    }

    func loadCredentialInputFieldsFromKeychain(overwriteExisting: Bool = true) {
        for (keyPath, key) in credentialDraftMappings {
            let value = readSavedKey(key)
            setCredentialDraft(keyPath, value: value, overwriteExisting: overwriteExisting)
        }
        loadCustomCredentialInputFieldsFromKeychain(overwriteExisting: overwriteExisting)
        viewModel.keychain.savedCredentialCount = AppKeychain.shared.savedSecretCount()
    }

    func loadCustomCredentialInputFieldsFromKeychain(overwriteExisting: Bool = true) {
        let asrCustomValue = readSavedKeyRef(engine.cloudASRApiKeyRef)
        let llmCustomValue = readSavedKeyRef(engine.cloudLLMApiKeyRef)
        setCredentialDraft(\.asrCustomProviderKey, value: asrCustomValue, overwriteExisting: overwriteExisting)
        setCredentialDraft(\.llmCustomProviderKey, value: llmCustomValue, overwriteExisting: overwriteExisting)
    }

    func persistCredentialInputFieldsToKeychain() {
        var encounteredError = false
        for (keyPath, key) in credentialDraftMappings {
            let value = viewModel.credentialDrafts[keyPath: keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            do {
                try AppKeychain.shared.setSecret(value, for: key)
            } catch {
                encounteredError = true
            }
        }

        let asrCustomValue = viewModel.credentialDrafts.asrCustomProviderKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let llmCustomValue = viewModel.credentialDrafts.llmCustomProviderKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !asrCustomValue.isEmpty {
            encounteredError = !persistCustomSecret(asrCustomValue, forRef: engine.cloudASRApiKeyRef) || encounteredError
        }
        if !llmCustomValue.isEmpty {
            encounteredError = !persistCustomSecret(llmCustomValue, forRef: engine.cloudLLMApiKeyRef) || encounteredError
        }

        viewModel.keychain.savedCredentialCount = AppKeychain.shared.savedSecretCount()
        if encounteredError {
            viewModel.keychain.needsAttention = true
            viewModel.keychain.status = prefs.ui(
                "部分凭据自动保存失败，请检查日志并重试保存。",
                "Some credentials could not be auto-saved. Please check logs and save again."
            )
        }
    }

    func readSavedKey(_ key: APISecretKey) -> String {
        let value = (try? AppKeychain.shared.getSecret(for: key, policy: .noUserInteraction)) ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func readSavedKeyRef(_ rawRef: String) -> String {
        let trimmedRef = rawRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRef.isEmpty else { return "" }
        let value = (try? AppKeychain.shared.getSecret(forRef: trimmedRef, policy: .noUserInteraction)) ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func setCredentialDraft(
        _ keyPath: CredentialDraftKeyPath,
        value: String,
        overwriteExisting: Bool
    ) {
        let current = viewModel.credentialDrafts[keyPath: keyPath]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard overwriteExisting || current.isEmpty else { return }
        viewModel.credentialDrafts[keyPath: keyPath] = value
    }

    private func persistCustomSecret(_ value: String, forRef rawRef: String) -> Bool {
        let trimmedRef = rawRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRef.isEmpty else { return true }
        do {
            try AppKeychain.shared.setSecret(value, forRef: trimmedRef)
            return true
        } catch {
            return false
        }
    }
}
