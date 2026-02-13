import Foundation

@MainActor
extension EnginesSettingsPane {
    func refreshASRModelsFromProvider() async {
        guard engine.asrEngine != .localMLX else { return }
        viewModel.probes.isRefreshingASRModels = true
        viewModel.probes.asrModelStatusIsError = false
        viewModel.probes.asrModelStatus = prefs.ui("正在从接口读取 ASR 模型列表...", "Fetching ASR model list from provider...")
        defer { viewModel.probes.isRefreshingASRModels = false }

        do {
            let remote = try await discoverASRModels()
            viewModel.probes.discoveredASRModels = remote
            syncASRModelPickerOptions()
            if remote.isEmpty {
                viewModel.probes.asrModelStatus = prefs.ui("接口未返回模型，已使用预设列表。", "Provider returned no models. Using preset list.")
            } else {
                viewModel.probes.asrModelStatus = prefs.ui("已从接口读取 \(remote.count) 个 ASR 模型。", "Loaded \(remote.count) ASR models from provider.")
            }
            AppLogger.shared.log("ASR model list refreshed. count=\(remote.count)")
        } catch {
            viewModel.probes.asrModelStatusIsError = true
            viewModel.probes.asrModelStatus = prefs.ui("读取 ASR 模型失败：\(error.localizedDescription)", "Failed to fetch ASR models: \(error.localizedDescription)")
            AppLogger.shared.log("Failed to refresh ASR models: \(error.localizedDescription)", type: .error)
        }
    }

    @MainActor
    func refreshLLMModelsFromProvider() async {
        guard engine.llmEngine != .localMLX else { return }
        viewModel.probes.isRefreshingLLMModels = true
        viewModel.probes.llmModelStatusIsError = false
        viewModel.probes.llmModelStatus = prefs.ui("正在从接口读取 LLM 模型列表...", "Fetching LLM model list from provider...")
        defer { viewModel.probes.isRefreshingLLMModels = false }

        do {
            let remote = try await discoverLLMModels()
            viewModel.probes.discoveredLLMModels = remote
            syncLLMModelPickerOptions()
            if remote.isEmpty {
                viewModel.probes.llmModelStatus = prefs.ui("接口未返回模型，已使用预设列表。", "Provider returned no models. Using preset list.")
            } else {
                viewModel.probes.llmModelStatus = prefs.ui("已从接口读取 \(remote.count) 个 LLM 模型。", "Loaded \(remote.count) LLM models from provider.")
            }
            AppLogger.shared.log("LLM model list refreshed. count=\(remote.count)")
        } catch {
            viewModel.probes.llmModelStatusIsError = true
            viewModel.probes.llmModelStatus = prefs.ui("读取 LLM 模型失败：\(error.localizedDescription)", "Failed to fetch LLM models: \(error.localizedDescription)")
            AppLogger.shared.log("Failed to refresh LLM models: \(error.localizedDescription)", type: .error)
        }
    }

    @MainActor
    func testASRConnection() async {
        guard engine.asrEngine != .localMLX else { return }
        guard !viewModel.probes.isTestingASRConnection else { return }
        viewModel.probes.isTestingASRConnection = true
        viewModel.probes.asrConnectionStatusIsError = false
        viewModel.probes.asrConnectionStatus = prefs.ui("正在测试 ASR 连接...", "Testing ASR connection...")
        defer { viewModel.probes.isTestingASRConnection = false }

        do {
            let summary = try await runASRConnectionProbe()
            viewModel.probes.asrConnectionStatus = prefs.ui("连接成功：\(summary)", "Connection successful: \(summary)")
            viewModel.probes.asrConnectionStatusIsError = false
            AppLogger.shared.log("ASR connection test passed: \(summary)")
        } catch {
            viewModel.probes.asrConnectionStatus = prefs.ui("连接失败：\(error.localizedDescription)", "Connection failed: \(error.localizedDescription)")
            viewModel.probes.asrConnectionStatusIsError = true
            AppLogger.shared.log("ASR connection test failed: \(error.localizedDescription)", type: .error)
        }
    }

