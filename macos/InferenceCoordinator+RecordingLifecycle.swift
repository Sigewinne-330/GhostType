import Foundation

extension InferenceCoordinator {
    func terminate() {
        cancelInferenceWatchdog()
        if let pretranscription = activePretranscriptionSession {
            Task { await pretranscription.cancel() }
        }
        activePretranscriptionSession = nil
        activePretranscriptionRecordingSessionID = nil
        pretranscriptionResultsBySessionID.removeAll()
        if isRecording {
            let audioCaptureService = audioCapture
            let logger = appLogger
            Task.detached(priority: .utility) {
                do {
                    _ = try await audioCaptureService.stopRecording()
                } catch {
                    logger.log("Failed to stop recording during coordinator termination: \(error.localizedDescription)", type: .warning)
                }
            }
            isRecording = false
        }
        isStoppingRecording = false
        activeStopRequestID = nil
        localProvider.terminateIfRunning()
        cloudProvider.terminateIfRunning()
        resultOverlay.reset()
        activeMode = nil
        askContextText = ""
        activeRecordingSessionID = nil
        activeInferenceSessionID = nil
        activeQualityPassID = nil
        contextManager.removeAllSelections()
        targetPasteApplication = nil
        sessionTracker.reset()
        state.pretranscribeStatus = "Off"
        state.pretranscribeCompletedChunks = 0
        state.pretranscribeQueueDepth = 0
        state.pretranscribeLastLatencyMS = 0
    }
    func handleModeStart(_ mode: WorkflowMode) {
        if isInferenceRunning {
            cancelCurrentOperation(
                reason: "Cancelled by user.",
                hudMessage: "Cancelled"
            )
            return
        }
        guard !isRecording else { return }
        guard !isStoppingRecording else {
            appLogger.log("Ignored mode start while recording stop is still in progress.", type: .warning)
            return
        }
        if activeQualityPassID != nil {
            activeQualityPassID = nil
            localProvider.terminateIfRunning()
            appLogger.log("Cancelled running quality pass due to new recording start.")
        }
        do {
            appLogger.log("Hotkey triggered start for mode \(mode.title).")
            if mode == .ask {
                askContextText = clipboardService.captureSelectedText()
                appLogger.log("Captured Ask selected text length: \(askContextText.count).")
            } else {
                askContextText = ""
            }

            let enhancementMode: AudioEnhancementModeOption = {
                guard state.audioEnhancementEnabled else { return .off }
                return state.audioEnhancementMode
            }()
            try audioCapture.startRecording(enhancementMode: enhancementMode)
            let recordingSessionID = UUID()
            if mode == .dictate {
                _ = contextManager.lockDictationContext(
                    for: recordingSessionID,
                    state: state,
                    logger: appLogger
                )
            }
            isRecording = true
            activeMode = mode
            activeRecordingSessionID = recordingSessionID
            didReceiveFirstToken = false
            targetPasteApplication = pasteCoordinator.resolveCurrentTargetApplication()

            state.stage = .recording
            state.activeModeText = mode.title
            state.processStatus = "Recording"
            state.streamingOutput = ""
            streamTextAccumulator.reset()
            state.lastError = ""

            resultOverlay.reset()
            hudPanel.showRecording(mode: mode)
            appLogger.log("Recording session started. sessionId=\(recordingSessionID.uuidString) mode=\(mode.title).")
            appLogger.log("Recording enhancement mode: \(enhancementMode.requestValue)")
            appLogger.log("Recording started for mode \(mode.title).")
            startPretranscriptionIfNeeded(mode: mode, recordingSessionID: recordingSessionID)
        } catch {
            state.stage = .failed
            state.processStatus = "Failed"
            state.lastError = "Failed to start recording: \(error.localizedDescription)"
            activeRecordingSessionID = nil
            hudPanel.showError(message: "Mic Error")
            hudPanel.hide(after: 1.0)
            appLogger.log("Failed to start recording: \(error.localizedDescription)", type: .error)
        }
    }

