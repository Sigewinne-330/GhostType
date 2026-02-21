import AppKit
import Foundation

extension InferenceCoordinator {
    private struct PendingQualityPass {
        let request: InferenceRequest
        let recordingSessionID: UUID
        let fastOutput: String
        let targetApp: NSRunningApplication?
    }

    func apiRouteDescription(for mode: WorkflowMode) -> String {
        let asrIsLocal = state.asrEngine == .localMLX
        let llmIsLocal = state.llmEngine == .localMLX
        if asrIsLocal && llmIsLocal {
            switch mode {
            case .dictate:
                return "/dictate/stream (local)"
            case .ask:
                return "/ask/stream (local)"
            case .translate:
                return "/translate/stream (local)"
            }
        }

        if asrIsLocal != llmIsLocal {
            let asrLabel = asrIsLocal ? "Local ASR" : "Cloud ASR"
            let llmLabel = llmIsLocal ? "Local LLM" : "Cloud LLM"
            return "Hybrid (\(asrLabel) + \(llmLabel)) [mode=\(mode.rawValue)]"
        }

        let providerRoute = cloudProviderRouteLabel()
        return "\(providerRoute) [mode=\(mode.rawValue)]"
    }

    private func cloudProviderRouteLabel() -> String {
        switch state.llmEngine {
        case .gemini:
            return "Gemini/Flash"
        case .anthropic:
            return "Anthropic Messages API"
        case .azureOpenAI:
            return "Azure OpenAI ChatCompletions"
        case .deepSeek:
            return "DeepSeek OpenAI-Compatible API"
        case .groq:
            return "Groq OpenAI-Compatible API"
        case .openAICompatible:
            return "OpenAI-Compatible ChatCompletions"
        case .customOpenAICompatible:
            return "Custom OpenAI-Compatible API"
        case .openAI:
            return "OpenAI ChatCompletions"
        case .ollama:
            return "Ollama OpenAI-Compatible API"
        case .lmStudio:
            return "LM Studio OpenAI-Compatible API"
        case .localMLX:
            return "Cloud ChatCompletions"
        }
    }

    private func keyForASREngine(_ engine: ASREngineOption) -> APISecretKey? {
        switch engine {
        case .localMLX:
            return nil
        case .localHTTPOpenAIAudio:
            return nil
        case .openAIWhisper:
            return .asrOpenAI
        case .deepgram:
            return .asrDeepgram
        case .assemblyAI:
            return .asrAssemblyAI
        case .groq:
            return .asrGroq
        case .geminiMultimodal:
            return .llmGemini
        case .customOpenAICompatible:
            return nil
        }
    }

    private func keyForLLMEngine(_ engine: LLMEngineOption) -> APISecretKey? {
        switch engine {
        case .localMLX:
            return nil
        case .openAI:
            return .llmOpenAI
        case .openAICompatible:
            return .llmOpenAICompatible
        case .customOpenAICompatible:
            return nil
        case .azureOpenAI:
            return .llmAzureOpenAI
        case .anthropic:
            return .llmAnthropic
        case .gemini:
            return .llmGemini
        case .deepSeek:
            return .llmDeepSeek
        case .groq:
            return .llmGroq
        case .ollama, .lmStudio:
            return nil
        }
    }

    private func cloudCredentialKeys() -> [APISecretKey] {
        var keys: [APISecretKey] = []
        if let asrKey = keyForASREngine(state.asrEngine) {
            keys.append(asrKey)
        }
        if let llmKey = keyForLLMEngine(state.llmEngine) {
            keys.append(llmKey)
        }
        return Array(Set(keys))
    }

    private func ensureCloudCredentialFlowReady(for mode: WorkflowMode) -> Bool {
        guard !state.shouldUseLocalProvider else {
            return true
        }

        let keys = cloudCredentialKeys()
        let missingHints = keys.filter { AppKeychain.shared.presenceHint(for: $0) == .missing }
        if !missingHints.isEmpty {
            let names = missingHints.map(\.displayName).joined(separator: ", ")
            state.lastError = "Missing credentials: \(names). Open Settings -> Engines & Models to configure."
            state.stage = .failed
            state.processStatus = "Failed"
            hudPanel.showError(message: state.ui("需要配置密钥", "Credentials Needed"))
            hudPanel.hide(after: 1.2)
            onOpenSettingsRequested?()
            appLogger.log(
                "Cloud run blocked due to missing credentials: \(names).",
                type: .warning
            )
            return false
        }

        return true
    }

    func finalizeAndInfer(
        mode: WorkflowMode,
        audioURL: URL,
        recordingSessionID: UUID,
        callsite: String
    ) {
        let inserted = sessionTracker.registerInferenceStart(sessionID: recordingSessionID)
        if !inserted {
            appLogger.log(
                "Duplicate finalizeAndInfer ignored. sessionId=\(recordingSessionID.uuidString) callsite=\(callsite)",
                type: .warning
            )
            removeTemporaryFileIfPresent(at: audioURL, context: "finalizeAndInfer.duplicate")
            return
        }
        appLogger.log("finalizeAndInfer accepted. sessionId=\(recordingSessionID.uuidString) callsite=\(callsite)")
        runInference(mode: mode, audioURL: audioURL, recordingSessionID: recordingSessionID)
    }