    @MainActor
    func testLLMConnection() async {
        guard engine.llmEngine != .localMLX else { return }
        guard !viewModel.probes.isTestingLLMConnection else { return }
        viewModel.probes.isTestingLLMConnection = true
        viewModel.probes.llmConnectionStatusIsError = false
        viewModel.probes.llmConnectionStatus = prefs.ui("正在测试 LLM 连接...", "Testing LLM connection...")
        defer { viewModel.probes.isTestingLLMConnection = false }

        do {
            let output = try await runLLMConnectionProbe()
            viewModel.probes.llmConnectionStatus = prefs.ui("连接成功，模型输出：\(output)", "Connection successful, model output: \(output)")
            viewModel.probes.llmConnectionStatusIsError = false
            AppLogger.shared.log("LLM connection test passed. output=\(output)")
        } catch {
            viewModel.probes.llmConnectionStatus = prefs.ui("连接失败：\(error.localizedDescription)", "Connection failed: \(error.localizedDescription)")
            viewModel.probes.llmConnectionStatusIsError = true
            AppLogger.shared.log("LLM connection test failed: \(error.localizedDescription)", type: .error)
        }
    }

    func discoverASRModels() async throws -> [String] {
        switch engine.asrEngine {
        case .localHTTPOpenAIAudio:
            let models = try await EngineProbeClient.fetchOpenAIModelIDs(
                baseURLRaw: effectiveASRBaseURL(),
                apiKey: "local-http-probe"
            )
            let filtered = models.filter { model in
                let lower = model.lowercased()
                return lower.contains("whisper") || lower.contains("transcrib") || lower.contains("speech")
            }
            return filtered.isEmpty ? models : filtered
        case .openAIWhisper, .groq:
            let models = try await EngineProbeClient.fetchOpenAIModelIDs(
                baseURLRaw: effectiveASRBaseURL(),
                apiKey: try requiredASRAPIKey(for: engine.asrEngine)
            )
            let filtered = models.filter { model in
                let lower = model.lowercased()
                return lower.contains("whisper") || lower.contains("transcrib") || lower.contains("speech")
            }
            return filtered.isEmpty ? models : filtered
        case .geminiMultimodal:
            let models = try await EngineProbeClient.fetchGeminiModelIDs(
                baseURLRaw: effectiveASRBaseURL(),
                apiKey: try requiredASRAPIKey(for: .geminiMultimodal)
            )
            let filtered = models.filter { $0.lowercased().contains("gemini") }
            return filtered.isEmpty ? models : filtered
        case .customOpenAICompatible:
            guard engine.cloudASRAuthMode == .bearer else {
                return []
            }
            let models = try await EngineProbeClient.fetchOpenAIModelIDs(
                baseURLRaw: effectiveASRBaseURL(),
                apiKey: try requiredASRAPIKey(for: .customOpenAICompatible)
            )
            let filtered = models.filter { model in
                let lower = model.lowercased()
                return lower.contains("whisper") || lower.contains("transcrib") || lower.contains("speech")
            }
            return filtered.isEmpty ? models : filtered
        case .deepgram, .assemblyAI, .localMLX:
            return []
        }
    }

    func discoverLLMModels() async throws -> [String] {
        switch engine.llmEngine {
        case .openAI, .openAICompatible, .deepSeek, .groq:
            let models = try await EngineProbeClient.fetchOpenAIModelIDs(
                baseURLRaw: effectiveLLMBaseURL(),
                apiKey: try requiredLLMAPIKey(for: engine.llmEngine)
            )
            let filtered = models.filter { model in
                let lower = model.lowercased()
                return !lower.contains("embedding")
                    && !lower.contains("audio")
                    && !lower.contains("whisper")
                    && !lower.contains("tts")
            }
            return filtered.isEmpty ? models : filtered
        case .customOpenAICompatible:
            guard engine.cloudLLMAuthMode == .bearer else {
                return []
            }
            let models = try await EngineProbeClient.fetchOpenAIModelIDs(
                baseURLRaw: effectiveLLMBaseURL(),
                apiKey: try requiredLLMAPIKey(for: .customOpenAICompatible)
            )
            let filtered = models.filter { model in
                let lower = model.lowercased()
                return !lower.contains("embedding")
                    && !lower.contains("audio")
                    && !lower.contains("whisper")
                    && !lower.contains("tts")
            }
            return filtered.isEmpty ? models : filtered
        case .anthropic:
            return try await EngineProbeClient.fetchAnthropicModelIDs(
                baseURLRaw: effectiveLLMBaseURL(),
                apiKey: try requiredLLMAPIKey(for: .anthropic)
            )
        case .gemini:
            return try await EngineProbeClient.fetchGeminiModelIDs(
                baseURLRaw: effectiveLLMBaseURL(),
                apiKey: try requiredLLMAPIKey(for: .gemini)
            )
        case .azureOpenAI, .localMLX:
            return []
        }
    }

