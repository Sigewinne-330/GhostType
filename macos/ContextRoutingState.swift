import Foundation

@MainActor
final class ContextRoutingState: ObservableObject {
    private enum Keys {
        static let contextAutoPresetSwitchingEnabled = "GhostType.contextAutoPresetSwitchingEnabled"
        static let contextLockCurrentPreset = "GhostType.contextLockCurrentPreset"
        static let contextDefaultDictationPresetID = "GhostType.contextDefaultDictationPresetID"
        static let contextActiveDictationPresetID = "GhostType.contextActiveDictationPresetID"
        static let contextRoutingRules = "GhostType.contextRoutingRules"
    }

    private let defaults: UserDefaults

    @Published var contextAutoPresetSwitchingEnabled: Bool {
        didSet {
            defaults.set(contextAutoPresetSwitchingEnabled, forKey: Keys.contextAutoPresetSwitchingEnabled)
        }
    }

    @Published var contextLockCurrentPreset: Bool {
        didSet {
            defaults.set(contextLockCurrentPreset, forKey: Keys.contextLockCurrentPreset)
        }
    }

    @Published var contextDefaultDictationPresetID: String {
        didSet {
            let normalized = normalizedDictationContextPresetID(contextDefaultDictationPresetID)
            if contextDefaultDictationPresetID != normalized {
                contextDefaultDictationPresetID = normalized
                return
            }
            defaults.set(contextDefaultDictationPresetID, forKey: Keys.contextDefaultDictationPresetID)
        }
    }

    @Published var contextActiveDictationPresetID: String {
        didSet {
            let normalized = normalizedDictationContextPresetID(contextActiveDictationPresetID)
            if contextActiveDictationPresetID != normalized {
                contextActiveDictationPresetID = normalized
                return
            }
            defaults.set(contextActiveDictationPresetID, forKey: Keys.contextActiveDictationPresetID)
        }
    }

    @Published var contextRoutingRules: [RoutingRule] {
        didSet {
            persistContextRoutingRules()
        }
    }

    @Published var contextLatestSnapshot: ContextSnapshot?
    @Published var contextMatchedRuleID: String
    @Published var contextMatchedRuleSummary: String
    @Published var contextSelectedPresetTitle: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        contextAutoPresetSwitchingEnabled = defaults.object(forKey: Keys.contextAutoPresetSwitchingEnabled) as? Bool ?? true
        contextLockCurrentPreset = defaults.object(forKey: Keys.contextLockCurrentPreset) as? Bool ?? false

        let loadedContextDefaultPresetID = Self.resolveDictationContextPresetID(
            defaults.string(forKey: Keys.contextDefaultDictationPresetID)
        )
        let loadedContextActivePresetID = Self.resolveDictationContextPresetID(
            defaults.string(forKey: Keys.contextActiveDictationPresetID),
            fallback: loadedContextDefaultPresetID
        )
        contextDefaultDictationPresetID = loadedContextDefaultPresetID
        contextActiveDictationPresetID = loadedContextActivePresetID
        contextRoutingRules = Self.loadContextRoutingRules(from: defaults)
        contextLatestSnapshot = nil
        contextMatchedRuleID = "none"
        contextMatchedRuleSummary = "default"
        contextSelectedPresetTitle = loadedContextActivePresetID

        defaults.set(contextDefaultDictationPresetID, forKey: Keys.contextDefaultDictationPresetID)
        defaults.set(contextActiveDictationPresetID, forKey: Keys.contextActiveDictationPresetID)
    }

    var activeDictationContextPresetTitle: String {
        contextSelectedPresetTitle
    }

    var defaultDictationContextPresetTitle: String {
        contextDefaultDictationPresetID
    }

    func normalizedDictationContextPresetID(_ rawID: String?) -> String {
        Self.resolveDictationContextPresetID(rawID, fallback: contextDefaultDictationPresetID)
    }

    func applyContextRoutingDecision(
        snapshot: ContextSnapshot,
        matchedRule: RoutingRule?,
        selectedPresetID: String,
        selectedPresetTitle: String
    ) {
        let normalizedPresetID = normalizedDictationContextPresetID(selectedPresetID)
        if contextActiveDictationPresetID != normalizedPresetID {
            contextActiveDictationPresetID = normalizedPresetID
        }
        let trimmedTitle = selectedPresetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        contextSelectedPresetTitle = trimmedTitle.isEmpty ? normalizedPresetID : trimmedTitle
        updateContextDebugSnapshot(snapshot: snapshot, matchedRule: matchedRule)
    }

    func updateContextDebugSnapshot(snapshot: ContextSnapshot, matchedRule: RoutingRule?) {
        contextLatestSnapshot = snapshot
        contextMatchedRuleID = matchedRule?.id ?? "default"
        if let matchedRule {
            contextMatchedRuleSummary = "\(matchedRule.matchType.rawValue): \(matchedRule.matchValue)"
        } else {
            contextMatchedRuleSummary = "default"
        }
    }

    func replaceContextRoutingRules(_ rules: [RoutingRule]) {
        contextRoutingRules = Self.normalizedContextRoutingRules(rules)
    }

    func resetContextRoutingRulesToBuiltIn() {
        contextRoutingRules = Self.builtInContextRoutingRules
    }

    private static func resolveDictationContextPresetID(_ rawID: String?, fallback: String? = nil) -> String {
        let fallbackID: String = {
            let fallbackTrimmed = (fallback ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return fallbackTrimmed.isEmpty ? defaultContextPresetID : fallbackTrimmed
        }()
        let trimmed = (rawID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallbackID }
        if let migrated = PromptTemplateStore.migratedLegacyPresetID(trimmed) {
            return migrated
        }
        return trimmed
    }

    private static func loadContextRoutingRules(from defaults: UserDefaults) -> [RoutingRule] {
        guard let data = defaults.data(forKey: Keys.contextRoutingRules),
              let decoded = try? JSONDecoder().decode([RoutingRule].self, from: data) else {
            return builtInContextRoutingRules
        }
        let normalized = normalizedContextRoutingRules(decoded)
        return normalized.isEmpty ? builtInContextRoutingRules : normalized
    }

    private static func normalizedContextRoutingRules(_ rules: [RoutingRule]) -> [RoutingRule] {
        var seenIDs = Set<String>()
        var output: [RoutingRule] = []
        output.reserveCapacity(rules.count)

        for raw in rules {
            let id = raw.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            guard seenIDs.insert(id).inserted else { continue }

            var normalized = raw
            normalized.id = id
            normalized.matchValue = raw.matchValue.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.targetPresetId = resolveDictationContextPresetID(
                raw.targetPresetId,
                fallback: defaultContextPresetID
            )
            output.append(normalized)
        }
        return output
    }

    private func persistContextRoutingRules() {
        let normalized = Self.normalizedContextRoutingRules(contextRoutingRules)
        if normalized != contextRoutingRules {
            contextRoutingRules = normalized
            return
        }
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: Keys.contextRoutingRules)
        }
    }
}

