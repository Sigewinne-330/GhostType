import Foundation

@MainActor
final class DictationContextManager {
    private var selections: [UUID: DictationContextSelection] = [:]

    func selection(for sessionID: UUID) -> DictationContextSelection? {
        selections[sessionID]
    }

    @discardableResult
    func lockDictationContext(
        for sessionID: UUID,
        state: AppState,
        logger: AppLogger
    ) -> DictationContextSelection {
        let snapshot = ContextDetector.getSnapshot()
        let resolution = ContextPresetResolver.resolve(
            mode: .dictate,
            autoSwitchEnabled: state.contextAutoPresetSwitchingEnabled,
            lockCurrentPreset: state.contextLockCurrentPreset,
            currentPresetId: state.contextActiveDictationPresetID,
            defaultPresetId: state.contextDefaultDictationPresetID,
            rules: state.contextRoutingRules,
            snapshot: snapshot
        )
        let presetID = state.normalizedPromptPresetID(
            resolution.presetId,
            fallbackID: state.contextDefaultDictationPresetID
        )
        let defaultPreset = state.promptPreset(by: state.contextDefaultDictationPresetID)
            ?? PromptTemplateStore.defaultPromptPreset
        let preset = state.promptPreset(by: presetID) ?? defaultPreset

        if state.promptPreset(by: presetID) == nil {
            logger.log(
                "Resolved dictation preset missing. Fallback applied. sessionId=\(sessionID.uuidString) presetId=\(presetID) fallback=\(defaultPreset.id)",
                type: .warning
            )
        }

        let selection = DictationContextSelection(
            snapshot: snapshot,
            preset: DictationResolvedPreset(
                id: preset.id,
                title: preset.name,
                dictationPrompt: preset.dictateSystemPrompt
            ),
            matchedRule: resolution.matchedRule
        )
        selections[sessionID] = selection

        state.applyContextRoutingDecision(
            snapshot: snapshot,
            matchedRule: resolution.matchedRule,
            selectedPresetID: preset.id,
            selectedPresetTitle: preset.name
        )
        logger.log(
            "Dictation context locked. sessionId=\(sessionID.uuidString) app=\(snapshot.frontmostAppBundleId) domain=\(snapshot.activeDomain ?? "n/a") preset=\(preset.name) rule=\(resolution.matchedRule?.id ?? "default")"
        )

        return selection
    }

    func removeSelection(for sessionID: UUID) {
        selections.removeValue(forKey: sessionID)
    }

    func removeAllSelections() {
        selections.removeAll()
    }
}