    func runASRConnectionProbe() async throws -> String {
        switch engine.asrEngine {
        case .localHTTPOpenAIAudio:
            return try await runLocalHTTPASRConnectionProbe()
        case .openAIWhisper, .groq:
            let models = try await discoverASRModels()
            let preview = previewModels(models)
            return prefs.ui("已鉴权，模型 \(models.count) 个。\(preview)", "Authenticated. \(models.count) model(s). \(preview)")
        case .deepgram:
            let apiKey = try requiredASRAPIKey(for: .deepgram)
            let config = engine.deepgramQueryConfig
            switch engine.deepgram.transcriptionMode {
            case .batch:
                return try await EngineProbeClient.runDeepgramBatchProbe(
                    baseURLRaw: effectiveASRBaseURL(),
                    apiKey: apiKey,
                    queryConfig: config,
                    region: engine.deepgram.region
                )
            case .streaming:
                return try await EngineProbeClient.runDeepgramStreamingProbe(
                    baseURLRaw: effectiveASRBaseURL(),
                    apiKey: apiKey,
                    queryConfig: config,
                    region: engine.deepgram.region
                )
            }
        case .assemblyAI:
            let count = try await EngineProbeClient.fetchAssemblyAITranscriptCount(
                baseURLRaw: effectiveASRBaseURL(),
                apiKey: try requiredASRAPIKey(for: .assemblyAI)
            )
            return prefs.ui("AssemblyAI 鉴权成功，最近记录=\(count)", "AssemblyAI authentication succeeded, recent transcripts=\(count)")
        case .geminiMultimodal:
            let models = try await discoverASRModels()
            let preview = previewModels(models)
            return prefs.ui("Gemini ASR 鉴权成功，模型 \(models.count) 个。\(preview)", "Gemini ASR authentication succeeded. \(models.count) model(s). \(preview)")
        case .customOpenAICompatible:
            if engine.cloudASRAuthMode == .bearer {
                let models = try await discoverASRModels()
                let preview = previewModels(models)
                return prefs.ui("自定义 ASR 鉴权成功，模型 \(models.count) 个。\(preview)", "Custom ASR authenticated. \(models.count) model(s). \(preview)")
            }
            return prefs.ui(
                "当前鉴权模式无需 Bearer 自动探测，配置已保存。",
                "Current auth mode skips bearer auto-probe. Configuration is saved."
            )
        case .localMLX:
            return prefs.ui("本地模式无需 API 连接测试。", "Local mode does not require API connection testing.")
        }
    }

    func runLLMConnectionProbe() async throws -> String {
        let model = resolvedLLMModelName()
        switch engine.llmEngine {
        case .openAI, .deepSeek, .groq:
            return try await EngineProbeClient.runOpenAIChatProbe(
                baseURLRaw: effectiveLLMBaseURL(),
                apiKey: try requiredLLMAPIKey(for: engine.llmEngine),
                model: model,
                allowResponsesFallback: false
            )
        case .openAICompatible:
            return try await EngineProbeClient.runOpenAIChatProbe(
                baseURLRaw: effectiveLLMBaseURL(),
                apiKey: try requiredLLMAPIKey(for: .openAICompatible),
                model: model,
                allowResponsesFallback: true
            )
        case .customOpenAICompatible:
            if engine.cloudLLMAuthMode == .bearer {
                return try await EngineProbeClient.runOpenAIChatProbe(
                    baseURLRaw: effectiveLLMBaseURL(),
                    apiKey: try requiredLLMAPIKey(for: .customOpenAICompatible),
                    model: model,
                    allowResponsesFallback: true
                )
            }
            return prefs.ui(
                "当前鉴权模式无需 Bearer 自动探测，配置已保存。",
                "Current auth mode skips bearer auto-probe. Configuration is saved."
            )
        case .azureOpenAI:
            return try await EngineProbeClient.runAzureOpenAIProbe(
                baseURLRaw: effectiveLLMBaseURL(),
                apiKey: try requiredLLMAPIKey(for: .azureOpenAI),
                deployment: model,
                apiVersion: resolvedAzureAPIVersion()
            )
        case .anthropic:
            return try await EngineProbeClient.runAnthropicProbe(
                baseURLRaw: effectiveLLMBaseURL(),
                apiKey: try requiredLLMAPIKey(for: .anthropic),
                model: model
            )
        case .gemini:
            return try await EngineProbeClient.runGeminiProbe(
                baseURLRaw: effectiveLLMBaseURL(),
                apiKey: try requiredLLMAPIKey(for: .gemini),
                model: model
            )
        case .localMLX:
            return prefs.ui("本地模式无需 API 连接测试。", "Local mode does not require API connection testing.")
        }
    }