    private func runInference(mode: WorkflowMode, audioURL: URL, recordingSessionID: UUID) {
        let pretranscribedResult = pretranscriptionResultsBySessionID.removeValue(forKey: recordingSessionID)
        let dictationContext: DictationContextSelection?
        if mode == .dictate {
            if let locked = contextManager.selection(for: recordingSessionID) {
                dictationContext = locked
            } else {
                dictationContext = contextManager.lockDictationContext(
                    for: recordingSessionID,
                    state: state,
                    logger: appLogger
                )
            }
        } else {
            dictationContext = nil
        }
        let request = InferenceRequest(
            state: state,
            mode: mode,
            audioURL: audioURL,
            selectedText: askContextText,
            dictationContext: dictationContext,
            audioProcessingProfile: self.initialAudioProcessingProfile(for: mode)
        )
        if let dictationContext {
            appLogger.log(
                "Dictation context locked. sessionId=\(recordingSessionID.uuidString) preset=\(dictationContext.preset.title) rule=\(dictationContext.matchedRule?.id ?? "default")"
            )
        }
        if let pretranscribedResult, !pretranscribedResult.transcript.isEmpty {
            appLogger.log(
                "Pretranscribed transcript ready. sessionId=\(recordingSessionID.uuidString) chars=\(pretranscribedResult.transcript.count) chunks=\(pretranscribedResult.completedChunks) fallback=\(pretranscribedResult.fallbackUsed)."
            )
        }
        appLogger.log(
            "Inference starting. sessionId=\(recordingSessionID.uuidString) mode=\(mode.title) outputLanguageSetting=\(state.outputLanguage.rawValue)"
        )
        activeInferenceSessionID = recordingSessionID
        let routePlan = lockedRoutePlan()
        logLockedRoute(routePlan, recordingSessionID: recordingSessionID)

        let provider: InferenceProvider
        do {
            provider = try selectProvider(for: routePlan)
        } catch {
            state.stage = .failed
            state.processStatus = "Failed"
            state.lastError = "Inference routing failed: \(error.localizedDescription)"
            hudPanel.showError(message: state.ui("路由错误", "Routing Error"))
            hudPanel.hide(after: 1.0)
            removeTemporaryFileIfPresent(at: audioURL, context: "runInference.routingFailed")
            clearWorkflowState(for: recordingSessionID, clearTargetApplication: false)
            appLogger.log("Inference routing failed: \(error.localizedDescription)", type: .error)
            return
        }

        if routePlan.requiresCloudCredentials, !ensureCloudCredentialFlowReady(for: mode) {
            removeTemporaryFileIfPresent(at: audioURL, context: "runInference.missingCredentials")
            clearWorkflowState(for: recordingSessionID, clearTargetApplication: true)
            return
        }

        let inferenceID = UUID()
        activeInferenceID = inferenceID
        activeInferenceAudioURL = audioURL
        isInferenceRunning = true
        // Note: For routes that require the local backend, we arm the watchdog INSIDE execute() so
        // that backend startup time (model loading, health check) does not count against the
        // first-token budget. For cloud-only routes the backend check is skipped and execute() is
        // called synchronously, so arming here vs. inside execute() is equivalent.
        if !routePlan.requiresLocalBackend {
            armInferenceWatchdog(
                inferenceID: inferenceID,
                timeout: didReceiveFirstToken ? Timeouts.stallAfterToken : Timeouts.firstToken,
                reason: "Inference timeout. Please try again."
            )
        }

        // Check if LLM polish is disabled for dictation mode
        if !state.llmPolishEnabled, mode == .dictate {
            runASROnlyInference(
                mode: mode,
                request: request,
                routePlan: routePlan,
                inferenceID: inferenceID,
                audioURL: audioURL,
                recordingSessionID: recordingSessionID,
                pretranscribedResult: pretranscribedResult
            )
            return
        }

        let execute = { [weak self] in
            guard let self else { return }
            // Arm (or re-arm) the watchdog now that the backend is confirmed healthy.
            // Local routes get a longer first-token budget because ASR + LLM loading can take
            // significantly more than 60 s on large models.
            if routePlan.requiresLocalBackend {
                self.armInferenceWatchdog(
                    inferenceID: inferenceID,
                    timeout: self.didReceiveFirstToken ? Timeouts.stallAfterToken : Timeouts.firstTokenLocal,
                    reason: "Local inference timeout. Please try again."
                )
            }
            if mode == .ask {
                self.resultOverlay.showAskPending(
                    anchorFrame: self.hudPanel.frame,
                    statusCycle: self.askProgressStatuses()
                )
            }
            let allowsLocalQualityPass = !routePlan.isHybridRoute
            var pendingQualityPass: PendingQualityPass?
            let onToken: (String) -> Void = { [weak self] token in
                    guard let self else { return }
                    guard self.activeInferenceID == inferenceID else { return }
                    guard self.activeInferenceSessionID == recordingSessionID else { return }
                    guard !token.isEmpty else { return }

                    if !self.didReceiveFirstToken {
                        self.didReceiveFirstToken = true
                        self.state.stage = .streaming
                        self.appLogger.log(
                            "First token received for mode \(mode.title). sessionId=\(recordingSessionID.uuidString)"
                        )
                    }
                    self.armInferenceWatchdog(
                        inferenceID: inferenceID,
                        timeout: Timeouts.stallAfterToken,
                        reason: "Inference stalled. Please try again."
                    )

                    let update = self.consumeStreamingToken(token)
                    switch update {
                    case .append(let delta):
                        if mode == .ask {
                            self.resultOverlay.append(delta, anchorFrame: self.hudPanel.frame, interactive: true)
                        } else if mode != .dictate {
                            self.resultOverlay.append(delta, anchorFrame: self.hudPanel.frame)
                        }
                    case .replace(let fullText):
                        if mode == .ask {
                            self.resultOverlay.setFinalText(fullText, anchorFrame: self.hudPanel.frame, interactive: true)
                        } else if mode != .dictate {
                            self.resultOverlay.setFinalText(fullText, anchorFrame: self.hudPanel.frame, interactive: false)
                        }
                    case .ignore:
                        break
                    }
                }
            let onCompletion: (Result<StreamInferenceMeta, Error>) -> Void = { [weak self] result in
                    guard let self else { return }
                    guard self.activeInferenceID == inferenceID else { return }
                    guard self.activeInferenceSessionID == recordingSessionID else { return }
                    defer {
                        self.finishInferenceContext(inferenceID: inferenceID, audioURL: audioURL)
                        self.clearWorkflowState(for: recordingSessionID, clearTargetApplication: true)
                        if let pendingQualityPass {
                            self.runDictationQualityPass(pendingQualityPass)
                        }
                    }

                    switch result {
                    case .success(let meta):
                        let fallbackPolicy = self.state.outputLanguageDirective(
                            asrDetectedLanguage: meta.asr_language_detected,
                            transcriptText: meta.raw_text
                        ).policyLabel
                        self.state.lastASRDetectedLanguage = meta.asr_language_detected ?? "Unknown"
                        self.state.lastLLMOutputLanguagePolicy = meta.output_language_policy ?? fallbackPolicy

                        let rawText = self.textPostProcessor.dedupe(
                            meta.raw_text,
                            stage: "ASR",
                            sessionID: recordingSessionID
                        )
                        let streamedOutput = meta.output_text.isEmpty ? self.state.streamingOutput : meta.output_text
                        let finalOutput = self.textPostProcessor.process(
                            streamedOutput,
                            request: request,
                            sessionID: recordingSessionID
                        )
                        if mode == .dictate {
                            self.logIfRewriteUnchanged(raw: rawText, output: finalOutput, sessionID: recordingSessionID)
                        }
                        self.state.streamingOutput = finalOutput
                        self.streamTextAccumulator.reset()
                        _ = self.streamTextAccumulator.ingest(finalOutput)
                        self.state.lastOutput = finalOutput
                        self.state.lastError = ""
                        self.state.stage = .completed
                        self.state.processStatus = "Idle"
                        if mode == .ask {
                            self.hudPanel.showAskReady()
                            self.resultOverlay.setFinalText(finalOutput, anchorFrame: self.hudPanel.frame, interactive: true)
                        } else {
                            self.hudPanel.showDone()
                            let targetApp = self.copyAndPasteToFrontApp(finalOutput, sessionID: recordingSessionID)
                            if allowsLocalQualityPass {
                                if let qualityPlan = self.prepareDictationQualityPass(
                                    mode: mode,
                                    provider: provider,
                                    originalRequest: request,
                                    audioURL: audioURL,
                                    recordingSessionID: recordingSessionID,
                                    fastOutput: finalOutput,
                                    targetApp: targetApp
                                ) {
                                    pendingQualityPass = qualityPlan
                                }
                            }
                        }

                        if self.sessionTracker.registerHistoryInsert(sessionID: recordingSessionID) {
                            self.historyStore.insert(
                                mode: mode.title,
                                rawText: rawText,
                                outputText: finalOutput
                            )
                            self.appLogger.log(
                                "History insert completed. sessionId=\(recordingSessionID.uuidString)"
                            )
                        } else {
                            self.appLogger.log(
                                "Duplicate history insert blocked. sessionId=\(recordingSessionID.uuidString)",
                                type: .warning
                            )
                        }

                        if mode != .ask {
                            self.resultOverlay.hide(after: 1.5)
                            self.hudPanel.hide(after: 1.5)
                        }
                        self.hudPanel.showInferenceTimingTelemetry(
                            self.timingHUDSummary(from: meta.timing_ms),
                            enabled: true
                        )
                        self.appLogger.log(
                            "Inference success for \(mode.title). sessionId=\(recordingSessionID.uuidString) \(self.timingLogLine(from: meta.timing_ms))"
                        )
                    case .failure(let error):
                        if error is CancellationError {
                            self.state.stage = .idle
                            self.state.processStatus = "Idle"
                            self.hudPanel.hide(after: 0.2)
                            self.resultOverlay.hide(after: 0.1)
                            self.appLogger.log(
                                "Inference cancelled for mode \(mode.title). sessionId=\(recordingSessionID.uuidString)"
                            )
                            return
                        }
                        self.state.stage = .failed
                        self.state.processStatus = "Failed"
                        self.state.lastError = "Inference failed: \(error.localizedDescription)"
                        self.hudPanel.showError(message: self.state.ui("推理错误", "Inference Error"))
                        self.hudPanel.hide(after: 1.0)
                        self.resultOverlay.hide(after: 0.2)
                        self.appLogger.log(
                            "Inference failed for \(mode.title). sessionId=\(recordingSessionID.uuidString): \(error.localizedDescription)",
                            type: .error
                        )
                    }
                }

            if routePlan.isHybridRoute {
                self.runHybridInference(
                    asrIsLocal: routePlan.asrIsLocal,
                    llmIsLocal: routePlan.llmIsLocal,
                    request: request,
                    pretranscribedResult: pretranscribedResult,
                    onToken: onToken,
                    completion: onCompletion
                )
            } else if let pretranscribedResult, !pretranscribedResult.transcript.isEmpty {
                self.runInferenceWithPreparedTranscript(
                    provider: provider,
                    request: request,
                    prepared: pretranscribedResult,
                    includePretranscribeMetrics: true,
                    timingOverrides: [:],
                    onToken: onToken,
                    completion: onCompletion
                )
            } else {
                provider.run(
                    request: request,
                    onToken: onToken,
                    completion: onCompletion
                )
            }
        }

        startLocalBackendIfNeededForInference(
            routePlan: routePlan,
            inferenceID: inferenceID,
            audioURL: audioURL,
            recordingSessionID: recordingSessionID,
            execute: execute
        )
    }

