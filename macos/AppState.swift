import Combine
import Foundation

@MainActor
@dynamicMemberLookup
final class AppState: ObservableObject {
    static let shared = AppState()

    let engine: EngineConfig
    let prefs: UserPreferences
    let runtime: RuntimeState
    let context: ContextRoutingState

    private var moduleCancellables = Set<AnyCancellable>()
    private lazy var promptStore = PromptTemplateStore()
    private var promptStoreBound = false

    var prompts: PromptTemplateStore {
        ensurePromptStore()
    }

    private init() {
        Self.migrateLegacyPrefixIfNeeded()
        engine = EngineConfig()
        prefs = UserPreferences()
        runtime = RuntimeState()
        context = ContextRoutingState()
        bridgeModuleChanges()
    }

    subscript<T>(dynamicMember keyPath: KeyPath<EngineConfig, T>) -> T {
        engine[keyPath: keyPath]
    }

    subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<EngineConfig, T>) -> T {
        get { engine[keyPath: keyPath] }
        set { engine[keyPath: keyPath] = newValue }
    }

    subscript<T>(dynamicMember keyPath: KeyPath<UserPreferences, T>) -> T {
        prefs[keyPath: keyPath]
    }

    subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<UserPreferences, T>) -> T {
        get { prefs[keyPath: keyPath] }
        set { prefs[keyPath: keyPath] = newValue }
    }

    subscript<T>(dynamicMember keyPath: KeyPath<RuntimeState, T>) -> T {
        runtime[keyPath: keyPath]
    }

    subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<RuntimeState, T>) -> T {
        get { runtime[keyPath: keyPath] }
        set { runtime[keyPath: keyPath] = newValue }
    }

    subscript<T>(dynamicMember keyPath: KeyPath<PromptTemplateStore, T>) -> T {
        prompts[keyPath: keyPath]
    }

    subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<PromptTemplateStore, T>) -> T {
        get { prompts[keyPath: keyPath] }
        set { prompts[keyPath: keyPath] = newValue }
    }

    subscript<T>(dynamicMember keyPath: KeyPath<ContextRoutingState, T>) -> T {
        context[keyPath: keyPath]
    }

    subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<ContextRoutingState, T>) -> T {
        get { context[keyPath: keyPath] }
        set { context[keyPath: keyPath] = newValue }
    }

    var isEnglishUI: Bool {
        prefs.uiLanguage == .english
    }

    var stateDirectoryURL: URL {
        appSupportDirectoryURL.appendingPathComponent("state", isDirectory: true)
    }

    var dictionaryFileURL: URL {
        appSupportDirectoryURL.appendingPathComponent("dictionary.json")
    }

    var styleProfileFileURL: URL {
        stateDirectoryURL.appendingPathComponent("style_profile.json")
    }

    func ui(_ zh: String, _ en: String) -> String {
        prefs.ui(zh, en)
    }

    func shortcut(for mode: WorkflowMode) -> HotkeyShortcut {
        prefs.shortcut(for: mode)
    }

    @discardableResult
    func applyHotkey(_ shortcut: HotkeyShortcut, for mode: WorkflowMode) -> HotkeyValidationError? {
        prefs.applyHotkey(shortcut, for: mode)
    }

    func outputLanguageDirective(asrDetectedLanguage: String?, transcriptText: String) -> OutputLanguageDirective {
        prefs.outputLanguageDirective(asrDetectedLanguage: asrDetectedLanguage, transcriptText: transcriptText)
    }

    func applyPromptPreset(id: String) {
        prompts.applyPromptPreset(id: id)
    }

    @discardableResult
    func saveCurrentPromptAsNewPreset(named name: String) -> Bool {
        prompts.saveCurrentPromptAsNewPreset(named: name)
    }

    @discardableResult
    func overwriteSelectedCustomPromptPreset(named name: String?) -> Bool {
        prompts.overwriteSelectedCustomPromptPreset(named: name)
    }

    @discardableResult
    func deleteSelectedCustomPromptPreset() -> Bool {
        prompts.deleteSelectedCustomPromptPreset()
    }

    func resolvedDictateSystemPrompt() -> String {
        prompts.resolvedDictateSystemPrompt()
    }

    func resolvedDictateSystemPrompt(lockedDictationPrompt: String?) -> String {
        prompts.resolvedDictateSystemPrompt(lockedDictationPrompt: lockedDictationPrompt)
    }

    func resolvedAskSystemPrompt() -> String {
        prompts.resolvedAskSystemPrompt()
    }

    func resolvedTranslateSystemPrompt(targetLanguage: String) -> String {
        prompts.resolvedTranslateSystemPrompt(targetLanguage: targetLanguage)
    }

    func resolvedGeminiASRPrompt(language: String) -> String {
        prompts.resolvedGeminiASRPrompt(language: language)
    }

    func promptPreset(by id: String) -> PromptPreset? {
        prompts.promptPreset(by: id)
    }

    func normalizedPromptPresetID(_ rawID: String?, fallbackID: String? = nil) -> String {
        prompts.normalizedPromptPresetID(rawID, fallbackID: fallbackID)
    }

    func ensurePersonalizationFilesExist() -> Bool {
        do {
            try FileManager.default.createDirectory(at: appSupportDirectoryURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: stateDirectoryURL, withIntermediateDirectories: true)
            let audioCapturesURL = appSupportDirectoryURL.appendingPathComponent("AudioCaptures", isDirectory: true)
            try FileManager.default.createDirectory(at: audioCapturesURL, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: dictionaryFileURL.path) {
                try """
                {
                  "items": []
                }
                """.write(to: dictionaryFileURL, atomically: true, encoding: .utf8)
            }
            if !FileManager.default.fileExists(atPath: styleProfileFileURL.path) {
                try """
                {
                  "version": 1,
                  "updated_at": "",
                  "rules": []
                }
                """.write(to: styleProfileFileURL, atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            return false
        }
    }

    private func bridgeModuleChanges() {
        moduleCancellables.removeAll()
        bindModule(engine)
        bindModule(prefs)
        bindModule(runtime)
        bindModule(context)
        promptStoreBound = false
    }

    private func ensurePromptStore() -> PromptTemplateStore {
        if !promptStoreBound {
            bindModule(promptStore)
            promptStoreBound = true
        }
        return promptStore
    }

    private func bindModule(_ module: some ObservableObject) {
        module.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &moduleCancellables)
    }

    private var appSupportDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("GhostType", isDirectory: true)
    }

    /// One-time migration from the legacy "LocalTypeless.*" UserDefaults prefix to "GhostType.*".
    private static func migrateLegacyPrefixIfNeeded(defaults: UserDefaults = .standard) {
        let doneKey = "GhostType.legacyPrefixMigrationDone"
        guard !defaults.bool(forKey: doneKey) else { return }
        let keys = [
            "asrEngine", "llmEngine", "asrModel", "llmModel", "localASRModel",
            "selectedLocalASRProvider", "selectedLocalASRModelId", "localASRShowAdvancedModels",
            "localLLMShowAdvancedQuantization",
            "localHTTPASRBaseURL", "localHTTPASRModelName",
            "localASRFunASRVADEnabled", "localASRFunASRPunctuationEnabled", "localASRWeNetModelType",
            "localASRWhisperCppBinaryPath", "localASRWhisperCppModelPath",
            "cloudASRBaseURL", "cloudASRModelName", "cloudASRLanguage",
            "cloudASRProviderKind", "cloudASRTimeoutSec", "cloudASRMaxRetries", "cloudASRMaxInFlight", "cloudASRStreamingEnabled",
            "cloudLLMBaseURL", "cloudLLMModelName", "cloudLLMAPIVersion",
            "cloudLLMProviderKind", "cloudLLMTimeoutSec", "cloudLLMMaxRetries", "cloudLLMMaxInFlight", "cloudLLMStreamingEnabled",
            "privacyModeEnabled", "uiLanguage", "targetLanguage", "outputLanguage",
            "memoryTimeout", "audioEnhancementEnabled", "audioEnhancementMode",
            "lowVolumeBoost", "noiseSuppressionLevel", "endpointPauseThreshold",
            "showAudioDebugHUD", "dictationDualPassEnabled", "dictationQualityAutoReplaceEnabled",
            "removeRepeatedTextEnabled",
            "smartInsertEnabled", "restoreClipboardAfterPaste",
            "pretranscribeEnabled", "pretranscribeStepSeconds", "pretranscribeOverlapSeconds",
            "pretranscribeMaxChunkSeconds", "pretranscribeMinSpeechSeconds",
            "pretranscribeEndSilenceMS", "pretranscribeMaxInFlight", "pretranscribeFallbackPolicy",
            "dictateShortcut", "askShortcut", "translateShortcut",
            "selectedPromptPresetID", "customPromptPresets",
            // Note: prompt template content keys are intentionally excluded —
            // let PromptTemplateStore always load the latest builtin content on first run.
            "contextAutoPresetSwitchingEnabled", "contextLockCurrentPreset",
            "contextDefaultDictationPresetID", "contextActiveDictationPresetID",
            "contextRoutingRules", "keychainDiagnosticsEnabled",
        ]
        for key in keys {
            let oldKey = "LocalTypeless.\(key)"
            let newKey = "GhostType.\(key)"
            guard let oldValue = defaults.object(forKey: oldKey),
                  defaults.object(forKey: newKey) == nil else { continue }
            defaults.set(oldValue, forKey: newKey)
        }
        defaults.set(true, forKey: doneKey)
    }
}