    func previewModels(_ models: [String]) -> String {
        guard !models.isEmpty else { return prefs.ui("模型列表为空。", "Model list is empty.") }
        return prefs.ui("示例：\(models.prefix(3).joined(separator: ", "))", "Examples: \(models.prefix(3).joined(separator: ", "))")
    }

    func effectiveASRBaseURL() -> String {
        let configured: String
        if engine.asrEngine == .localHTTPOpenAIAudio {
            configured = engine.localHTTPASRBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            configured = engine.cloudASRBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if configured.isEmpty {
            if engine.asrEngine == .deepgram {
                return engine.deepgram.region.defaultHTTPSBaseURL
            }
            return engine.asrEngine.defaultBaseURL
        }
        return configured
    }

    func effectiveLLMBaseURL() -> String {
        let configured = engine.cloudLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if configured.isEmpty {
            return engine.llmEngine.defaultBaseURL
        }
        return configured
    }

    func resolvedLLMModelName() -> String {
        let configured = engine.cloudLLMModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if configured.isEmpty {
            return engine.llmEngine.defaultModelName
        }
        return configured
    }

    func resolvedAzureAPIVersion() -> String {
        let configured = engine.cloudLLMAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? "2024-02-01" : configured
    }

    func requiredASRAPIKey(for engineOption: ASREngineOption) throws -> String {
        let value: String
        let label: String
        switch engineOption {
        case .openAIWhisper:
            value = resolvedSecret(fromInput: viewModel.credentialDrafts.asrOpenAIKey, keychainKey: .asrOpenAI)
            label = "OpenAI ASR"
        case .deepgram:
            value = resolvedSecret(fromInput: viewModel.credentialDrafts.asrDeepgramKey, keychainKey: .asrDeepgram)
            label = "Deepgram ASR"
        case .assemblyAI:
            value = resolvedSecret(fromInput: viewModel.credentialDrafts.asrAssemblyAIKey, keychainKey: .asrAssemblyAI)
            label = "AssemblyAI ASR"
        case .groq:
            value = resolvedSecret(fromInput: viewModel.credentialDrafts.asrGroqKey, keychainKey: .asrGroq)
            label = "Groq ASR"
        case .geminiMultimodal:
            value = resolvedSecret(fromInput: viewModel.credentialDrafts.llmGeminiKey, keychainKey: .llmGemini)
            label = "Gemini (Shared)"
        case .customOpenAICompatible:
            if self.engine.cloudASRAuthMode == .bearer {
                value = resolvedSecretFromRef(
                    fromInput: viewModel.credentialDrafts.asrCustomProviderKey,
                    keyRef: self.engine.cloudASRApiKeyRef
                )
            } else {
                value = "no-key-required"
            }
            label = "Custom ASR"
        case .localHTTPOpenAIAudio:
            value = "no-key-required"
            label = "Local HTTP ASR"
        case .localMLX:
            value = ""
            label = "Local MLX"
        }
        guard !value.isEmpty else {
            throw EngineProbeClient.ProbeError.missingAPIKey(label)
        }
        return value
    }

    private func runLocalHTTPASRConnectionProbe() async throws -> String {
        let baseURLRaw = effectiveASRBaseURL()
        let normalizedRaw: String
        if baseURLRaw.contains("://") {
            normalizedRaw = baseURLRaw
        } else {
            normalizedRaw = "http://\(baseURLRaw)"
        }
        guard let baseURL = URL(string: normalizedRaw) else {
            throw EngineProbeClient.ProbeError.invalidBaseURL(baseURLRaw)
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let suffix = "v1/audio/transcriptions"
        components?.path = basePath.isEmpty ? "/\(suffix)" : "/\(basePath)/\(suffix)"
        guard let endpoint = components?.url else {
            throw EngineProbeClient.ProbeError.invalidBaseURL(baseURLRaw)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        let configuredModel = engine.localHTTPASRModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = configuredModel.isEmpty
            ? engine.localASRProvider.defaultHTTPModelName
            : configuredModel
        if !modelName.isEmpty {
            appendField("model", modelName)
        }

        let sample = makeSilentWAVSample(durationMS: 280)
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"probe.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(sample)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EngineProbeClient.ProbeError.invalidHTTPResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw EngineProbeClient.ProbeError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let text = ((object["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return prefs.ui("返回示例：\(text)", "Transcript sample: \(text)")
            }
        }
        return prefs.ui("连接成功，服务返回 2xx。", "Connection successful (2xx response).")
    }

    private func makeSilentWAVSample(
        durationMS: Int,
        sampleRate: Int = 16_000,
        channels: Int = 1,
        bitsPerSample: Int = 16
    ) -> Data {
        let frameCount = max(1, durationMS * sampleRate / 1_000)
        let bytesPerSample = bitsPerSample / 8
        let dataSize = frameCount * channels * bytesPerSample
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample

        var wav = Data()
        wav.append(Data("RIFF".utf8))
        wav.append(littleEndianUInt32(UInt32(36 + dataSize)))
        wav.append(Data("WAVE".utf8))
        wav.append(Data("fmt ".utf8))
        wav.append(littleEndianUInt32(16))
        wav.append(littleEndianUInt16(1))
        wav.append(littleEndianUInt16(UInt16(channels)))
        wav.append(littleEndianUInt32(UInt32(sampleRate)))
        wav.append(littleEndianUInt32(UInt32(byteRate)))
        wav.append(littleEndianUInt16(UInt16(blockAlign)))
        wav.append(littleEndianUInt16(UInt16(bitsPerSample)))
        wav.append(Data("data".utf8))
        wav.append(littleEndianUInt32(UInt32(dataSize)))
        wav.append(Data(repeating: 0, count: dataSize))
        return wav
    }

    private func littleEndianUInt16(_ value: UInt16) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: MemoryLayout<UInt16>.size)
    }

    private func littleEndianUInt32(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: MemoryLayout<UInt32>.size)
    }

    func requiredLLMAPIKey(for engineOption: LLMEngineOption) throws -> String {
        let value: String
        let label: String
        switch engineOption {
        case .openAI:
            value = resolvedSecret(fromInput: viewModel.credentialDrafts.llmOpenAIKey, keychainKey: .llmOpenAI)
            label = "OpenAI LLM"
        case .openAICompatible:
            value = resolvedSecret(fromInput: viewModel.credentialDrafts.llmOpenAICompatibleKey, keychainKey: .llmOpenAICompatible)
            label = "OpenAI-Compatible LLM"
        case .customOpenAICompatible:
            if self.engine.cloudLLMAuthMode == .bearer {
                value = resolvedSecretFromRef(
                    fromInput: viewModel.credentialDrafts.llmCustomProviderKey,
                    keyRef: self.engine.cloudLLMApiKeyRef
                )
            } else {
                value = "no-key-required"
            }
            label = "Custom LLM"
        case .azureOpenAI:
            value = resolvedSecret(fromInput: viewModel.credentialDrafts.llmAzureOpenAIKey, keychainKey: .llmAzureOpenAI)
            label = "Azure OpenAI LLM"
        case .anthropic:
            value = resolvedSecret(fromInput: viewModel.credentialDrafts.llmAnthropicKey, keychainKey: .llmAnthropic)
            label = "Anthropic LLM"
        case .gemini:
            value = resolvedSecret(fromInput: viewModel.credentialDrafts.llmGeminiKey, keychainKey: .llmGemini)
            label = "Gemini LLM"
        case .deepSeek:
            value = resolvedSecret(fromInput: viewModel.credentialDrafts.llmDeepSeekKey, keychainKey: .llmDeepSeek)
            label = "DeepSeek LLM"
        case .groq:
            value = resolvedSecret(fromInput: viewModel.credentialDrafts.llmGroqKey, keychainKey: .llmGroq)
            label = "Groq LLM"
        case .localMLX:
            value = ""
            label = "Local MLX"
        }
        guard !value.isEmpty else {
            throw EngineProbeClient.ProbeError.missingAPIKey(label)
        }
        return value
    }

    func resolvedSecret(fromInput input: String, keychainKey: APISecretKey) -> String {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            return typed
        }
        return (try? AppKeychain.shared.getSecret(for: keychainKey, policy: .noUserInteraction))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func resolvedSecretFromRef(fromInput input: String, keyRef: String) -> String {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            return typed
        }
        let trimmedRef = keyRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRef.isEmpty else { return "" }
        return (try? AppKeychain.shared.getSecret(forRef: trimmedRef, policy: .noUserInteraction))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

}