    func initialAudioProcessingProfile(for mode: WorkflowMode) -> AudioProcessingProfile {
        guard mode == .dictate else { return .standard }
        guard state.dictationDualPassEnabled, state.audioEnhancementEnabled else { return .standard }
        return .fast
    }

    private func runInferenceWithPreparedTranscript(
        provider: InferenceProvider,
        request: InferenceRequest,
        prepared: PretranscriptionFinalResult,
        includePretranscribeMetrics: Bool,
        timingOverrides: [String: Double],
        onToken: @escaping (String) -> Void,
        completion: @escaping (Result<StreamInferenceMeta, Error>) -> Void
    ) {
        var timingSeed: [String: Double] = timingOverrides
        if timingSeed["asr"] == nil {
            timingSeed["asr"] = 0
        }
        if includePretranscribeMetrics {
            timingSeed["pretranscribe_chunks"] = Double(prepared.completedChunks)
            timingSeed["pretranscribe_failed_chunks"] = Double(prepared.failedChunks)
            timingSeed["pretranscribe_requests"] = Double(prepared.asrRequestsCount)
            timingSeed["pretranscribe_backlog_seconds"] = prepared.maxBacklogSeconds
            timingSeed["pretranscribe_low_conf_merges"] = Double(prepared.lowConfidenceMerges)
            timingSeed["pretranscribe_last_chunk_latency_ms"] = prepared.lastChunkLatencyMS
            if let firstChunk = prepared.firstChunkLatencyMS {
                timingSeed["time_to_first_chunk"] = firstChunk
            }
        }

        if let local = provider as? PythonStreamRunner {
            local.runPreparedTranscript(
                state: request.state,
                mode: request.mode,
                rawText: prepared.transcript,
                selectedText: request.selectedText,
                dictationContext: request.dictationContext,
                timingMS: timingSeed,
                onToken: onToken,
                completion: completion
            )
            return
        }

        if let cloud = provider as? CloudInferenceProvider {
            Task {
                do {
                    let llmStartedAt = Date()
                    let stream = try await cloud.streamGenerate(
                        request: request,
                        rawText: prepared.transcript,
                        asrDetectedLanguage: prepared.detectedLanguage,
                        onToken: onToken
                    )
                    let llmElapsedMS = Date().timeIntervalSince(llmStartedAt) * 1000
                    var timing: [String: Double] = timingSeed
                    let asrTiming = timing["asr"] ?? 0
                    timing["llm"] = llmElapsedMS
                    timing["total"] = asrTiming + llmElapsedMS
                    if let firstToken = stream.firstTokenLatencyMS {
                        timing["first_token"] = firstToken
                    }
                    let meta = StreamInferenceMeta(
                        mode: request.mode.rawValue,
                        raw_text: prepared.transcript,
                        output_text: stream.output,
                        used_web_search: false,
                        web_sources: [],
                        timing_ms: timing,
                        asr_language_detected: prepared.detectedLanguage,
                        output_language_policy: stream.outputLanguagePolicy
                    )
                    await MainActor.run {
                        completion(.success(meta))
                    }
                } catch {
                    await MainActor.run {
                        completion(.failure(error))
                    }
                }
            }
            return
        }

        provider.run(request: request, onToken: onToken, completion: completion)
    }

