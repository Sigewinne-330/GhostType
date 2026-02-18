import Foundation

struct InferenceSessionTracker {
    private(set) var startedInferenceSessionIDs: Set<UUID> = []
    private(set) var pastedSessionIDs: Set<UUID> = []
    private(set) var historyInsertedSessionIDs: Set<UUID> = []

    mutating func registerInferenceStart(sessionID: UUID) -> Bool {
        startedInferenceSessionIDs.insert(sessionID).inserted
    }

    mutating func registerPaste(sessionID: UUID) -> Bool {
        pastedSessionIDs.insert(sessionID).inserted
    }

    mutating func registerHistoryInsert(sessionID: UUID) -> Bool {
        historyInsertedSessionIDs.insert(sessionID).inserted
    }

    mutating func reset() {
        startedInferenceSessionIDs.removeAll(keepingCapacity: true)
        pastedSessionIDs.removeAll(keepingCapacity: true)
        historyInsertedSessionIDs.removeAll(keepingCapacity: true)
    }
}

@MainActor
final class InferenceWatchdog {
    private var task: Task<Void, Never>?
    private(set) var activeInferenceID: UUID?

    func arm(
        inferenceID: UUID,
        timeout: TimeInterval,
        handler: @escaping (UUID) -> Void
    ) {
        cancel()
        activeInferenceID = inferenceID
        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return
            }
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard self.activeInferenceID == inferenceID else { return }
            handler(inferenceID)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        activeInferenceID = nil
    }
}

extension InferenceCoordinator {
    struct InferenceRoutePlan {
        let asrIsLocal: Bool
        let llmIsLocal: Bool
        let asrProviderID: String
        let llmProviderID: String

        var isHybridRoute: Bool {
            asrIsLocal != llmIsLocal
        }

        var requiresLocalBackend: Bool {
            asrIsLocal || llmIsLocal
        }

        var requiresCloudCredentials: Bool {
            !asrIsLocal || !llmIsLocal
        }

        var asrRuntimeLabel: String {
            asrIsLocal ? "local" : "cloud"
        }

        var llmRuntimeLabel: String {
            llmIsLocal ? "local" : "cloud"
        }
    }

    func lockedRoutePlan() -> InferenceRoutePlan {
        let asrIsLocal = state.asrEngine == .localMLX
        let llmIsLocal = state.llmEngine == .localMLX
        return InferenceRoutePlan(
            asrIsLocal: asrIsLocal,
            llmIsLocal: llmIsLocal,
            asrProviderID: asrIsLocal ? "local.asr.mlx" : state.selectedASRProviderID,
            llmProviderID: llmIsLocal ? "local.llm.mlx" : state.selectedLLMProviderID
        )
    }

    func logLockedRoute(_ routePlan: InferenceRoutePlan, recordingSessionID: UUID) {
        appLogger.log(
            "Engine route locked. sessionId=\(recordingSessionID.uuidString) asr=\(routePlan.asrRuntimeLabel):\(routePlan.asrProviderID) llm=\(routePlan.llmRuntimeLabel):\(routePlan.llmProviderID)"
        )
    }

    func selectProvider(for routePlan: InferenceRoutePlan) throws -> InferenceProvider {
        if routePlan.isHybridRoute {
            let provider = routePlan.llmIsLocal ? localProvider : cloudProvider
            appLogger.log("Hybrid inference mode selected. LLM provider=\(provider.providerID).")
            return provider
        }

        let provider = try InferenceProviderFactory.makeProvider(
            for: state,
            localProvider: localProvider,
            cloudProvider: cloudProvider
        )
        appLogger.log("Inference provider selected: \(provider.providerID).")
        return provider
    }

    func startLocalBackendIfNeededForInference(
        routePlan: InferenceRoutePlan,
        inferenceID: UUID,
        audioURL: URL,
        recordingSessionID: UUID,
        execute: @escaping () -> Void
    ) {
        guard routePlan.requiresLocalBackend else {
            execute()
            return
        }

        backendManager.startIfNeeded(
            asrModel: state.asrModel,
            llmModel: state.llmModel,
            idleTimeoutSeconds: state.memoryTimeoutSeconds
        ) { [weak self] result in
            guard let self else { return }
            guard self.activeInferenceID == inferenceID else {
                self.removeTemporaryFileIfPresent(at: audioURL, context: "runInference.backendStart.staleInference")
                return
            }
            switch result {
            case .success:
                self.state.backendStatus = "Ready"
                self.appLogger.log("Local backend confirmed healthy before inference run.")
                execute()
            case .failure(let error):
                self.state.stage = .failed
                self.state.processStatus = "Failed"
                self.state.lastError = "Backend startup failed: \(error.localizedDescription)"
                self.hudPanel.showError(message: self.state.ui("后端错误", "Backend Error"))
                self.hudPanel.hide(after: 1.0)
                self.finishInferenceContext(inferenceID: inferenceID, audioURL: audioURL)
                self.clearWorkflowState(for: recordingSessionID, clearTargetApplication: false)
                self.appLogger.log(
                    "Backend startup failed before inference. sessionId=\(recordingSessionID.uuidString): \(error.localizedDescription)",
                    type: .error
                )
            }
        }
    }
}
