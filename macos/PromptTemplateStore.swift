import Foundation

enum PromptLibraryMarkdownParser {
    struct ParsedDocument {
        let standardAskPrompt: String
        let standardTranslatePrompt: String
        let standardGeminiASRPrompt: String
        let dictationPrompts: [String: String]
    }

    private static let askHeading = "Standard Ask System Prompt"
    private static let translateHeading = "Standard Translate System Prompt"
    private static let geminiHeading = "Standard Multimodal AI Model Prompt"

    static func parse(markdown: String) -> ParsedDocument? {
        let lines = markdown.components(separatedBy: .newlines)
        var index = 0
        var currentHeading: String?
        var codeBlockByHeading: [String: String] = [:]

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("### ") {
                let heading = String(trimmed.dropFirst(4))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                currentHeading = heading.isEmpty ? nil : heading
                index += 1
                continue
            }

            if trimmed.hasPrefix("```"), let heading = currentHeading {
                index += 1
                var blockLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index]
                    if candidate.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
                        break
                    }
                    blockLines.append(candidate)
                    index += 1
                }
                let block = blockLines
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !block.isEmpty {
                    codeBlockByHeading[heading] = block
                }
            }

            index += 1
        }

        guard let askPrompt = codeBlockByHeading[askHeading],
              let translatePrompt = codeBlockByHeading[translateHeading],
              let geminiPrompt = codeBlockByHeading[geminiHeading]
        else {
            return nil
        }

        var dictationPrompts: [String: String] = [:]
        for (heading, block) in codeBlockByHeading {
            if heading == askHeading || heading == translateHeading || heading == geminiHeading {
                continue
            }
            dictationPrompts[heading] = block
        }

        return ParsedDocument(
            standardAskPrompt: askPrompt,
            standardTranslatePrompt: translatePrompt,
            standardGeminiASRPrompt: geminiPrompt,
            dictationPrompts: dictationPrompts
        )
    }
}

