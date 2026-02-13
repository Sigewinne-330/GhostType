extension AppState {
    static let defaultPromptPreset = PromptTemplateStore.defaultPromptPreset
    static let builtInPromptPresets = PromptTemplateStore.builtInPromptPresets
    static let builtInContextRoutingRules = ContextRoutingState.builtInContextRoutingRules

    func isIMNaturalChatPreset(_ id: String?) -> Bool {
        normalizedPromptPresetID(id) == PromptTemplateStore.imNaturalChatPresetID
    }

    func normalizedDictationContextPresetID(_ rawID: String?) -> String {
        context.normalizedDictationContextPresetID(rawID)
    }

    func applyContextRoutingDecision(
        snapshot: ContextSnapshot,
        matchedRule: RoutingRule?,
        selectedPresetID: String,
        selectedPresetTitle: String
    ) {
        context.applyContextRoutingDecision(
            snapshot: snapshot,
            matchedRule: matchedRule,
            selectedPresetID: selectedPresetID,
            selectedPresetTitle: selectedPresetTitle
        )
    }

    func updateContextDebugSnapshot(snapshot: ContextSnapshot, matchedRule: RoutingRule?) {
        context.updateContextDebugSnapshot(snapshot: snapshot, matchedRule: matchedRule)
    }

    func replaceContextRoutingRules(_ rules: [RoutingRule]) {
        context.replaceContextRoutingRules(rules)
    }

    func resetContextRoutingRulesToBuiltIn() {
        context.resetContextRoutingRulesToBuiltIn()
    }
}
