import XCTest
@testable import GhostType

@MainActor
final class PromptTemplateStoreMigrationTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for suiteName in suiteNames {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    func testLegacyContextPromptStylesAreRemovedAndReferencesMigrated() throws {
        let defaults = makeDefaults()

        let legacyChatGPT = PromptPreset(
            id: "custom.legacy.chatgpt",
            name: "ChatGPT Web PromptStyle",
            dictateSystemPrompt: "legacy",
            askSystemPrompt: "legacy",
            translateSystemPrompt: "legacy",
            geminiASRPrompt: "legacy",
            isBuiltIn: false
        )
        let legacyNotion = PromptPreset(
            id: "custom.legacy.notion",
            name: "Notion NoteStyle",
            dictateSystemPrompt: "legacy",
            askSystemPrompt: "legacy",
            translateSystemPrompt: "legacy",
            geminiASRPrompt: "legacy",
            isBuiltIn: false
        )
        let keptPreset = PromptPreset(
            id: "custom.keep",
            name: "My Team Style",
            dictateSystemPrompt: "keep",
            askSystemPrompt: "keep",
            translateSystemPrompt: "keep",
            geminiASRPrompt: "keep",
            isBuiltIn: false
        )
        let encodedCustomPresets = try JSONEncoder().encode([legacyChatGPT, legacyNotion, keptPreset])
        defaults.set(encodedCustomPresets, forKey: "GhostType.customPromptPresets")

        defaults.set("custom.legacy.chatgpt", forKey: "GhostType.selectedPromptPresetID")
        defaults.set("dictation.context.default", forKey: "GhostType.contextDefaultDictationPresetID")
        defaults.set("custom.legacy.notion", forKey: "GhostType.contextActiveDictationPresetID")

        let legacyRules: [RoutingRule] = [
            RoutingRule(
                id: "rule.legacy.chatgpt",
                priority: 1,
                matchType: .domainExact,
                matchValue: "chat.openai.com",
                targetPresetId: "dictation.context.chatgpt-web",
                enabled: true
            ),
            RoutingRule(
                id: "rule.legacy.notion",
                priority: 2,
                matchType: .appBundleId,
                matchValue: "notion.id",
                targetPresetId: "custom.legacy.notion",
                enabled: true
            ),
            RoutingRule(
                id: "rule.legacy.gemini",
                priority: 3,
                matchType: .domainExact,
                matchValue: "gemini.google.com",
                targetPresetId: "builtin.gemini-web-promptstyle",
                enabled: true
            ),
        ]
        defaults.set(try JSONEncoder().encode(legacyRules), forKey: "GhostType.contextRoutingRules")

        let store = PromptTemplateStore(defaults: defaults)
        XCTAssertEqual(store.selectedPromptPresetID, PromptTemplateStore.promptBuilderPresetID)
        XCTAssertEqual(store.customPromptPresets.map(\.id), ["custom.keep"])

        XCTAssertEqual(
            defaults.string(forKey: "GhostType.contextDefaultDictationPresetID"),
            PromptTemplateStore.workspaceNotesPresetID
        )
        XCTAssertEqual(
            defaults.string(forKey: "GhostType.contextActiveDictationPresetID"),
            PromptTemplateStore.workspaceNotesPresetID
        )

        let migratedRulesData = try XCTUnwrap(defaults.data(forKey: "GhostType.contextRoutingRules"))
        let migratedRules = try JSONDecoder().decode([RoutingRule].self, from: migratedRulesData)
        XCTAssertEqual(migratedRules[0].targetPresetId, PromptTemplateStore.promptBuilderPresetID)
        XCTAssertEqual(migratedRules[1].targetPresetId, PromptTemplateStore.workspaceNotesPresetID)
        XCTAssertEqual(migratedRules[2].targetPresetId, PromptTemplateStore.promptBuilderPresetID)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "PromptTemplateStoreMigrationTests.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create UserDefaults suite: \(suiteName)")
            return .standard
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