    func handleModeStop(_ mode: WorkflowMode) {
        guard activeMode == mode else { return }
        guard isRecording else { return }
        guard !isStoppingRecording else { return }
        guard let sessionID = activeRecordingSessionID else {
            appLogger.log("Missing recording session id on stop. mode=\(mode.title)", type: .warning)
            return
        }
        let stopRequestID = UUID()
        activeStopRequestID = stopRequestID
        isStoppingRecording = true
        appLogger.log("Final execution mode: \(mode.title) | API Route: \(apiRouteDescription(for: mode))")
        isRecording = false
        state.stage = .processing
        state.processStatus = "Running"
        hudPanel.showProcessing(mode: mode)
        appLogger.log("Stopping recording for mode \(mode.title). sessionId=\(sessionID.uuidString)")

        let audioCaptureService = audioCapture
        Task { [weak self, audioCaptureService] in
            guard let self else { return }
            defer { self.finishRecordingStopIfCurrent(stopRequestID) }
            do {
                let audioURL = try await audioCaptureService.stopRecording()
                guard self.activeRecordingSessionID == sessionID else {
                    self.removeTemporaryFileIfPresent(at: audioURL, context: "handleModeStop.staleSession")
                    return
                }
                let pretranscriptionResult = await self.finishPretranscriptionIfNeeded(
                    mode: mode,
                    recordingSessionID: sessionID,
                    audioURL: audioURL
                )
                if let pretranscriptionResult {
                    self.pretranscriptionResultsBySessionID[sessionID] = pretranscriptionResult
                }
                self.appLogger.log("Recording stopped successfully. Audio file: \(audioURL.path)")
                self.finalizeAndInfer(
                    mode: mode,
                    audioURL: audioURL,
                    recordingSessionID: sessionID,
                    callsite: "handleModeStop.stopRecording.success"
                )
            } catch {
                guard self.activeRecordingSessionID == sessionID else { return }
                if self.isBenignRecordingStopError(error) {
                    await self.cancelPretranscriptionSessionIfNeeded(recordingSessionID: sessionID)
                    self.activeMode = nil
                    self.activeRecordingSessionID = nil
                    self.contextManager.removeSelection(for: sessionID)
                    self.state.activeModeText = "None"
                    self.state.stage = .idle
                    self.state.processStatus = "Idle"
                    self.hudPanel.hide(after: 0.25)
                    self.appLogger.log("Recording stop ignored: \(error.localizedDescription)", type: .warning)
                    return
                }
                self.activeMode = nil
                self.state.activeModeText = "None"
                self.state.stage = .failed
                self.state.processStatus = "Failed"
                self.state.lastError = "Failed to stop recording: \(error.localizedDescription)"
                self.hudPanel.showError(message: "Record Stop Error")
                self.hudPanel.hide(after: 1.0)
                self.activeRecordingSessionID = nil
                self.contextManager.removeSelection(for: sessionID)
                await self.cancelPretranscriptionSessionIfNeeded(recordingSessionID: sessionID)
                self.appLogger.log("AudioEngine stop failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    private func finishRecordingStopIfCurrent(_ stopRequestID: UUID) {
        guard activeStopRequestID == stopRequestID else { return }
        activeStopRequestID = nil
        isStoppingRecording = false
    }

    private func isBenignRecordingStopError(_ error: Error) -> Bool {
        guard case let AudioCaptureError.normalizationFailed(reason) = error else {
            return false
        }
        let normalized = reason.lowercased()
        return normalized.contains("no audio frames were captured")
            || normalized.contains("recording too short")
    }

    func handleModePromotion(from previousMode: WorkflowMode, to nextMode: WorkflowMode) {
        appLogger.log("Promoted mode applied to recorder: \(previousMode.title) -> \(nextMode.title).", type: .debug)
        if previousMode != nextMode, let session = activePretranscriptionSession {
            Task { await session.cancel() }
            activePretranscriptionSession = nil
            activePretranscriptionRecordingSessionID = nil
            state.pretranscribeStatus = state.pretranscribeEnabled ? "Mode Changed" : "Off"
            state.pretranscribeQueueDepth = 0
            appLogger.log("Pretranscribe session cancelled due to mode promotion.")
        }
        activeMode = nextMode
        state.activeModeText = nextMode.title
        if nextMode == .ask {
            askContextText = clipboardService.captureSelectedText()
            appLogger.log("Mode promoted to Ask. Captured selected text length: \(askContextText.count).", type: .debug)
        } else {
            askContextText = ""
        }

        if let activeRecordingSessionID {
            if nextMode == .dictate {
                _ = contextManager.lockDictationContext(
                    for: activeRecordingSessionID,
                    state: state,
                    logger: appLogger
                )
            } else {
                contextManager.removeSelection(for: activeRecordingSessionID)
            }
        }

        if isRecording {
            hudPanel.showRecording(mode: nextMode)
        }
    }

    private func startPretranscriptionIfNeeded(mode: WorkflowMode, recordingSessionID: UUID) {
        if let existing = activePretranscriptionSession {
            Task { await existing.cancel() }
            activePretranscriptionSession = nil
            activePretranscriptionRecordingSessionID = nil
        }
        pretranscriptionResultsBySessionID.removeValue(forKey: recordingSessionID)

        let config = PretranscriptionConfig.from(state: state)
        guard config.enabled else {
            state.pretranscribeStatus = "Off"
            state.pretranscribeCompletedChunks = 0
            state.pretranscribeQueueDepth = 0
            state.pretranscribeLastLatencyMS = 0
            return
        }

        if state.asrEngine == .localMLX {
            backendManager.startIfNeeded(
                asrModel: state.asrModel,
                llmModel: state.llmModel,
                idleTimeoutSeconds: state.memoryTimeoutSeconds
            ) { [weak self] result in
                guard let self else { return }
                if case .failure(let error) = result {
                    self.appLogger.log(
                        "Pretranscribe local backend warmup failed: \(error.localizedDescription)",
                        type: .warning
                    )
                }
            }
        }

        let selectedText = askContextText
        let dictationContext = mode == .dictate
            ? contextManager.selection(for: recordingSessionID)
            : nil
        let chunkTranscriber: PretranscriptionSession.ChunkASRTranscriber = { [weak self] chunkURL in
            guard let self else { throw CancellationError() }
            return try await self.transcribeAudioChunkForPretranscription(
                mode: mode,
                audioURL: chunkURL,
                selectedText: selectedText,
                dictationContext: dictationContext
            )
        }
        let fullASRTranscriber: PretranscriptionSession.FullASRTranscriber?
        if config.fallbackPolicy == .fullASROnHighFailure {
            fullASRTranscriber = { [weak self] fullAudioURL in
                guard let self else { throw CancellationError() }
                return try await self.transcribeAudioChunkForPretranscription(
                    mode: mode,
                    audioURL: fullAudioURL,
                    selectedText: selectedText,
                    dictationContext: dictationContext
                )
            }
        } else {
            fullASRTranscriber = nil
        }

        let runtimeUpdate: PretranscriptionSession.RuntimeUpdateHandler = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.pretranscribeStatus = snapshot.status
                self.state.pretranscribeCompletedChunks = snapshot.completedChunks
                self.state.pretranscribeQueueDepth = snapshot.queueDepth
                self.state.pretranscribeLastLatencyMS = snapshot.lastChunkLatencyMS
            }
        }
        let logHandler: PretranscriptionSession.LogHandler = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.appLogger.log(message, type: .warning)
            }
        }