extension ContextRoutingState {
    static let defaultContextPresetID = PromptTemplateStore.workspaceNotesPresetID

    static let builtInContextRoutingRules: [RoutingRule] = [
        RoutingRule(
            id: "rule.domain.chatgpt.exact",
            priority: 10,
            matchType: .domainExact,
            matchValue: "chat.openai.com",
            targetPresetId: PromptTemplateStore.promptBuilderPresetID,
            enabled: true
        ),
        RoutingRule(
            id: "rule.domain.gemini.exact",
            priority: 11,
            matchType: .domainExact,
            matchValue: "gemini.google.com",
            targetPresetId: PromptTemplateStore.promptBuilderPresetID,
            enabled: true
        ),
        RoutingRule(
            id: "rule.domain.claude.exact",
            priority: 12,
            matchType: .domainExact,
            matchValue: "claude.ai",
            targetPresetId: PromptTemplateStore.promptBuilderPresetID,
            enabled: true
        ),
        RoutingRule(
            id: "rule.domain.gmail.exact",
            priority: 13,
            matchType: .domainExact,
            matchValue: "mail.google.com",
            targetPresetId: PromptTemplateStore.emailProfessionalPresetID,
            enabled: true
        ),
        RoutingRule(
            id: "rule.domain.outlook.suffix",
            priority: 20,
            matchType: .domainSuffix,
            matchValue: "outlook.office.com",
            targetPresetId: PromptTemplateStore.emailProfessionalPresetID,
            enabled: true
        ),
        RoutingRule(
            id: "rule.domain.atlassian.suffix",
            priority: 21,
            matchType: .domainSuffix,
            matchValue: "atlassian.net",
            targetPresetId: PromptTemplateStore.ticketUpdatePresetID,
            enabled: true
        ),
        RoutingRule(
            id: "rule.bundle.wechat",
            priority: 30,
            matchType: .appBundleId,
            matchValue: "com.tencent.xinWeChat",
            targetPresetId: PromptTemplateStore.imNaturalChatPresetID,
            enabled: true
        ),
        RoutingRule(
            id: "rule.bundle.notion",
            priority: 31,
            matchType: .appBundleId,
            matchValue: "notion.id",
            targetPresetId: PromptTemplateStore.workspaceNotesPresetID,
            enabled: true
        ),
        RoutingRule(
            id: "rule.bundle.slack",
            priority: 32,
            matchType: .appBundleId,
            matchValue: "com.tinyspeck.slackmacgap",
            targetPresetId: PromptTemplateStore.workChatBriefPresetID,
            enabled: true
        ),
        RoutingRule(
            id: "rule.bundle.jira",
            priority: 33,
            matchType: .appBundleId,
            matchValue: "com.atlassian.Jira",
            targetPresetId: PromptTemplateStore.ticketUpdatePresetID,
            enabled: true
        ),
        RoutingRule(
            id: "rule.bundle.apple-mail",
            priority: 34,
            matchType: .appBundleId,
            matchValue: "com.apple.mail",
            targetPresetId: PromptTemplateStore.emailProfessionalPresetID,
            enabled: true
        ),
        RoutingRule(
            id: "rule.title.prompt-builder",
            priority: 40,
            matchType: .windowTitleRegex,
            matchValue: "(chatgpt|chat\\.openai\\.com|gemini\\.google\\.com|claude\\.ai)",
            targetPresetId: PromptTemplateStore.promptBuilderPresetID,
            enabled: true
        ),
    ]
}