struct PromptPreset: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var dictateSystemPrompt: String
    var askSystemPrompt: String
    var translateSystemPrompt: String
    var geminiASRPrompt: String
    var isBuiltIn: Bool
    var updatedAt: Date

    init(
        id: String,
        name: String,
        dictateSystemPrompt: String,
        askSystemPrompt: String,
        translateSystemPrompt: String,
        geminiASRPrompt: String,
        isBuiltIn: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.dictateSystemPrompt = dictateSystemPrompt
        self.askSystemPrompt = askSystemPrompt
        self.translateSystemPrompt = translateSystemPrompt
        self.geminiASRPrompt = geminiASRPrompt
        self.isBuiltIn = isBuiltIn
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case dictateSystemPrompt
        case askSystemPrompt
        case translateSystemPrompt
        case geminiASRPrompt
        case isBuiltIn
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        dictateSystemPrompt = try container.decode(String.self, forKey: .dictateSystemPrompt)
        askSystemPrompt = try container.decode(String.self, forKey: .askSystemPrompt)
        translateSystemPrompt = try container.decode(String.self, forKey: .translateSystemPrompt)
        geminiASRPrompt = try container.decode(String.self, forKey: .geminiASRPrompt)
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

@MainActor
final class PromptTemplateStore: ObservableObject {
    private enum Keys {
        static let selectedPromptPresetID = "GhostType.selectedPromptPresetID"
        static let customPromptPresets = "GhostType.customPromptPresets"
        static let dictateSystemPromptTemplate = "GhostType.dictateSystemPromptTemplate"
        static let askSystemPromptTemplate = "GhostType.askSystemPromptTemplate"
        static let translateSystemPromptTemplate = "GhostType.translateSystemPromptTemplate"
        static let geminiASRPromptTemplate = "GhostType.geminiASRPromptTemplate"
        static let promptTemplateVersion = "GhostType.promptTemplateVersion"
        static let contextDefaultDictationPresetID = "GhostType.contextDefaultDictationPresetID"
        static let contextActiveDictationPresetID = "GhostType.contextActiveDictationPresetID"
        static let contextRoutingRules = "GhostType.contextRoutingRules"
    }

    static let currentPromptTemplateVersion = 5
    static let legacyDefaultPromptPresetIDs: Set<String> = [
        "builtin.strict",
        "builtin.precise-english-v2",
    ]

    private let defaults: UserDefaults

    @Published var selectedPromptPresetID: String {
        didSet {
            defaults.set(selectedPromptPresetID, forKey: Keys.selectedPromptPresetID)
        }
    }

    @Published var customPromptPresets: [PromptPreset] {
        didSet {
            persistCustomPromptPresets()
        }
    }

    @Published var dictateSystemPromptTemplate: String {
        didSet {
            defaults.set(dictateSystemPromptTemplate, forKey: Keys.dictateSystemPromptTemplate)
        }
    }

    @Published var askSystemPromptTemplate: String {
        didSet {
            defaults.set(askSystemPromptTemplate, forKey: Keys.askSystemPromptTemplate)
        }
    }

    @Published var translateSystemPromptTemplate: String {
        didSet {
            defaults.set(translateSystemPromptTemplate, forKey: Keys.translateSystemPromptTemplate)
        }
    }

    @Published var geminiASRPromptTemplate: String {
        didSet {
            defaults.set(geminiASRPromptTemplate, forKey: Keys.geminiASRPromptTemplate)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let loadedCustomPromptPresetsRaw = Self.loadCustomPromptPresets(from: defaults)
        let legacyCleanup = PromptPresetMigration.removeLegacyContextPromptPresets(from: loadedCustomPromptPresetsRaw)
        let loadedCustomPromptPresets = legacyCleanup.presets
        if loadedCustomPromptPresets != loadedCustomPromptPresetsRaw {
            Self.persistCustomPromptPresets(loadedCustomPromptPresets, to: defaults)
        }
        PromptPresetMigration.migrateContextPresetReferences(
            in: defaults,
            customPresetReplacementMap: legacyCleanup.replacementMap
        )

        let loadedSelectedPromptPresetIDRaw = defaults.string(forKey: Keys.selectedPromptPresetID)
        let loadedSelectedPromptPresetID = {
            guard let storedID = loadedSelectedPromptPresetIDRaw else {
                return Self.defaultPromptPreset.id
            }
            let migrated = legacyCleanup.replacementMap[storedID]
                ?? PromptPresetMigration.migratedLegacyPresetID(storedID)
                ?? storedID
            if Self.legacyDefaultPromptPresetIDs.contains(migrated) {
                return Self.defaultPromptPreset.id
            }
            return migrated
        }()
        if let raw = loadedSelectedPromptPresetIDRaw,
           raw != loadedSelectedPromptPresetID {
            defaults.set(loadedSelectedPromptPresetID, forKey: Keys.selectedPromptPresetID)
        }

        customPromptPresets = loadedCustomPromptPresets
        selectedPromptPresetID = loadedSelectedPromptPresetID

        let promptTemplateVersion = defaults.integer(forKey: Keys.promptTemplateVersion)
        let selectedPresetIsCustom = loadedCustomPromptPresets.contains(where: { $0.id == loadedSelectedPromptPresetID })
        let shouldMigrateBuiltInPromptTemplates = promptTemplateVersion < Self.currentPromptTemplateVersion && !selectedPresetIsCustom
        if shouldMigrateBuiltInPromptTemplates {
            defaults.removeObject(forKey: Keys.dictateSystemPromptTemplate)
            defaults.removeObject(forKey: Keys.askSystemPromptTemplate)
            defaults.removeObject(forKey: Keys.translateSystemPromptTemplate)
            defaults.removeObject(forKey: Keys.geminiASRPromptTemplate)
        }

        let initialPreset = Self.promptPreset(by: loadedSelectedPromptPresetID, customPresets: loadedCustomPromptPresets)
            ?? Self.defaultPromptPreset
        dictateSystemPromptTemplate = defaults.string(forKey: Keys.dictateSystemPromptTemplate) ?? initialPreset.dictateSystemPrompt
        askSystemPromptTemplate = defaults.string(forKey: Keys.askSystemPromptTemplate) ?? initialPreset.askSystemPrompt
        translateSystemPromptTemplate = defaults.string(forKey: Keys.translateSystemPromptTemplate) ?? initialPreset.translateSystemPrompt
        geminiASRPromptTemplate = defaults.string(forKey: Keys.geminiASRPromptTemplate) ?? initialPreset.geminiASRPrompt

        if Self.promptPreset(by: loadedSelectedPromptPresetID, customPresets: loadedCustomPromptPresets) == nil {
            selectedPromptPresetID = Self.defaultPromptPreset.id
        }
        defaults.set(Self.currentPromptTemplateVersion, forKey: Keys.promptTemplateVersion)
        PromptPresetMigration.migrate(self)
    }

    var availablePromptPresets: [PromptPreset] {
        Self.builtInPromptPresets + customPromptPresets
    }

    var selectedPromptPresetName: String {
        availablePromptPresets.first(where: { $0.id == selectedPromptPresetID })?.name ?? Self.defaultPromptPreset.name
    }

    var isSelectedPromptPresetCustom: Bool {
        customPromptPresets.contains(where: { $0.id == selectedPromptPresetID })
    }

    func promptPreset(by id: String) -> PromptPreset? {
        Self.promptPreset(by: id, customPresets: customPromptPresets)
    }

    func normalizedPromptPresetID(_ rawID: String?, fallbackID: String? = nil) -> String {
        let fallback = fallbackID ?? Self.defaultPromptPreset.id
        let trimmed = (rawID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let candidate = PromptPresetMigration.migratedLegacyPresetID(trimmed) ?? trimmed
        return promptPreset(by: candidate) == nil ? fallback : candidate
    }

    func applyPromptPreset(id: String) {
        guard let preset = Self.promptPreset(by: id, customPresets: customPromptPresets) else { return }
        selectedPromptPresetID = preset.id
        dictateSystemPromptTemplate = preset.dictateSystemPrompt
        askSystemPromptTemplate = preset.askSystemPrompt
        translateSystemPromptTemplate = preset.translateSystemPrompt
        geminiASRPromptTemplate = preset.geminiASRPrompt
    }

    @discardableResult
    func saveCurrentPromptAsNewPreset(named name: String) -> Bool {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { return false }
        let preset = PromptPreset(
            id: "custom.\(UUID().uuidString)",
            name: cleanedName,
            dictateSystemPrompt: dictateSystemPromptTemplate,
            askSystemPrompt: askSystemPromptTemplate,
            translateSystemPrompt: translateSystemPromptTemplate,
            geminiASRPrompt: geminiASRPromptTemplate,
            isBuiltIn: false,
            updatedAt: Date()
        )
        customPromptPresets.append(preset)
        selectedPromptPresetID = preset.id
        return true
    }

    @discardableResult
    func overwriteSelectedCustomPromptPreset(named name: String?) -> Bool {
        guard let index = customPromptPresets.firstIndex(where: { $0.id == selectedPromptPresetID }) else {
            return false
        }

        let cleanedName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        customPromptPresets[index].name = cleanedName.isEmpty ? customPromptPresets[index].name : cleanedName
        customPromptPresets[index].dictateSystemPrompt = dictateSystemPromptTemplate
        customPromptPresets[index].askSystemPrompt = askSystemPromptTemplate
        customPromptPresets[index].translateSystemPrompt = translateSystemPromptTemplate
        customPromptPresets[index].geminiASRPrompt = geminiASRPromptTemplate
        customPromptPresets[index].isBuiltIn = false
        customPromptPresets[index].updatedAt = Date()
        return true
    }

    @discardableResult
    func deleteSelectedCustomPromptPreset() -> Bool {
        guard let index = customPromptPresets.firstIndex(where: { $0.id == selectedPromptPresetID }) else {
            return false
        }
        customPromptPresets.remove(at: index)
        applyPromptPreset(id: Self.defaultPromptPreset.id)
        return true
    }

    func resolvedDictateSystemPrompt() -> String {
        normalizedPrompt(dictateSystemPromptTemplate, fallback: Self.defaultPromptPreset.dictateSystemPrompt)
    }

    func resolvedDictateSystemPrompt(lockedDictationPrompt: String?) -> String {
        let locked = (lockedDictationPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !locked.isEmpty {
            return locked
        }
        return resolvedDictateSystemPrompt()
    }

    func resolvedAskSystemPrompt() -> String {
        normalizedPrompt(askSystemPromptTemplate, fallback: Self.defaultPromptPreset.askSystemPrompt)
    }

    func resolvedTranslateSystemPrompt(targetLanguage: String) -> String {
        let template = normalizedPrompt(translateSystemPromptTemplate, fallback: Self.defaultPromptPreset.translateSystemPrompt)
        return template
            .replacingOccurrences(of: "{target_language}", with: targetLanguage)
            .replacingOccurrences(of: "【{target_language}】", with: "【\(targetLanguage)】")
    }

    func resolvedGeminiASRPrompt(language: String) -> String {
        let template = normalizedPrompt(geminiASRPromptTemplate, fallback: Self.defaultPromptPreset.geminiASRPrompt)
        return template.replacingOccurrences(of: "{language}", with: language)
    }

    private func normalizedPrompt(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return fallback
        }
        return trimmed
    }

    private static func promptPreset(by id: String, customPresets: [PromptPreset]) -> PromptPreset? {
        builtInPromptPresets.first(where: { $0.id == id }) ?? customPresets.first(where: { $0.id == id })
    }

    private static func loadCustomPromptPresets(from defaults: UserDefaults) -> [PromptPreset] {
        guard let data = defaults.data(forKey: Keys.customPromptPresets) else {
            return []
        }
        do {
            return try JSONDecoder().decode([PromptPreset].self, from: data)
        } catch {
            AppLogger.shared.log("Failed to decode custom prompt presets: \(error.localizedDescription)", type: .warning)
            return []
        }
    }

    private static func persistCustomPromptPresets(_ presets: [PromptPreset], to defaults: UserDefaults) {
        do {
            let data = try JSONEncoder().encode(presets)
            defaults.set(data, forKey: Keys.customPromptPresets)
        } catch {
            AppLogger.shared.log("Failed to encode custom prompt presets for persistence: \(error.localizedDescription)", type: .error)
        }
    }

    private func persistCustomPromptPresets() {
        do {
            let data = try JSONEncoder().encode(customPromptPresets)
            defaults.set(data, forKey: Keys.customPromptPresets)
        } catch {
            AppLogger.shared.log("Failed to encode custom prompt presets: \(error.localizedDescription)", type: .error)
        }
    }

    var userDefaultsForMigration: UserDefaults {
        defaults
    }
}

extension PromptTemplateStore {
    nonisolated static let promptBuilderPresetID = PromptLibraryBuiltins.promptBuilderPresetID
    nonisolated static let imNaturalChatPresetID = PromptLibraryBuiltins.imNaturalChatPresetID
    nonisolated static let workspaceNotesPresetID = PromptLibraryBuiltins.workspaceNotesPresetID
    nonisolated static let emailProfessionalPresetID = PromptLibraryBuiltins.emailProfessionalPresetID
    nonisolated static let ticketUpdatePresetID = PromptLibraryBuiltins.ticketUpdatePresetID
    nonisolated static let workChatBriefPresetID = PromptLibraryBuiltins.workChatBriefPresetID

    nonisolated static let defaultPromptPreset = PromptLibraryBuiltins.defaultPromptPreset
    nonisolated static let builtInPromptPresets = PromptLibraryBuiltins.builtInPromptPresets

    nonisolated static func migratedLegacyPresetID(_ rawID: String?) -> String? {
        PromptPresetMigration.migratedLegacyPresetID(rawID)
    }
}