    private func runHybridInference(
        asrIsLocal: Bool,
        llmIsLocal: Bool,
        request: InferenceRequest,
        pretranscribedResult: PretranscriptionFinalResult?,
        onToken: @escaping (String) -> Void,
        completion: @escaping (Result<StreamInferenceMeta, Error>) -> Void
    ) {
        let llmProvider: InferenceProvider = llmIsLocal ? localProvider : cloudProvider

        if let pretranscribedResult, !pretranscribedResult.transcript.isEmpty {
            runInferenceWithPreparedTranscript(
                provider: llmProvider,
                request: request,
                prepared: pretranscribedResult,
                includePretranscribeMetrics: true,
                timingOverrides: [:],
                onToken: onToken,
                completion: completion
            )
            return
        }

        Task {
            do {
                let asrStartedAt = Date()
                let asrResult = try await transcribeForRoute(asrIsLocal: asrIsLocal, request: request)
                let asrElapsedMS = Date().timeIntervalSince(asrStartedAt) * 1000
                let prepared = PretranscriptionFinalResult(
                    transcript: asrResult.text,
                    detectedLanguage: asrResult.detectedLanguage,
                    fallbackUsed: false,
                    lowConfidenceMerges: 0,
                    asrRequestsCount: 1,
                    completedChunks: 1,
                    failedChunks: 0,
                    firstChunkLatencyMS: nil,
                    lastChunkLatencyMS: asrElapsedMS,
                    maxBacklogSeconds: 0
                )
                await MainActor.run {
                    self.runInferenceWithPreparedTranscript(
                        provider: llmProvider,
                        request: request,
                        prepared: prepared,
                        includePretranscribeMetrics: false,
                        timingOverrides: ["asr": asrElapsedMS],
                        onToken: onToken,
                        completion: completion
                    )
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    private func transcribeForRoute(
        asrIsLocal: Bool,
        request: InferenceRequest
    ) async throws -> ASRTranscriptionResult {
        if asrIsLocal {
            guard let local = localProvider as? PythonStreamRunner else {
                throw PythonRunError.invalidResponse("Local ASR runtime unavailable.")
            }
            let asr = try await local.transcribeChunk(
                state: request.state,
                audioURL: request.audioURL,
                dictationContext: request.dictationContext,
                audioProcessingProfile: request.audioProcessingProfile
            )
            return ASRTranscriptionResult(
                text: asr.text,
                detectedLanguage: asr.detectedLanguage
            )
        }

        guard let cloud = cloudProvider as? CloudInferenceProvider else {
            throw CloudInferenceError.unsupportedASREngine
        }
        return try await cloud.transcribeAudio(request: request)
    }

    private func runASROnlyInference(
        mode: WorkflowMode,
        request: InferenceRequest,
        routePlan: InferenceRoutePlan,
        inferenceID: UUID,
        audioURL: URL,
        recordingSessionID: UUID,
        pretranscribedResult: PretranscriptionFinalResult?
    ) {
        appLogger.log(
            "Running ASR-only inference (LLM polish disabled). sessionId=\(recordingSessionID.uuidString)"
        )

        // If we already have pretranscribed result, use it directly
        if let pretranscribedResult, !pretranscribedResult.transcript.isEmpty {
            let output = textPostProcessor.dedupe(
                pretranscribedResult.transcript,
                stage: "ASR",
                sessionID: recordingSessionID
            )
            finalizeASROnlyOutput(
                output: output,
                detectedLanguage: pretranscribedResult.detectedLanguage,
                timing: ["asr": pretranscribedResult.lastChunkLatencyMS, "total": pretranscribedResult.lastChunkLatencyMS],
                inferenceID: inferenceID,
                audioURL: audioURL,
                recordingSessionID: recordingSessionID,
                mode: mode
            )
            return
        }

        // Perform ASR based on route plan
        Task {
            do {
                let asrStartedAt = Date()
                let asrResult: ASRTranscriptionResult

                if routePlan.isHybridRoute {
                    // Hybrid route: use the appropriate ASR provider
                    asrResult = try await transcribeForRoute(
                        asrIsLocal: routePlan.asrIsLocal,
                        request: request
                    )
                } else if routePlan.asrIsLocal {
                    // Local-only route
                    guard let local = localProvider as? PythonStreamRunner else {
                        throw PythonRunError.invalidResponse("Local ASR runtime unavailable.")
                    }
                    let asr = try await local.transcribeChunk(
                        state: request.state,
                        audioURL: request.audioURL,
                        dictationContext: request.dictationContext,
                        audioProcessingProfile: request.audioProcessingProfile
                    )
                    asrResult = ASRTranscriptionResult(
                        text: asr.text,
                        detectedLanguage: asr.detectedLanguage
                    )
                } else {
                    // Cloud-only route
                    guard let cloud = cloudProvider as? CloudInferenceProvider else {
                        throw CloudInferenceError.unsupportedASREngine
                    }
                    asrResult = try await cloud.transcribeAudio(request: request)
                }

                let asrElapsedMS = Date().timeIntervalSince(asrStartedAt) * 1000
                let output = textPostProcessor.dedupe(
                    asrResult.text,
                    stage: "ASR",
                    sessionID: recordingSessionID
                )

                await MainActor.run {
                    self.finalizeASROnlyOutput(
                        output: output,
                        detectedLanguage: asrResult.detectedLanguage,
                        timing: ["asr": asrElapsedMS, "total": asrElapsedMS],
                        inferenceID: inferenceID,
                        audioURL: audioURL,
                        recordingSessionID: recordingSessionID,
                        mode: mode
                    )
                }
            } catch {
                await MainActor.run {
                    self.finishInferenceContext(inferenceID: inferenceID, audioURL: audioURL)
                    self.clearWorkflowState(for: recordingSessionID, clearTargetApplication: true)

                    if error is CancellationError {
                        self.state.stage = .idle
                        self.state.processStatus = "Idle"
                        self.hudPanel.hide(after: 0.2)
                        self.resultOverlay.hide(after: 0.1)
                        self.appLogger.log(
                            "ASR-only inference cancelled. sessionId=\(recordingSessionID.uuidString)"
                        )
                        return
                    }

                    self.state.stage = .failed
                    self.state.processStatus = "Failed"
                    self.state.lastError = "ASR failed: \(error.localizedDescription)"
                    self.hudPanel.showError(message: self.state.ui("ASR 错误", "ASR Error"))
                    self.hudPanel.hide(after: 1.0)
                    self.resultOverlay.hide(after: 0.2)
                    self.appLogger.log(
                        "ASR-only inference failed. sessionId=\(recordingSessionID.uuidString): \(error.localizedDescription)",
                        type: .error
                    )
                }
            }
        }
    }

    private func finalizeASROnlyOutput(
        output: String,
        detectedLanguage: String?,
        timing: [String: Double],
        inferenceID: UUID,
        audioURL: URL,
        recordingSessionID: UUID,
        mode: WorkflowMode
    ) {
        guard activeInferenceID == inferenceID else { return }
        guard activeInferenceSessionID == recordingSessionID else { return }

        let fallbackPolicy = state.outputLanguageDirective(
            asrDetectedLanguage: detectedLanguage,
            transcriptText: output
        ).policyLabel
        state.lastASRDetectedLanguage = detectedLanguage ?? "Unknown"
        state.lastLLMOutputLanguagePolicy = "ASR-only (\(fallbackPolicy))"

        let finalOutput = textPostProcessor.process(
            output,
            request: InferenceRequest(
                state: state,
                mode: mode,
                audioURL: audioURL,
                selectedText: "",
                dictationContext: nil,
                audioProcessingProfile: .standard
            ),
            sessionID: recordingSessionID
        )

        state.streamingOutput = finalOutput
        streamTextAccumulator.reset()
        _ = streamTextAccumulator.ingest(finalOutput)
        state.lastOutput = finalOutput
        state.lastError = ""
        state.stage = .completed
        state.processStatus = "Idle"

        hudPanel.showDone()
        _ = copyAndPasteToFrontApp(finalOutput, sessionID: recordingSessionID)

        if sessionTracker.registerHistoryInsert(sessionID: recordingSessionID) {
            historyStore.insert(
                mode: mode.title,
                rawText: output,
                outputText: finalOutput
            )
            appLogger.log(
                "ASR-only history insert completed. sessionId=\(recordingSessionID.uuidString)"
            )
        }

        resultOverlay.hide(after: 1.5)
        hudPanel.hide(after: 1.5)
        hudPanel.showInferenceTimingTelemetry(
            timingHUDSummary(from: timing),
            enabled: true
        )

        appLogger.log(
            "ASR-only inference success. sessionId=\(recordingSessionID.uuidString) \(timingLogLine(from: timing))"
        )

        finishInferenceContext(inferenceID: inferenceID, audioURL: audioURL)
        clearWorkflowState(for: recordingSessionID, clearTargetApplication: true)
    }

    private func prepareDictationQualityPass(
        mode: WorkflowMode,
        provider: InferenceProvider,
        originalRequest: InferenceRequest,
        audioURL: URL,
        recordingSessionID: UUID,
        fastOutput: String,
        targetApp: NSRunningApplication?
    ) -> PendingQualityPass? {
        guard mode == .dictate else { return nil }
        guard provider.providerID == localProvider.providerID else { return nil }
        guard state.dictationDualPassEnabled, state.audioEnhancementEnabled else { return nil }
        guard originalRequest.audioProcessingProfile == .fast else { return nil }
        guard let retainedAudioURL = retainedAudioCopy(for: audioURL, recordingSessionID: recordingSessionID) else {
            return nil
        }

        let request = InferenceRequest(
            state: state,
            mode: .dictate,
            audioURL: retainedAudioURL,
            selectedText: originalRequest.selectedText,
            dictationContext: originalRequest.dictationContext,
            audioProcessingProfile: .quality
        )
        appLogger.log("Dictation quality pass scheduled. sessionId=\(recordingSessionID.uuidString)")
        return PendingQualityPass(
            request: request,
            recordingSessionID: recordingSessionID,
            fastOutput: fastOutput,
            targetApp: targetApp
        )
    }

    private func retainedAudioCopy(for audioURL: URL, recordingSessionID: UUID) -> URL? {
        do {
            let fileManager = FileManager.default
            let dir = fileManager.temporaryDirectory.appendingPathComponent("ghosttype-quality-pass", isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let destination = dir.appendingPathComponent("session-\(recordingSessionID.uuidString).wav")
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: audioURL, to: destination)
            return destination
        } catch {
            appLogger.log(
                "Failed to prepare retained audio for quality pass. sessionId=\(recordingSessionID.uuidString) error=\(error.localizedDescription)",
                type: .warning
            )
            return nil
        }
    }

    private func runDictationQualityPass(_ pending: PendingQualityPass) {
        let qualityPassID = UUID()
        activeQualityPassID = qualityPassID
        appLogger.log("Dictation quality pass started. sessionId=\(pending.recordingSessionID.uuidString)")

        localProvider.run(
            request: pending.request,
            onToken: { _ in },
            completion: { [weak self] result in
                guard let self else { return }
                defer {
                    if self.activeQualityPassID == qualityPassID {
                        self.activeQualityPassID = nil
                    }
                    self.removeTemporaryFileIfPresent(
                        at: pending.request.audioURL,
                        context: "runDictationQualityPass.cleanup"
                    )
                }
                guard self.activeQualityPassID == qualityPassID else { return }

                switch result {
                case .success(let meta):
                    let streamedOutput = meta.output_text.isEmpty ? meta.raw_text : meta.output_text
                    let qualityOutput = self.textPostProcessor.process(
                        streamedOutput,
                        request: pending.request,
                        sessionID: pending.recordingSessionID
                    )
                    let normalizedFast = Self.normalizeRewriteComparisonText(pending.fastOutput)
                    let normalizedQuality = Self.normalizeRewriteComparisonText(qualityOutput)
                    guard !normalizedQuality.isEmpty, normalizedFast != normalizedQuality else {
                        self.appLogger.log(
                            "Dictation quality pass unchanged. sessionId=\(pending.recordingSessionID.uuidString) \(self.timingLogLine(from: meta.timing_ms))"
                        )
                        return
                    }

                    self.appLogger.log(
                        "Dictation quality pass produced improved output. sessionId=\(pending.recordingSessionID.uuidString) \(self.timingLogLine(from: meta.timing_ms))"
                    )
                    guard self.state.dictationQualityAutoReplaceEnabled else {
                        self.appLogger.log(
                            "Auto-replace disabled; quality output not inserted. sessionId=\(pending.recordingSessionID.uuidString)",
                            type: .debug
                        )
                        return
                    }
                    self.replaceRecentInsertionWithQualityOutput(
                        qualityOutput,
                        targetApp: pending.targetApp,
                        sessionID: pending.recordingSessionID
                    )
                case .failure(let error):
                    if error is CancellationError {
                        self.appLogger.log(
                            "Dictation quality pass cancelled. sessionId=\(pending.recordingSessionID.uuidString)"
                        )
                    } else {
                        self.appLogger.log(
                            "Dictation quality pass failed. sessionId=\(pending.recordingSessionID.uuidString) error=\(error.localizedDescription)",
                            type: .warning
                        )
                    }
                }
            }
        )
    }

    private func replaceRecentInsertionWithQualityOutput(
        _ text: String,
        targetApp: NSRunningApplication?,
        sessionID: UUID
    ) {
        guard let targetApp else {
            appLogger.log(
                "Skip quality replace: no original target app. sessionId=\(sessionID.uuidString)",
                type: .warning
            )
            return
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == targetApp.processIdentifier else {
            appLogger.log(
                "Skip quality replace: foreground app changed. sessionId=\(sessionID.uuidString)",
                type: .warning
            )
            return
        }

        let clipboardSnapshot = clipboardService.snapshotCurrentPasteboard()
        let expectedChangeCount = clipboardService.writeTextPayload(text)
        pasteCoordinator.undoThenPaste(
            to: targetApp,
            sessionID: UUID(),
            dispatchDelay: Timeouts.pasteDispatchDelay,
            logger: appLogger
        ) { [weak self] dispatched in
            guard let self else { return }
            let restore = self.clipboardService.restoreSnapshotIfUnchanged(
                clipboardSnapshot,
                expectedChangeCount: expectedChangeCount,
                restoreEnabled: self.state.restoreClipboardAfterPaste
            )
            if dispatched {
                self.state.lastOutput = text
                self.hudPanel.showDone()
                self.hudPanel.hide(after: 0.8)
                self.appLogger.log(
                    "Quality pass replacement applied. sessionId=\(sessionID.uuidString) clipboard=\(restore.title)"
                )
            } else {
                self.appLogger.log(
                    "Quality pass replacement failed to dispatch. sessionId=\(sessionID.uuidString) clipboard=\(restore.title)",
                    type: .warning
                )
            }
        }
    }

    @discardableResult
    private func copyAndPasteToFrontApp(_ text: String, sessionID: UUID) -> NSRunningApplication? {
        guard sessionTracker.registerPaste(sessionID: sessionID) else {
            appLogger.log(
                "Duplicate paste blocked. sessionId=\(sessionID.uuidString) callsite=copyAndPasteToFrontApp",
                type: .warning
            )
            return nil
        }
        let targetApp = targetPasteApplication
        targetPasteApplication = nil
        let snapshot = contextSnapshotService.cachedSnapshot()
        state.lastInsertPath = "Resolving"
        state.lastInsertDebug = snapshot.frontmostAppBundleId
        state.lastClipboardRestoreStatus = "Pending"
        appLogger.log(
            "Delivering output. sessionId=\(sessionID.uuidString) characterCount=\(text.count) smartInsert=\(state.smartInsertEnabled)."
        )
        textInserter.insert(
            text,
            preferredTargetApp: targetApp,
            snapshot: snapshot,
            sessionID: sessionID,
            useSmartInsert: state.smartInsertEnabled,
            restoreClipboard: state.restoreClipboardAfterPaste,
            dispatchDelay: Timeouts.pasteDispatchDelay,
            logger: appLogger
        ) { [weak self] outcome in
            guard let self else { return }
            self.state.lastInsertPath = outcome.path.rawValue
            self.state.lastInsertDebug = outcome.debugInfo
            if let clipboardRestore = outcome.clipboardRestore {
                self.state.lastClipboardRestoreStatus = clipboardRestore.title
            } else {
                self.state.lastClipboardRestoreStatus = "N/A"
            }

            let restoreLabel = outcome.clipboardRestore?.title ?? "N/A"
            self.appLogger.log(
                "Output insertion completed. sessionId=\(sessionID.uuidString) path=\(outcome.path.rawValue) success=\(outcome.success) resolver=\(outcome.resolverSource.rawValue) clipboard=\(restoreLabel)"
            )
            if !outcome.success {
                self.state.lastError = "Auto insert failed. Content remains in clipboard."
                self.hudPanel.showError(message: self.state.ui("已复制", "Copied"))
                self.hudPanel.hide(after: 1.0)
                self.appLogger.log(
                    "Output insertion failed. sessionId=\(sessionID.uuidString) path=\(outcome.path.rawValue) details=\(outcome.debugInfo)",
                    type: .warning
                )
            }
        }
        return targetApp
    }

    func clearWorkflowState(for recordingSessionID: UUID, clearTargetApplication: Bool) {
        activeMode = nil
        askContextText = ""
        activeRecordingSessionID = nil
        activeInferenceSessionID = nil
        contextManager.removeSelection(for: recordingSessionID)
        pretranscriptionResultsBySessionID.removeValue(forKey: recordingSessionID)
        state.activeModeText = "None"
        if clearTargetApplication {
            targetPasteApplication = nil
        }
    }

    private func consumeStreamingToken(_ token: String) -> StreamTokenMergeAction {
        let action = streamTextAccumulator.ingest(token)
        state.streamingOutput = streamTextAccumulator.text
        return action
    }

    private func logIfRewriteUnchanged(raw: String, output: String, sessionID: UUID) {
        let rawText = raw
        let outputText = output
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let unchanged = await Self.isRewriteEffectivelyUnchangedOffMain(raw: rawText, output: outputText)
            guard unchanged else { return }
            self.appLogger.log(
                "Dictation output is effectively unchanged vs ASR input. sessionId=\(sessionID.uuidString) rawChars=\(rawText.count) outputChars=\(outputText.count)",
                type: .warning
            )
        }
    }

    private static func isRewriteEffectivelyUnchangedOffMain(raw: String, output: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let normalizedRaw = normalizeRewriteComparisonText(raw)
            let normalizedOutput = normalizeRewriteComparisonText(output)
            guard !normalizedRaw.isEmpty, !normalizedOutput.isEmpty else {
                return false
            }
            return normalizedRaw == normalizedOutput
        }.value
    }

    private static nonisolated func normalizeRewriteComparisonText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private func askProgressStatuses() -> [String] {
        [
            state.ui("思考中...", "Thinking..."),
            state.ui("搜索网络...", "Searching web..."),
        ]
    }

    private func timingLogLine(from timings: [String: Double]) -> String {
        let keys: [(String, String)] = [
            ("stop_to_vad", "audio_stop_to_vad_done"),
            ("enhance", "enhancement_chain"),
            ("asr_send", "asr_request_send"),
            ("asr_first", "asr_first_packet"),
            ("asr", "asr"),
            ("llm", "llm"),
            ("total", "total"),
        ]
        let fields = keys.map { label, key in
            let value: Double
            if key == "asr_first_packet" {
                value = timings[key] ?? timings["first_token"] ?? 0
            } else {
                value = timings[key] ?? 0
            }
            return "\(label)=\(String(format: "%.1f", value))ms"
        }
        return fields.joined(separator: " ")
    }

    private func timingHUDSummary(from timings: [String: Double]) -> String {
        let stopToVAD = timings["audio_stop_to_vad_done"] ?? 0
        let enhance = timings["enhancement_chain"] ?? 0
        let asrFirst = timings["asr_first_packet"] ?? timings["first_token"] ?? timings["asr"] ?? 0
        let llm = timings["llm"] ?? 0
        return String(
            format: "VAD %.0f  ENH %.0f  ASR1 %.0f  LLM %.0f",
            stopToVAD,
            enhance,
            asrFirst,
            llm
        )
    }

    func handleResultOverlayCancelRequested() {
        if isRecording || isInferenceRunning {
            cancelCurrentOperation(
                reason: "Cancelled by user.",
                hudMessage: state.ui("已取消", "Cancelled")
            )
            return
        }
        if activeQualityPassID != nil {
            activeQualityPassID = nil
            localProvider.terminateIfRunning()
            appLogger.log("Cancelled active quality pass from result overlay action.")
        }

        resultOverlay.dismiss()
        hudPanel.hide(after: 0.05)
        activeMode = nil
        isStoppingRecording = false
        activeStopRequestID = nil
        activeRecordingSessionID = nil
        askContextText = ""
        contextManager.removeAllSelections()
        targetPasteApplication = nil
        state.activeModeText = "None"
        state.processStatus = "Idle"
        state.stage = .idle
        state.lastError = ""
        appLogger.log("Ask result overlay dismissed by user.")
    }

    func copyAskResultToClipboard(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cleaned, forType: .string)
        hudPanel.showCopied()
        appLogger.log("Copied Ask output to clipboard. Character count: \(cleaned.count).")
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 750_000_000)
            } catch {
                return
            }
            guard let self else { return }
            guard !self.isRecording, !self.isInferenceRunning else { return }
            guard self.state.stage == .completed else { return }
            self.hudPanel.showAskReady()
        }
    }

    private func armInferenceWatchdog(inferenceID: UUID, timeout: TimeInterval, reason: String) {
        watchdog.arm(inferenceID: inferenceID, timeout: timeout) { [weak self] firedInferenceID in
            guard let self else { return }
            guard self.activeInferenceID == firedInferenceID else { return }
            self.appLogger.log("Inference watchdog triggered: \(reason)", type: .error)
            self.cancelCurrentOperation(reason: reason, hudMessage: self.state.ui("超时", "Timed Out"))
        }
    }

    func cancelInferenceWatchdog() {
        watchdog.cancel()
    }

    func finishInferenceContext(inferenceID: UUID, audioURL: URL?) {
        guard activeInferenceID == inferenceID else { return }
        cancelInferenceWatchdog()
        isInferenceRunning = false
        activeInferenceID = nil
        activeInferenceSessionID = nil
        activeInferenceAudioURL = nil
        streamTextAccumulator.reset()
        if let audioURL {
            removeTemporaryFileIfPresent(at: audioURL, context: "finishInferenceContext")
        }
    }

    func cancelCurrentOperation(reason: String, hudMessage: String) {
        appLogger.log("Cancelling current operation: \(reason)")
        if let pretranscription = activePretranscriptionSession {
            Task { await pretranscription.cancel() }
            activePretranscriptionSession = nil
            activePretranscriptionRecordingSessionID = nil
        }
        pretranscriptionResultsBySessionID.removeAll()
        state.pretranscribeStatus = state.pretranscribeEnabled ? "Cancelled" : "Off"
        state.pretranscribeQueueDepth = 0
        if isRecording {
            let audioCaptureService = audioCapture
            let logger = appLogger
            Task.detached(priority: .utility) {
                do {
                    let recorded = try await audioCaptureService.stopRecording()
                    if FileManager.default.fileExists(atPath: recorded.path) {
                        do {
                            try FileManager.default.removeItem(at: recorded)
                        } catch {
                            logger.log(
                                "Failed to remove cancelled recording file: \(error.localizedDescription)",
                                type: .warning
                            )
                        }
                    }
                    logger.log("Recording cancelled and temporary file removed: \(recorded.path)")
                } catch {
                    logger.log("Cancel stopRecording failed: \(error.localizedDescription)", type: .error)
                }
            }
            isRecording = false
        }
        if isStoppingRecording {
            appLogger.log("Cancellation requested while recording stop is still in progress; waiting for stop task to exit.", type: .debug)
        } else {
            activeStopRequestID = nil
            isStoppingRecording = false
        }

        if isInferenceRunning {
            let needsBackendReset = state.requiresLocalBackend
            localProvider.terminateIfRunning()
            cloudProvider.terminateIfRunning()
            if let activeInferenceID {
                finishInferenceContext(inferenceID: activeInferenceID, audioURL: activeInferenceAudioURL)
            }
            if needsBackendReset {
                restartLocalBackendAfterCancellation()
            }
        }
        if activeQualityPassID != nil {
            activeQualityPassID = nil
            localProvider.terminateIfRunning()
            appLogger.log("Cancelled active dictation quality pass.")
        }

        activeMode = nil
        askContextText = ""
        didReceiveFirstToken = false
        activeRecordingSessionID = nil
        activeInferenceSessionID = nil
        contextManager.removeAllSelections()
        targetPasteApplication = nil
        state.streamingOutput = ""
        streamTextAccumulator.reset()
        state.activeModeText = "None"
        state.processStatus = "Idle"
        state.stage = .idle
        state.lastError = reason
        resultOverlay.hide(after: 0.05)
        hudPanel.showError(message: hudMessage)
        hudPanel.hide(after: 0.55)
    }

    private func restartLocalBackendAfterCancellation() {
        guard state.requiresLocalBackend else { return }
        state.backendStatus = "Restarting"
        appLogger.log("Restarting local backend after cancellation.")
        backendManager.stopIfNeeded()
        backendManager.startIfNeeded(
            asrModel: state.asrModel,
            llmModel: state.llmModel,
            idleTimeoutSeconds: state.memoryTimeoutSeconds
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.state.backendStatus = "Ready"
                self.appLogger.log("Local backend restart succeeded.")
            case .failure(let error):
                self.state.backendStatus = "Failed"
                self.state.lastError = "Backend restart failed: \(error.localizedDescription)"
                self.appLogger.log("Local backend restart failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    func removeTemporaryFileIfPresent(at url: URL, context: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            appLogger.log(
                "Failed to remove temporary file (\(context)): \(error.localizedDescription)",
                type: .warning
            )
        }
    }
}