        activePretranscriptionSession = PretranscriptionSession(
            config: config,
            sessionID: recordingSessionID,
            chunkTranscriber: chunkTranscriber,
            fullASRTranscriber: fullASRTranscriber,
            runtimeUpdate: runtimeUpdate,
            logger: logHandler
        )
        activePretranscriptionRecordingSessionID = recordingSessionID
        state.pretranscribeStatus = "On"
        state.pretranscribeCompletedChunks = 0
        state.pretranscribeQueueDepth = 0
        state.pretranscribeLastLatencyMS = 0
        appLogger.log("Pretranscribe session started. sessionId=\(recordingSessionID.uuidString)")
    }

    private func finishPretranscriptionIfNeeded(
        mode: WorkflowMode,
        recordingSessionID: UUID,
        audioURL: URL
    ) async -> PretranscriptionFinalResult? {
        guard activePretranscriptionRecordingSessionID == recordingSessionID,
              let session = activePretranscriptionSession else {
            state.pretranscribeStatus = state.pretranscribeEnabled ? "Skipped" : "Off"
            state.pretranscribeQueueDepth = 0
            return nil
        }

        activePretranscriptionSession = nil
        activePretranscriptionRecordingSessionID = nil
        let result = await session.finish(finalAudioURL: audioURL)
        state.pretranscribeStatus = result.fallbackUsed ? "Fallback Used" : "Ready"
        state.pretranscribeCompletedChunks = result.completedChunks
        state.pretranscribeQueueDepth = 0
        state.pretranscribeLastLatencyMS = result.lastChunkLatencyMS
        appLogger.log(
            "Pretranscribe finished. mode=\(mode.rawValue) chunks=\(result.completedChunks) failed=\(result.failedChunks) fallback=\(result.fallbackUsed) requests=\(result.asrRequestsCount)"
        )
        return result
    }

    private func cancelPretranscriptionSessionIfNeeded(recordingSessionID: UUID) async {
        guard activePretranscriptionRecordingSessionID == recordingSessionID,
              let session = activePretranscriptionSession else {
            return
        }
        activePretranscriptionSession = nil
        activePretranscriptionRecordingSessionID = nil
        pretranscriptionResultsBySessionID.removeValue(forKey: recordingSessionID)
        await session.cancel()
        state.pretranscribeStatus = state.pretranscribeEnabled ? "Cancelled" : "Off"
        state.pretranscribeQueueDepth = 0
    }

    @MainActor
    private func transcribeAudioChunkForPretranscription(
        mode: WorkflowMode,
        audioURL: URL,
        selectedText: String,
        dictationContext: DictationContextSelection?
    ) async throws -> PretranscriptionASRResult {
        let profile = initialAudioProcessingProfile(for: mode)
        if state.asrEngine == .localMLX {
            guard let local = localProvider as? PythonStreamRunner else {
                throw PythonRunError.invalidResponse("Local pretranscribe runtime unavailable.")
            }
            return try await local.transcribeChunk(
                state: state,
                audioURL: audioURL,
                dictationContext: dictationContext,
                audioProcessingProfile: profile
            )
        }

        guard let cloud = cloudProvider as? CloudInferenceProvider else {
            throw CloudInferenceError.unsupportedASREngine
        }
        let request = InferenceRequest(
            state: state,
            mode: mode,
            audioURL: audioURL,
            selectedText: selectedText,
            dictationContext: dictationContext,
            audioProcessingProfile: profile
        )
        let response = try await cloud.transcribeAudio(request: request)
        return PretranscriptionASRResult(
            text: response.text,
            detectedLanguage: response.detectedLanguage,
            timingMS: [:]
        )
    }
}
