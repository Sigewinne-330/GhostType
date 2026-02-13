import SwiftUI

struct ContextRuleManagerSheet: View {
    @ObservedObject var prefs: UserPreferences
    @ObservedObject var context: ContextRoutingState
    @ObservedObject var prompts: PromptTemplateStore
    @Environment(\.dismiss) private var dismiss

    @State private var draftMatchType: RoutingMatchType = .domainExact
    @State private var draftMatchValue: String = ""
    @State private var draftTargetPresetID: String = ContextRoutingState.defaultContextPresetID
    @State private var draftRuleEnabled: Bool = true
    @State private var statusText: String = ""

    init(prefs: UserPreferences, context: ContextRoutingState, prompts: PromptTemplateStore) {
        self.prefs = prefs
        self.context = context
        self.prompts = prompts
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(prefs.ui("规则列表", "Rules")) {
                    if context.contextRoutingRules.isEmpty {
                        Text(prefs.ui("暂无规则。", "No rules yet."))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sortedRuleIDs, id: \.self) { ruleID in
                            ContextRuleEditorRow(
                                rule: binding(for: ruleID),
                                presets: prompts.availablePromptPresets
                            )
                        }
                        .onDelete(perform: deleteRules)
                    }
                }

                Section(prefs.ui("新增规则", "Add Rule")) {
                    Toggle(
                        prefs.ui("根据当前应用切换提示词", "Enable Auto Preset Switching"),
                        isOn: $context.contextAutoPresetSwitchingEnabled
                    )
                    Toggle(
                        prefs.ui("锁定当前提示词", "Lock Current Preset"),
                        isOn: $context.contextLockCurrentPreset
                    )

                    Picker(prefs.ui("默认提示词", "Default Preset"), selection: $context.contextDefaultDictationPresetID) {
                        ForEach(prompts.availablePromptPresets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker(prefs.ui("当前听写提示词", "Current Dictation Preset"), selection: $context.contextActiveDictationPresetID) {
                        ForEach(prompts.availablePromptPresets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker(prefs.ui("匹配类型", "Match Type"), selection: $draftMatchType) {
                        ForEach(RoutingMatchType.allCases) { matchType in
                            Text(matchType.rawValue).tag(matchType)
                        }
                    }

                    TextField(prefs.ui("匹配值", "Match Value"), text: $draftMatchValue)
                        .textFieldStyle(.roundedBorder)

                    Picker(prefs.ui("目标预设", "Target Preset"), selection: $draftTargetPresetID) {
                        ForEach(prompts.availablePromptPresets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }

                    Toggle(prefs.ui("启用该规则", "Enable Rule"), isOn: $draftRuleEnabled)

                    HStack(spacing: 8) {
                        Button(prefs.ui("新增", "Add")) {
                            addRule()
                        }
                        .buttonStyle(.borderedProminent)

                        Button(prefs.ui("从默认映射生成", "Generate from Default Mapping")) {
                            context.resetContextRoutingRulesToBuiltIn()
                            statusText = prefs.ui("已恢复内置规则。", "Built-in rules restored.")
                        }
                        .buttonStyle(.bordered)
                    }

                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(prefs.ui("上下文路由规则", "Context Routing Rules"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(
                        prefs.ui("根据当前应用切换提示词", "Auto Switch"),
                        isOn: $context.contextAutoPresetSwitchingEnabled
                    )
                    .toggleStyle(.switch)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(prefs.ui("完成", "Done")) {
                        dismiss()
                    }
                }
            }
            .onAppear {
                context.contextDefaultDictationPresetID = prompts.normalizedPromptPresetID(
                    context.contextDefaultDictationPresetID,
                    fallbackID: ContextRoutingState.defaultContextPresetID
                )
                context.contextActiveDictationPresetID = prompts.normalizedPromptPresetID(
                    context.contextActiveDictationPresetID,
                    fallbackID: context.contextDefaultDictationPresetID
                )
                if !prompts.availablePromptPresets.contains(where: { $0.id == draftTargetPresetID }) {
                    draftTargetPresetID = context.contextDefaultDictationPresetID
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var sortedRuleIDs: [String] {
        context.contextRoutingRules
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority < rhs.priority
                }
                if lhs.matchType != rhs.matchType {
                    return lhs.matchType.rawValue < rhs.matchType.rawValue
                }
                return lhs.id < rhs.id
            }
            .map(\.id)
    }

    private func binding(for ruleID: String) -> Binding<RoutingRule> {
        guard let index = context.contextRoutingRules.firstIndex(where: { $0.id == ruleID }) else {
            return .constant(
                RoutingRule(
                    id: ruleID,
                    priority: 0,
                    matchType: .appBundleId,
                    matchValue: "",
                    targetPresetId: context.contextDefaultDictationPresetID,
                    enabled: false
                )
            )
        }
        return $context.contextRoutingRules[index]
    }

    private func addRule() {
        let trimmedValue = draftMatchValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            statusText = prefs.ui("匹配值不能为空。", "Match value cannot be empty.")
            return
        }

        let normalizedPresetID = prompts.normalizedPromptPresetID(
            draftTargetPresetID,
            fallbackID: context.contextDefaultDictationPresetID
        )
        let nextPriority = (context.contextRoutingRules.map(\.priority).max() ?? 0) + 1
        let rule = RoutingRule(
            priority: nextPriority,
            matchType: draftMatchType,
            matchValue: trimmedValue,
            targetPresetId: normalizedPresetID,
            enabled: draftRuleEnabled
        )
        var rules = context.contextRoutingRules
        rules.append(rule)
        context.replaceContextRoutingRules(rules)
        statusText = prefs.ui("已新增规则。", "Rule added.")
        draftMatchValue = ""
    }

    private func deleteRules(at offsets: IndexSet) {
        let idsToDelete: [String] = offsets.compactMap { offset in
            guard sortedRuleIDs.indices.contains(offset) else { return nil }
            return sortedRuleIDs[offset]
        }
        guard !idsToDelete.isEmpty else { return }
        context.contextRoutingRules.removeAll { idsToDelete.contains($0.id) }
    }
}

private struct ContextRuleEditorRow: View {
    @Binding var rule: RoutingRule
    let presets: [PromptPreset]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("#\(rule.priority)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(rule.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Toggle("Enabled", isOn: $rule.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Picker("Match Type", selection: $rule.matchType) {
                ForEach(RoutingMatchType.allCases) { matchType in
                    Text(matchType.rawValue).tag(matchType)
                }
            }
            .pickerStyle(.menu)

            Stepper(value: $rule.priority, in: 0 ... 999) {
                Text("Priority: \(rule.priority)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Match Value", text: $rule.matchValue)
                .textFieldStyle(.roundedBorder)

            Picker("Target Preset", selection: $rule.targetPresetId) {
                ForEach(presets) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .pickerStyle(.menu)
        }
        .padding(.vertical, 4)
    }
}
