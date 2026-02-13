import SwiftUI

struct PromptTemplatesPane: View {
    @ObservedObject var prefs: UserPreferences
    @ObservedObject var prompts: PromptTemplateStore
    @ObservedObject var context: ContextRoutingState

    @State private var presetSelection: String = ""
    @State private var newPresetName: String = ""
    @State private var statusText: String = ""
    @State private var showingContextRuleManager = false
    @State private var showingContextDebugPanel = false

    var body: some View {
        DetailContainer(
            icon: "text.bubble",
            title: prefs.ui("提示词与预设", "Prompts & Presets"),
            subtitle: prefs.ui("编辑 AI Prompt 并管理预设", "Edit AI prompts and manage presets")
        ) {
            Form {
                Section(prefs.ui("预设管理", "Preset Management")) {
                    Picker(prefs.ui("当前预设", "Current Preset"), selection: $presetSelection) {
                        ForEach(prompts.availablePromptPresets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack(spacing: 10) {
                        Button(prefs.ui("应用预设", "Apply Preset")) {
                            prompts.applyPromptPreset(id: presetSelection)
                            newPresetName = prompts.selectedPromptPresetName
                            statusText = "Applied preset: \(prompts.selectedPromptPresetName)"
                        }
                        .buttonStyle(.borderedProminent)

                        Button(prefs.ui("保存为新预设", "Save as New Preset")) {
                            if prompts.saveCurrentPromptAsNewPreset(named: newPresetName) {
                                presetSelection = prompts.selectedPromptPresetID
                                statusText = "Saved as new preset: \(prompts.selectedPromptPresetName)"
                            } else {
                                statusText = prefs.ui("请输入有效的预设名称。", "Please enter a valid preset name.")
                            }
                        }
                        .buttonStyle(.bordered)

                        Button(prefs.ui("覆盖当前预设", "Overwrite Current Preset")) {
                            if prompts.overwriteSelectedCustomPromptPreset(named: newPresetName) {
                                statusText = "Updated preset: \(prompts.selectedPromptPresetName)"
                            } else {
                                statusText = prefs.ui("当前预设不是自定义预设，无法覆盖。", "The current preset is not a custom preset and cannot be overwritten.")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!prompts.isSelectedPromptPresetCustom)

                        Button(role: .destructive) {
                            if prompts.deleteSelectedCustomPromptPreset() {
                                presetSelection = prompts.selectedPromptPresetID
                                newPresetName = prompts.selectedPromptPresetName
                                statusText = "Custom preset deleted. Reverted to default preset."
                            } else {
                                statusText = prefs.ui("当前预设不是自定义预设，无法删除。", "The current preset is not a custom preset and cannot be deleted.")
                            }
                        } label: {
                            Text(prefs.ui("删除自定义预设", "Delete Custom Preset"))
                        }
                        .buttonStyle(.bordered)
                        .disabled(!prompts.isSelectedPromptPresetCustom)
                    }

                    TextField(prefs.ui("预设名称", "Preset Name"), text: $newPresetName)
                        .textFieldStyle(.roundedBorder)

                    Text(prefs.ui("当前支持 4 个可编辑提示词：Dictation / Ask / Translate / Gemini ASR。", "Currently supports 4 editable prompts: Dictation / Ask / Translate / Gemini ASR."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(prefs.ui("自动切换", "Auto Switching")) {
                    Toggle(
                        prefs.ui("根据当前应用切换提示词", "Enable Auto Preset Switching"),
                        isOn: $context.contextAutoPresetSwitchingEnabled
                    )
                    Toggle(
                        prefs.ui("锁定当前提示词", "Lock Current Preset"),
                        isOn: $context.contextLockCurrentPreset
                    )

                    Picker(prefs.ui("Default Preset", "Default Preset"), selection: $context.contextDefaultDictationPresetID) {
                        ForEach(prompts.availablePromptPresets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker(prefs.ui("Current Dictation Preset", "Current Dictation Preset"), selection: $context.contextActiveDictationPresetID) {
                        ForEach(prompts.availablePromptPresets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Button(prefs.ui("Manage Routing Rules", "Manage Routing Rules")) {
                        showingContextRuleManager = true
                    }
                    .buttonStyle(.bordered)

                    DisclosureGroup(
                        prefs.ui("Debug", "Debug"),
                        isExpanded: $showingContextDebugPanel
                    ) {
                        if let snapshot = context.contextLatestSnapshot {
                            LabeledContent(
                                "frontmostAppBundleId",
                                value: snapshot.frontmostAppBundleId
                            )
                            LabeledContent(
                                "activeDomain",
                                value: snapshot.activeDomain ?? "n/a"
                            )
                            LabeledContent(
                                "matchedRule",
                                value: context.contextMatchedRuleSummary
                            )
                            LabeledContent(
                                "selectedPresetTitle",
                                value: context.activeDictationContextPresetTitle
                            )
                            LabeledContent(
                                "confidence",
                                value: snapshot.confidence.rawValue
                            )
                            LabeledContent(
                                "source",
                                value: snapshot.source.rawValue
                            )
                        } else {
                            Text(prefs.ui("暂无上下文快照。", "No context snapshot yet."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Dictation System Prompt") {
                    PromptEditor(text: $prompts.dictateSystemPromptTemplate)
                }

                Section("Ask System Prompt") {
                    PromptEditor(text: $prompts.askSystemPromptTemplate)
                }

                Section("Translate System Prompt") {
                    PromptEditor(text: $prompts.translateSystemPromptTemplate)
                }

                Section("Gemini ASR Prompt") {
                    PromptEditor(text: $prompts.geminiASRPromptTemplate, minHeight: 120)
                }
            }
            .formStyle(.grouped)
            .onAppear {
                if presetSelection.isEmpty {
                    presetSelection = prompts.selectedPromptPresetID
                }
                newPresetName = prompts.selectedPromptPresetName
                context.contextDefaultDictationPresetID = prompts.normalizedPromptPresetID(
                    context.contextDefaultDictationPresetID,
                    fallbackID: ContextRoutingState.defaultContextPresetID
                )
                context.contextActiveDictationPresetID = prompts.normalizedPromptPresetID(
                    context.contextActiveDictationPresetID,
                    fallbackID: context.contextDefaultDictationPresetID
                )
                context.contextSelectedPresetTitle = prompts.promptPreset(
                    by: context.contextActiveDictationPresetID
                )?.name ?? context.contextActiveDictationPresetID
                if context.contextRoutingRules.isEmpty {
                    context.resetContextRoutingRulesToBuiltIn()
                }
            }
            .onChange(of: prompts.selectedPromptPresetID) { _, value in
                if presetSelection != value {
                    presetSelection = value
                }
            }
            .onChange(of: context.contextActiveDictationPresetID) { _, value in
                context.contextSelectedPresetTitle = prompts.promptPreset(by: value)?.name ?? value
            }
            .sheet(isPresented: $showingContextRuleManager) {
                ContextRuleManagerSheet(prefs: prefs, context: context, prompts: prompts)
            }
        }
    }
}

private struct PromptEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 170

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.callout, design: .monospaced))
            .frame(minHeight: minHeight)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}
