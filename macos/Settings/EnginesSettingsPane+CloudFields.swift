import AppKit
import SwiftUI

@MainActor
extension EnginesSettingsPane {
    var cloudASRCommonFields: AnyView {
        AnyView(
            Group {
            TextField("ASR Base URL", text: $engine.cloudASRBaseURL)
                .textFieldStyle(.roundedBorder)
            TextField("ASR Models (comma/newline)", text: $engine.cloudASRModelCatalog, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            HStack(alignment: .center, spacing: 8) {
                Picker("ASR Model", selection: $engine.cloudASRModelName) {
                    ForEach(asrModelOptions, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)

                Button(viewModel.probes.isRefreshingASRModels ? prefs.ui("刷新中...", "Refreshing...") : prefs.ui("刷新模型", "Refresh Models")) {
                    Task {
                        await refreshASRModelsFromProvider()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.probes.isRefreshingASRModels)
            }
            if !viewModel.probes.asrModelStatus.isEmpty {
                Text(viewModel.probes.asrModelStatus)
                    .font(.caption)
                    .foregroundStyle(viewModel.probes.asrModelStatusIsError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
            TextField("ASR Request Path", text: $engine.cloudASRRequestPath)
                .textFieldStyle(.roundedBorder)
            Picker("ASR Auth Mode", selection: $engine.cloudASRAuthMode) {
                ForEach(ProviderAuthMode.allCases) { mode in
                    Text(providerAuthModeLabel(mode)).tag(mode)
                }
            }
            .pickerStyle(.menu)
            TextField(prefs.ui("ASR API 密钥引用", "ASR API Key Ref"), text: $engine.cloudASRApiKeyRef)
                .textFieldStyle(.roundedBorder)
            TextField(prefs.ui("ASR 自定义请求头 JSON", "ASR Custom Headers JSON"), text: $engine.cloudASRHeadersJSON, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            Picker(prefs.ui("ASR 类型", "ASR Kind"), selection: $engine.cloudASRProviderKind) {
                ForEach(ProviderKind.allCases) { kind in
                    Text(providerKindLabel(kind)).tag(kind)
                }
            }
            .pickerStyle(.menu)
            HStack(spacing: 8) {
                Text(prefs.ui("ASR 超时 (秒)", "ASR Timeout (s)"))
                Spacer()
                TextField("", value: $engine.cloudASRTimeoutSec, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                Stepper("", value: $engine.cloudASRTimeoutSec, in: 15...1800, step: 15)
                    .labelsHidden()
            }
            HStack(spacing: 8) {
                Text(prefs.ui("ASR 最大重试次数", "ASR Max Retries"))
                Spacer()
                Stepper(value: $engine.cloudASRMaxRetries, in: 0...8) {
                    Text("\(engine.cloudASRMaxRetries)")
                        .monospacedDigit()
                }
            }
            HStack(spacing: 8) {
                Text(prefs.ui("ASR 最大并发数", "ASR Max In-Flight"))
                Spacer()
                Stepper(value: $engine.cloudASRMaxInFlight, in: 1...8) {
                    Text("\(engine.cloudASRMaxInFlight)")
                        .monospacedDigit()
                }
            }
            Toggle(prefs.ui("启用 ASR 流式传输", "ASR Streaming Enabled"), isOn: $engine.cloudASRStreamingEnabled)
            if engine.asrEngine == .deepgram {
                Picker(prefs.ui("Region", "Region"), selection: $engine.deepgram.region) {
                    ForEach(DeepgramRegionOption.allCases) { region in
                        Text(region.rawValue).tag(region)
                    }
                }
                .pickerStyle(.menu)

                Picker(prefs.ui("转写模式", "Transcription Mode"), selection: $engine.deepgram.transcriptionMode) {
                    ForEach(DeepgramTranscriptionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Text("\(prefs.ui("Endpoint 预览", "Endpoint Preview")): \(deepgramEndpointPreview)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Picker(prefs.ui("语言策略", "Language Strategy"), selection: $engine.cloudASRLanguage) {
                    ForEach(Self.deepgramASRLanguageOptions) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .pickerStyle(.menu)

                if engine.deepgramResolvedLanguage == DeepgramLanguageStrategy.multi.rawValue {
                    Text(DeepgramConfig.deepgramMultiLanguageHint)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text(deepgramModelRecommendationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !deepgramLanguageModelWarning.isEmpty {
                    Text(deepgramLanguageModelWarning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 10) {
                    Button(prefs.ui("预设：中文听写（稳定）", "Preset: Chinese Dictation")) {
                        applyDeepgramChinesePreset()
                    }
                    .buttonStyle(.bordered)

                    Button(prefs.ui("预设：英文会议（高质量）", "Preset: English Meeting")) {
                        applyDeepgramEnglishMeetingPreset()
                    }
                    .buttonStyle(.bordered)
                }

                Toggle("smart_format", isOn: $engine.deepgram.smartFormat)

                Toggle("punctuate", isOn: $engine.deepgram.punctuate)
                    .disabled(engine.deepgram.smartFormat)
                if engine.deepgram.smartFormat {
                    Text(prefs.ui("smart_format 已启用标点，punctuate 参数会被自动忽略。", "smart_format already enables punctuation, so punctuate is ignored."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("paragraphs", isOn: $engine.deepgram.paragraphs)
                Toggle("diarize", isOn: $engine.deepgram.diarize)

                Toggle("interim_results (Streaming)", isOn: $engine.deepgram.interimResults)
                    .disabled(engine.deepgram.transcriptionMode == .batch)
                if engine.deepgram.transcriptionMode == .batch {
                    Text(prefs.ui("当前为 Batch 模式，interim_results 仅在 Streaming 下生效。", "Batch mode selected. interim_results applies only to Streaming mode."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("endpointing", isOn: $engine.deepgram.endpointingEnabled)
                    .disabled(engine.deepgram.transcriptionMode == .batch)
                if engine.deepgram.transcriptionMode == .batch {
                    Text(prefs.ui("Batch 模式不支持 endpointing 参数，已自动忽略。", "Batch mode does not support endpointing and will ignore this parameter."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if engine.deepgram.endpointingEnabled {
                    HStack(spacing: 8) {
                        TextField("endpointing (ms)", value: $engine.deepgram.endpointingMS, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 160)
                        Stepper("", value: $engine.deepgram.endpointingMS, in: 10...10_000, step: 50)
                            .labelsHidden()
                    }
                    Text(prefs.ui("静音达到该时长后，当前片段会被标记为 speech_final=true。", "After this silence duration, Deepgram marks the segment as speech_final=true."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if deepgramTerminologyMode == .keywords {
                    TextField("keywords (comma/newline; supports boosts like GhostType:2)", text: $engine.deepgram.keywords, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField("keyterm (comma/newline)", text: $engine.deepgram.keyterm, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                Picker("ASR Language", selection: $engine.cloudASRLanguage) {
                    ForEach(Self.supportedASRLanguages) { option in
                        Text("\(option.name) (\(option.code))").tag(option.code)
                    }
                }
                .pickerStyle(.menu)
            }
            Button(viewModel.probes.isTestingASRConnection ? prefs.ui("测试中...", "Testing...") : prefs.ui("测试 ASR 连接", "Test ASR Connection")) {
                Task {
                    await testASRConnection()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.probes.isTestingASRConnection)

            if !viewModel.probes.asrConnectionStatus.isEmpty {
                Text(viewModel.probes.asrConnectionStatus)
                    .font(.caption)
                    .foregroundStyle(viewModel.probes.asrConnectionStatusIsError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
            }
        )
    }

    var cloudLLMCommonFields: AnyView {
        AnyView(
            Group {
            TextField("LLM Base URL", text: $engine.cloudLLMBaseURL)
                .textFieldStyle(.roundedBorder)
            TextField("LLM Models (comma/newline)", text: $engine.cloudLLMModelCatalog, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            HStack(alignment: .center, spacing: 8) {
                Picker("LLM Model", selection: $engine.cloudLLMModelName) {
                    ForEach(llmModelOptions, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)

                Button(viewModel.probes.isRefreshingLLMModels ? prefs.ui("刷新中...", "Refreshing...") : prefs.ui("刷新模型", "Refresh Models")) {
                    Task {
                        await refreshLLMModelsFromProvider()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.probes.isRefreshingLLMModels)
            }
            if !viewModel.probes.llmModelStatus.isEmpty {
                Text(viewModel.probes.llmModelStatus)
                    .font(.caption)
                    .foregroundStyle(viewModel.probes.llmModelStatusIsError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
            TextField("LLM Request Path", text: $engine.cloudLLMRequestPath)
                .textFieldStyle(.roundedBorder)
            Picker("LLM Auth Mode", selection: $engine.cloudLLMAuthMode) {
                ForEach(ProviderAuthMode.allCases) { mode in
                    Text(providerAuthModeLabel(mode)).tag(mode)
                }
            }
            .pickerStyle(.menu)
            TextField(prefs.ui("LLM API 密钥引用", "LLM API Key Ref"), text: $engine.cloudLLMApiKeyRef)
                .textFieldStyle(.roundedBorder)
            TextField(prefs.ui("LLM 自定义请求头 JSON", "LLM Custom Headers JSON"), text: $engine.cloudLLMHeadersJSON, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            Picker(prefs.ui("LLM 类型", "LLM Kind"), selection: $engine.cloudLLMProviderKind) {
                ForEach(ProviderKind.allCases) { kind in
                    Text(providerKindLabel(kind)).tag(kind)
                }
            }
            .pickerStyle(.menu)
            HStack(spacing: 8) {
                Text(prefs.ui("LLM 超时 (秒)", "LLM Timeout (s)"))
                Spacer()
                TextField("", value: $engine.cloudLLMTimeoutSec, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                Stepper("", value: $engine.cloudLLMTimeoutSec, in: 15...3600, step: 15)
                    .labelsHidden()
            }
            HStack(spacing: 8) {
                Text(prefs.ui("LLM 最大重试次数", "LLM Max Retries"))
                Spacer()
                Stepper(value: $engine.cloudLLMMaxRetries, in: 0...8) {
                    Text("\(engine.cloudLLMMaxRetries)")
                        .monospacedDigit()
                }
            }
            HStack(spacing: 8) {
                Text(prefs.ui("LLM 最大并发数", "LLM Max In-Flight"))
                Spacer()
                Stepper(value: $engine.cloudLLMMaxInFlight, in: 1...8) {
                    Text("\(engine.cloudLLMMaxInFlight)")
                        .monospacedDigit()
                }
            }
            Toggle(prefs.ui("启用 LLM SSE 流式传输", "LLM SSE Streaming Enabled"), isOn: $engine.cloudLLMStreamingEnabled)
            Button(viewModel.probes.isTestingLLMConnection ? prefs.ui("测试中...", "Testing...") : prefs.ui("测试 LLM 连接", "Test LLM Connection")) {
                Task {
                    await testLLMConnection()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.probes.isTestingLLMConnection)
            if !viewModel.probes.llmConnectionStatus.isEmpty {
                Text(viewModel.probes.llmConnectionStatus)
                    .font(.caption)
                    .foregroundStyle(viewModel.probes.llmConnectionStatusIsError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }

            DisclosureGroup(prefs.ui("模型参数", "Model Parameters")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(prefs.ui("温度 (Temperature)", "Temperature"))
                        Spacer()
                        Text(String(format: "%.2f", engine.llmTemperature))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $engine.llmTemperature, in: 0...2, step: 0.05)
                    Text(prefs.ui(
                        "较低值（如 0.2）输出更确定，较高值（如 1.0）更有创意。",
                        "Lower values (e.g. 0.2) produce more deterministic output; higher (e.g. 1.0) more creative."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(prefs.ui("Top-P", "Top-P"))
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

                VStack(alignment: .leading, spacing: 6) {
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
                    Text(prefs.ui(
                        "LLM 单次响应最大 Token 上限（1–32768）。",
                        "Maximum output tokens per LLM response (1–32768)."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            }
        )
    }

    var localLLMModelOptions: [String] {
        let allowedQuantizations = engine.localLLMShowAdvancedQuantization
            ? Set(["default", "8bit", "4bit", "2bit", "fp16", "fp32", "q8", "q4", "int8", "int4"])
            : Set(["default", "8bit", "4bit", "q8", "q4", "int8", "int4"])
        let filteredPreset = Self.localLLMModelPresets.filter { model in
            allowedQuantizations.contains(localLLMQuantizationTag(for: model))
        }
        return mergedModelOptions(
            preset: filteredPreset,
            discovered: [],
            selected: engine.llmModel
        )
    }

    private func localLLMQuantizationTag(for model: String) -> String {
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let suffixes: [(String, String)] = [
            ("-8bit", "8bit"),
            ("-4bit", "4bit"),
            ("-2bit", "2bit"),
            ("-fp16", "fp16"),
            ("-fp32", "fp32"),
            ("-q8", "q8"),
            ("-q4", "q4"),
            ("-int8", "int8"),
            ("-int4", "int4"),
        ]
        for (suffix, tag) in suffixes {
            if lower.hasSuffix(suffix) {
                return tag
            }
        }
        return "default"
    }

    var asrPresetModels: [String] {
        if engine.asrEngine == .customOpenAICompatible,
           let selected = engine.selectedASRProvider,
           !selected.models.isEmpty {
            return selected.models
        }
        let presets = Self.cloudASRModelPresets[engine.asrEngine] ?? []
        if presets.isEmpty {
            return [engine.asrEngine.defaultModelName]
        }
        return presets
    }

    var llmPresetModels: [String] {
        if engine.llmEngine == .customOpenAICompatible,
           let selected = engine.selectedLLMProvider,
           !selected.models.isEmpty {
            return selected.models
        }
        let presets = Self.cloudLLMModelPresets[engine.llmEngine] ?? []
        if presets.isEmpty {
            return [engine.llmEngine.defaultModelName]
        }
        return presets
    }

    var asrModelOptions: [String] {
        mergedModelOptions(
            preset: asrPresetModels + asrCatalogModels,
            discovered: viewModel.probes.discoveredASRModels,
            selected: engine.cloudASRModelName
        )
    }

    var llmModelOptions: [String] {
        mergedModelOptions(
            preset: llmPresetModels + llmCatalogModels,
            discovered: viewModel.probes.discoveredLLMModels,
            selected: engine.cloudLLMModelName
        )
    }

    var asrCatalogModels: [String] {
        engine.cloudASRModelCatalog
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var llmCatalogModels: [String] {
        engine.cloudLLMModelCatalog
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var deepgramTerminologyMode: DeepgramTerminologyMode {
        DeepgramConfig.terminologyMode(for: engine.cloudASRModelName)
    }

    var deepgramEndpointPreview: String {
        guard let endpointBase = DeepgramConfig.endpointURL(
            baseURLRaw: effectiveASRBaseURL(),
            mode: engine.deepgram.transcriptionMode,
            fallbackRegion: engine.deepgram.region
        ) else {
            return prefs.ui("无效 Base URL", "Invalid Base URL")
        }
        var components = URLComponents(url: endpointBase, resolvingAgainstBaseURL: false)
        components?.queryItems = DeepgramConfig.buildQueryItems(config: engine.deepgramQueryConfig)
        return components?.string ?? endpointBase.absoluteString
    }

    var deepgramModelRecommendationText: String {
        let recommended = DeepgramConfig.recommendedModel(for: engine.deepgramResolvedLanguage)
        if engine.deepgramResolvedLanguage == DeepgramLanguageStrategy.chineseSimplified.rawValue {
            return prefs.ui(
                "当前语言建议模型：\(recommended)。中文场景优先 nova-2。",
                "Recommended model: \(recommended). Chinese is best served by nova-2."
            )
        }
        return prefs.ui(
            "当前语言建议模型：\(recommended)。英文与 multi 场景优先 nova-3。",
            "Recommended model: \(recommended). English and multi are best served by nova-3."
        )
    }

    var deepgramLanguageModelWarning: String {
        let model = engine.cloudASRModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return "" }
        if engine.deepgramResolvedLanguage == DeepgramLanguageStrategy.chineseSimplified.rawValue,
           DeepgramConfig.isNova3Model(model) {
            return prefs.ui(
                "你选择了中文，但模型是 \(model)。建议改为 nova-2 以避免语言覆盖问题。",
                "Chinese is selected, but model is \(model). Use nova-2 for better language coverage."
            )
        }
        if engine.deepgramResolvedLanguage != DeepgramLanguageStrategy.chineseSimplified.rawValue,
           !DeepgramConfig.isNova3Model(model) {
            return prefs.ui(
                "当前语言更适合 nova-3，建议切换模型以提升效果。",
                "The selected language is better served by nova-3. Consider switching models."
            )
        }
        return ""
    }

    func mergedModelOptions(preset: [String], discovered: [String], selected: String) -> [String] {
        var merged = preset + discovered
        let selectedTrimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedTrimmed.isEmpty {
            merged.insert(selectedTrimmed, at: 0)
        }
        var seen = Set<String>()
        var output: [String] = []
        output.reserveCapacity(merged.count)
        for model in merged {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            output.append(trimmed)
        }
        return output
    }

    func syncASRModelPickerOptions() {
        let options = asrModelOptions
        guard let first = options.first else { return }
        let current = engine.cloudASRModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty || !options.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            engine.cloudASRModelName = first
        }
    }

    func syncLLMModelPickerOptions() {
        let options = llmModelOptions
        guard let first = options.first else { return }
        let current = engine.cloudLLMModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty || !options.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            engine.cloudLLMModelName = first
        }
    }

    func syncLocalLLMModelSelection() {
        guard engine.llmEngine == .localMLX else { return }
        let current = engine.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = localLLMModelOptions
        guard let first = options.first else { return }
        if current.isEmpty || !options.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            engine.llmModel = first
        }
    }

    func providerAuthModeLabel(_ mode: ProviderAuthMode) -> String {
        switch mode {
        case .none:
            return "none"
        case .bearer:
            return "bearer"
        case .headers:
            return "headers"
        case .vendorSpecific:
            return "vendorSpecific"
        }
    }

    func providerKindLabel(_ kind: ProviderKind) -> String {
        switch kind {
        case .openAICompatible:
            return "OpenAI-compatible"
        case .genericHTTP:
            return "Generic HTTP"
        }
    }

}
