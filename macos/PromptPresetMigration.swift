import Foundation

enum PromptPresetMigration {
    typealias CleanupResult = (presets: [PromptPreset], replacementMap: [String: String])

    private static let legacyContextPresetIDAliases: [String: String] = [
        "dictation.context.chatgpt-web": PromptTemplateStore.promptBuilderPresetID,
        "dictation.context.gemini-web": PromptTemplateStore.promptBuilderPresetID,
        "dictation.context.wechat": PromptTemplateStore.imNaturalChatPresetID,
        "dictation.context.notion": PromptTemplateStore.workspaceNotesPresetID,
        "dictation.context.default": PromptTemplateStore.workspaceNotesPresetID,
        "builtin.chatgpt-web-promptstyle": PromptTemplateStore.promptBuilderPresetID,
        "builtin.gemini-web-promptstyle": PromptTemplateStore.promptBuilderPresetID,
        "builtin.wechat-chatstyle": PromptTemplateStore.imNaturalChatPresetID,
        "builtin.notion-notestyle": PromptTemplateStore.workspaceNotesPresetID,
        "builtin.default-promptstyle": PromptTemplateStore.workspaceNotesPresetID,
    ]

    private static let legacyContextPresetNameAliases: [String: String] = [
        "chatgpt web promptstyle": PromptTemplateStore.promptBuilderPresetID,
        "gemini web promptstyle": PromptTemplateStore.promptBuilderPresetID,
        "wechat chatstyle": PromptTemplateStore.imNaturalChatPresetID,
        "notion notestyle": PromptTemplateStore.workspaceNotesPresetID,
        "default promptstyle": PromptTemplateStore.workspaceNotesPresetID,
    ]

    static func removeLegacyContextPromptPresets(from presets: [PromptPreset]) -> CleanupResult {
        var replacementMap: [String: String] = [:]
        var sanitized: [PromptPreset] = []
        sanitized.reserveCapacity(presets.count)

        for preset in presets {
            if let replacement = migratedLegacyPresetID(preset.id) ?? migratedLegacyPresetIDForName(preset.name) {
                replacementMap[preset.id] = replacement
                continue
            }
            sanitized.append(preset)
        }

        return (sanitized, replacementMap)
    }

    static func migrateContextPresetReferences(
        in defaults: UserDefaults,
        customPresetReplacementMap: [String: String]
    ) {
        func migrateID(_ rawID: String?) -> String? {
            let trimmed = (rawID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let replacement = customPresetReplacementMap[trimmed] {
                return replacement
            }
            if let migrated = migratedLegacyPresetID(trimmed) {
                return migrated
            }
            return trimmed
        }

        if let selectedRaw = defaults.string(forKey: "GhostType.selectedPromptPresetID"),
           let migratedSelected = migrateID(selectedRaw),
           migratedSelected != selectedRaw {
            defaults.set(migratedSelected, forKey: "GhostType.selectedPromptPresetID")
        }

        for key in ["GhostType.contextDefaultDictationPresetID", "GhostType.contextActiveDictationPresetID"] {
            guard let raw = defaults.string(forKey: key),
                  let migrated = migrateID(raw),
                  migrated != raw else {
                continue
            }
            defaults.set(migrated, forKey: key)
        }

        guard let encodedRules = defaults.data(forKey: "GhostType.contextRoutingRules"),
              let decodedRules = try? JSONDecoder().decode([RoutingRule].self, from: encodedRules) else {
            return
        }

        var didChange = false
        var migratedRules = decodedRules
        for index in migratedRules.indices {
            let original = migratedRules[index].targetPresetId
            guard let migrated = migrateID(original) else { continue }
            if migrated != original {
                migratedRules[index].targetPresetId = migrated
                didChange = true
            }
        }

        if didChange, let data = try? JSONEncoder().encode(migratedRules) {
            defaults.set(data, forKey: "GhostType.contextRoutingRules")
        }
    }

    static func migratedLegacyPresetID(_ rawID: String?) -> String? {
        let trimmed = (rawID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let mapped = legacyContextPresetIDAliases[trimmed] {
            return mapped
        }

        let lowered = trimmed.lowercased()
        if let mapped = legacyContextPresetIDAliases[lowered] {
            return mapped
        }

        if lowered.contains("chatgpt"), lowered.contains("promptstyle") {
            return PromptTemplateStore.promptBuilderPresetID
        }
        if lowered.contains("gemini"), lowered.contains("promptstyle") {
            return PromptTemplateStore.promptBuilderPresetID
        }
        if lowered.contains("wechat"), lowered.contains("chatstyle") {
            return PromptTemplateStore.imNaturalChatPresetID
        }
        if lowered.contains("notion"), lowered.contains("notestyle") {
            return PromptTemplateStore.workspaceNotesPresetID
        }
        if lowered.contains("default"), lowered.contains("promptstyle") {
            return PromptTemplateStore.workspaceNotesPresetID
        }

        return nil
    }

    @MainActor
    static func migrate(_ store: PromptTemplateStore) {
        let cleanup = removeLegacyContextPromptPresets(from: store.customPromptPresets)
        if cleanup.presets != store.customPromptPresets {
            store.customPromptPresets = cleanup.presets
        }
        migrateContextPresetReferences(
            in: store.userDefaultsForMigration,
            customPresetReplacementMap: cleanup.replacementMap
        )

        let normalizedSelected = store.normalizedPromptPresetID(
            store.selectedPromptPresetID,
            fallbackID: PromptTemplateStore.defaultPromptPreset.id
        )
        if normalizedSelected != store.selectedPromptPresetID {
            store.applyPromptPreset(id: normalizedSelected)
        }
    }

    private static func migratedLegacyPresetIDForName(_ name: String) -> String? {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        return legacyContextPresetNameAliases[normalized]
    }
}
