import SwiftUI

// MARK: - Filter & Sort

enum LocalLLMSortOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"
    case paramScale = "Parameters"
    case recent = "Recently Used"
    var id: String { rawValue }
}

// MARK: - Inline Form-compatible Local LLM Configuration View
// Designed to match the ASR section's flat-list-in-Form style.

@MainActor
struct LocalLLMInlineConfigView: View {
    @ObservedObject var catalog: LocalLLMCatalogStore
    @ObservedObject var engine: EngineConfig
    @ObservedObject var prefs: UserPreferences

    @State private var searchText = ""
    @State private var showAdvancedQuantization: Bool = false
    @State private var showAdvancedInference = false
    @State private var showQuantizationAlert = false
    @State private var alertTargetQuantization = ""

    var body: some View {
        localLLMModelPickerRows
        modelMetaRows
        modelManagementRows
        inferenceParameterRows
    }

    // MARK: - Model Search + Picker

    @ViewBuilder
    private var localLLMModelPickerRows: some View {
        Toggle(
            prefs.ui("显示高级量化（2bit / fp16 / fp32）", "Show advanced quantization (2bit / fp16 / fp32)"),
            isOn: $engine.localLLMShowAdvancedQuantization
        )

        TextField(
            prefs.ui("搜索本地模型", "Search local LLM models"),
            text: $searchText
        )
        .textFieldStyle(.roundedBorder)

        if filteredModels.isEmpty {
            Text(prefs.ui("无匹配模型。", "No matching models."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker(
                prefs.ui("本地模型", "Local Model"),
                selection: $engine.llmModel
            ) {
                ForEach(filteredModels, id: \.self) { model in
                    Text(shortModelName(model)).tag(model)
                }
            }
            .pickerStyle(.menu)
        }

        // Quantization switcher — same pattern as ASR "Choose quantization" Menu
        let currentQuant = localLLMQuantizationTag(for: engine.llmModel)
        Menu {
            ForEach(quantizationChoices, id: \.value) { choice in
                Button {
                    applyQuantization(choice.value)
                } label: {
                    if choice.value == currentQuant {
                        Label(choice.displayName, systemImage: "checkmark")
                    } else {
                        Text(choice.displayName)
                    }
                }
            }
        } label: {
            Label(
                prefs.ui(
                    "选择模型量化：\(quantizationDisplayName(currentQuant))",
                    "Choose quantization: \(quantizationDisplayName(currentQuant))"
                ),
                systemImage: "dial.medium"
            )
        }
        .menuStyle(.borderlessButton)
        .alert(
            prefs.ui("未找到对应量化版本", "Quantization variant not found"),
            isPresented: $showQuantizationAlert
        ) {
            Button(prefs.ui("选最近可用版本", "Use Closest Available")) {
                applyClosestQuantization(target: alertTargetQuantization)
            }
            Button(prefs.ui("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(prefs.ui(
                "当前模型没有 \(alertTargetQuantization) 的变体，将切换到最接近的可用量化。",
                "No \(alertTargetQuantization) variant found. The closest available will be selected."
            ))
        }
    }

    // MARK: - Model Meta Info

    @ViewBuilder
    private var modelMetaRows: some View {
        let entry = catalog.entries.first(where: { $0.repoId == engine.llmModel })
        Text("Repo: \(engine.llmModel)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        if let entry {
            if let paramScale = entry.paramScale {
                Text(prefs.ui("参数规模：\(paramScale)", "Parameters: \(paramScale)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let sizeStr = entry.sizeBytesEstimate != nil ? entry.sizeDisplayString : prefs.ui("大小未知（点击刷新目录获取）", "Size unknown — refresh catalog")
            Text(prefs.ui("预计磁盘占用：\(sizeStr)", "Est. disk usage: \(sizeStr)"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let license = entry.license {
                Text(prefs.ui("许可证：\(license)", "License: \(license)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let ctx = entry.contextLength {
                Text(prefs.ui("上下文长度：\(ctx.formatted()) tokens", "Context length: \(ctx.formatted()) tokens"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let hasCT = entry.hasChatTemplate {
                Text(hasCT
                    ? prefs.ui("Chat Template：可用", "Chat Template: Available")
                    : prefs.ui("Chat Template：未检测到", "Chat Template: Not detected"))
                    .font(.caption)
                    .foregroundStyle(hasCT ? Color.secondary : Color.orange)
            }
            let downloadStatus = catalog.downloadingRepos.contains(engine.llmModel)
                ? prefs.ui("下载中", "Downloading")
                : entry.downloadStatus == .ready
                    ? prefs.ui("已就绪", "Ready")
                    : prefs.ui("未下载（MLX 将在首次使用时自动下载）", "Not downloaded (MLX will fetch on first use)")
            Text(prefs.ui("状态：\(downloadStatus)", "Status: \(downloadStatus)"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Download / Manage

    @ViewBuilder
    private var modelManagementRows: some View {
        Text(prefs.ui("模型管理", "Model Management"))
            .font(.subheadline.weight(.semibold))

        // Download progress bar (only when downloading)
        if catalog.downloadingRepos.contains(engine.llmModel) {
            let progress = catalog.downloadProgress[engine.llmModel] ?? 0
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress > 0 ? progress : nil)
                    .progressViewStyle(.linear)
                if progress > 0 {
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }

        // Error message
        if let error = catalog.downloadErrors[engine.llmModel], !error.isEmpty {
            Text(prefs.ui("错误：\(error)", "Error: \(error)"))
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }

        HStack(spacing: 8) {
            let isDownloading = catalog.downloadingRepos.contains(engine.llmModel)

            // Download button
            Button(
                isDownloading
                    ? prefs.ui("下载中...", "Downloading...")
                    : prefs.ui("下载并预热当前模型", "Download & Warm Up")
            ) {
                Task { await catalog.startDownload(repoId: engine.llmModel) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDownloading)

            // Cancel download
            if isDownloading {
                Button(prefs.ui("取消下载", "Cancel Download"), role: .destructive) {
                    Task { await catalog.cancelDownload(repoId: engine.llmModel) }
                }
                .buttonStyle(.bordered)
            } else {
                // Clear cache
                Button(
                    prefs.ui("清理当前模型缓存", "Clear Model Cache"),
                    role: .destructive
                ) {
                    Task { await catalog.deleteModel(repoId: engine.llmModel) }
                }
                .buttonStyle(.bordered)
            }

            Button(prefs.ui("在 Finder 中显示缓存", "Reveal Cache in Finder")) {
                catalog.openCacheDirectory()
            }
            .buttonStyle(.bordered)
        }

        // Refresh catalog from HF
        Button(
            catalog.isRefreshing
                ? prefs.ui("刷新中...", "Refreshing...")
                : prefs.ui("刷新模型目录（Hugging Face）", "Refresh Catalog (Hugging Face)")
        ) {
            Task { await catalog.refreshFromHuggingFace() }
        }
        .buttonStyle(.bordered)
        .disabled(catalog.isRefreshing)

        if !catalog.catalogStatus.isEmpty {
            Text(catalog.catalogStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Inference Parameters

    @ViewBuilder
    private var inferenceParameterRows: some View {
        DisclosureGroup(
            prefs.ui("推理参数", "Inference Parameters"),
            isExpanded: $showAdvancedInference
        ) {
            // Temperature
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(String(format: "%.2f", engine.llmTemperature))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $engine.llmTemperature, in: 0...2, step: 0.05)
                Text(prefs.ui(
                    "低值（如 0.2）输出更确定，高值（如 1.0）更有创意。",
                    "Lower values (e.g. 0.2) produce more deterministic output; higher (e.g. 1.0) more creative."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Top-P
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Top-P")
                    Spacer()
                    Text(String(format: "%.2f", engine.llmTopP))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $engine.llmTopP, in: 0...1, step: 0.05)
                Text(prefs.ui(
                    "控制 nucleus sampling，通常保持 0.9–1.0。",
                    "Controls nucleus sampling. Typically kept at 0.9–1.0."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Max Tokens
            HStack(spacing: 8) {
                Text(prefs.ui("最大 Token 数", "Max Tokens"))
                Spacer()
                TextField("", value: $engine.llmMaxTokens, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $engine.llmMaxTokens, in: 1...32768, step: 256)
                    .labelsHidden()
            }

            // Repetition penalty
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(prefs.ui("重复惩罚", "Repetition Penalty"))
                    Spacer()
                    Text(String(format: "%.2f", engine.llmRepetitionPenalty))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $engine.llmRepetitionPenalty, in: 1.0...2.0, step: 0.05)
                Text(prefs.ui(
                    "惩罚重复词汇，1.0 表示无惩罚。",
                    "Penalizes repeated tokens; 1.0 = no penalty."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Seed
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Seed")
                    Text(prefs.ui("设为 -1 则随机", "Set to -1 for random"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("", value: $engine.llmSeed, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                    .multilineTextAlignment(.trailing)
            }

            // Stop sequences
            VStack(alignment: .leading, spacing: 4) {
                Text(prefs.ui("Stop Sequences", "Stop Sequences"))
                TextField(
                    prefs.ui("用逗号分隔", "Comma-separated"),
                    text: $engine.llmStopSequences,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...3)
            }

            // Memory saving
            Toggle(
                prefs.ui("内存节省模式（减少 KV Cache 占用）", "Memory Saving Mode (reduce KV cache usage)"),
                isOn: $engine.llmMemorySavingMode
            )
        }
    }

    // MARK: - Helpers

    private var filteredModels: [String] {
        let allowedQuantizations: Set<String> = engine.localLLMShowAdvancedQuantization
            ? ["default", "8bit", "4bit", "2bit", "fp16", "fp32", "q8", "q4", "int8", "int4"]
            : ["default", "8bit", "4bit", "q8", "q4", "int8", "int4"]

        var models = EngineSettingsCatalog.localLLMModelPresets.filter {
            allowedQuantizations.contains(localLLMQuantizationTag(for: $0))
        }

        if !searchText.isEmpty {
            let q = searchText.lowercased()
            models = models.filter { $0.lowercased().contains(q) }
        }

        // Make sure the currently selected model is always present
        let current = engine.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, !models.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            models.insert(current, at: 0)
        }

        // deduplicate
        var seen = Set<String>()
        return models.filter { seen.insert($0.lowercased()).inserted }
    }

    private func shortModelName(_ repoId: String) -> String {
        let parts = repoId.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : repoId
    }

    private func localLLMQuantizationTag(for model: String) -> String {
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let suffixes: [(String, String)] = [
            ("-8bit", "8bit"), ("-4bit", "4bit"), ("-2bit", "2bit"),
            ("-fp16", "fp16"), ("-fp32", "fp32"),
            ("-q8", "q8"), ("-q4", "q4"), ("-int8", "int8"), ("-int4", "int4"),
        ]
        for (suffix, tag) in suffixes {
            if lower.hasSuffix(suffix) { return tag }
        }
        return "default"
    }

    private func quantizationDisplayName(_ tag: String) -> String {
        switch tag {
        case "8bit", "int8", "q8": return "8-bit"
        case "4bit", "int4", "q4": return "4-bit"
        case "2bit": return "2-bit"
        case "fp16": return "FP16"
        case "fp32": return "FP32"
        default: return "Default"
        }
    }

    private struct QuantChoice {
        let value: String
        let displayName: String
    }

    private var quantizationChoices: [QuantChoice] {
        let current = engine.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return [] }

        let familyBase = familyKey(for: current)
        let sameFamily = filteredModels.filter {
            familyKey(for: $0).caseInsensitiveCompare(familyBase) == .orderedSame
        }

        var seen = Set<String>()
        var choices: [QuantChoice] = []
        for model in sameFamily {
            let tag = localLLMQuantizationTag(for: model)
            guard seen.insert(tag).inserted else { continue }
            choices.append(QuantChoice(value: tag, displayName: quantizationDisplayName(tag)))
        }
        if choices.isEmpty {
            let tag = localLLMQuantizationTag(for: current)
            choices = [QuantChoice(value: tag, displayName: quantizationDisplayName(tag))]
        }
        return choices
    }

    private func familyKey(for model: String) -> String {
        var name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Strip publisher prefix
        if let slashIdx = name.firstIndex(of: "/") {
            name = String(name[name.index(after: slashIdx)...])
        }
        // Strip quantization suffix
        let suffixes = ["-8bit", "-4bit", "-2bit", "-fp16", "-fp32", "-q8", "-q4", "-int8", "-int4"]
        for suffix in suffixes {
            if name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        return name
    }

    private func applyQuantization(_ quantization: String) {
        let current = engine.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return }

        let familyBase = familyKey(for: current)
        // Find a model in the filtered list with the same family and requested quantization
        if let match = filteredModels.first(where: {
            familyKey(for: $0).caseInsensitiveCompare(familyBase) == .orderedSame &&
            localLLMQuantizationTag(for: $0).lowercased() == quantization.lowercased()
        }) {
            engine.llmModel = match
        } else {
            alertTargetQuantization = quantizationDisplayName(quantization)
            showQuantizationAlert = true
        }
    }

    private func applyClosestQuantization(target: String) {
        let current = engine.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let familyBase = familyKey(for: current)
        let sameFamily = filteredModels.filter {
            familyKey(for: $0).caseInsensitiveCompare(familyBase) == .orderedSame
        }
        // Prefer 4bit → 8bit → default → fp16 → fp32 → 2bit
        let preference = ["4bit", "8bit", "default", "fp16", "fp32", "2bit"]
        for pref in preference {
            if let match = sameFamily.first(where: {
                localLLMQuantizationTag(for: $0).lowercased() == pref
            }) {
                engine.llmModel = match
                return
            }
        }
        // Fall back to first in family
        if let first = sameFamily.first {
            engine.llmModel = first
        }
    }
}
