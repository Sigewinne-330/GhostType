import AppKit
import Foundation

@MainActor
final class InferenceCoordinator {
    enum Timeouts {
        static let firstToken: TimeInterval = 60
        static let stallAfterToken: TimeInterval = 30
        static let pasteDispatchDelay: TimeInterval = 0.08
    }

    let state: AppState
    let historyStore: HistoryStore
    let backendManager: BackendManager
    let hudPanel: HUDPanelController
    let resultOverlay: ResultOverlayController
    let audioCapture: any AudioRecordingService
    let clipboardService: ClipboardContextService
    let localProvider: any InferenceProvider
    let cloudProvider: any InferenceProvider
    let contextSnapshotService: ContextSnapshotService
    let appLogger: AppLogger
    let pasteCoordinator: PasteCoordinator
    let textInserter: TextInserter
    let contextManager = DictationContextManager()
    let textPostProcessor: InferenceTextPostProcessor

    var isRecording = false
    var isStoppingRecording = false
    var isInferenceRunning = false
    var activeMode: WorkflowMode?
    var askContextText: String = ""
    var didReceiveFirstToken = false
    var activeStopRequestID: UUID?
    var activeRecordingSessionID: UUID?
    var activeInferenceSessionID: UUID?
    var activeInferenceID: UUID?
    var activeInferenceAudioURL: URL?
    var activeQualityPassID: UUID?
    var sessionTracker = InferenceSessionTracker()
    let watchdog = InferenceWatchdog()
    var targetPasteApplication: NSRunningApplication?
    var activePretranscriptionSession: PretranscriptionSession?
    var activePretranscriptionRecordingSessionID: UUID?
    var pretranscriptionResultsBySessionID: [UUID: PretranscriptionFinalResult] = [:]

    var streamTextAccumulator = StreamTextAccumulator()

    var onOpenSettingsRequested: (() -> Void)?

    init(
        state: AppState,
        historyStore: HistoryStore,
        backendManager: BackendManager,
        hudPanel: HUDPanelController,
        resultOverlay: ResultOverlayController,
        audioCapture: any AudioRecordingService,
        clipboardService: ClipboardContextService,
        localProvider: any InferenceProvider,
        cloudProvider: any InferenceProvider,
        contextSnapshotService: ContextSnapshotService,
        appLogger: AppLogger,
        pasteCoordinator: PasteCoordinator
    ) {
        self.state = state
        self.historyStore = historyStore
        self.backendManager = backendManager
        self.hudPanel = hudPanel
        self.resultOverlay = resultOverlay
        self.audioCapture = audioCapture
        self.clipboardService = clipboardService
        self.localProvider = localProvider
        self.cloudProvider = cloudProvider
        self.contextSnapshotService = contextSnapshotService
        self.appLogger = appLogger
        self.pasteCoordinator = pasteCoordinator
        self.textInserter = TextInserter(
            targetResolver: TargetResolver(),
            pasteCoordinator: pasteCoordinator,
            clipboardService: clipboardService
        )
        self.textPostProcessor = InferenceTextPostProcessor(
            logger: appLogger,
            shouldDedupe: { state.removeRepeatedTextEnabled },
            isIMNaturalChatPreset: { presetID in state.isIMNaturalChatPreset(presetID) }
        )

        hudPanel.onCancelRequested = { [weak self] in
            self?.cancelCurrentOperation(reason: "Cancelled by user.", hudMessage: "Cancelled")
        }
        resultOverlay.onCancelRequested = { [weak self] in
            self?.handleResultOverlayCancelRequested()
        }
        resultOverlay.onCopyRequested = { [weak self] text in
            self?.copyAskResultToClipboard(text)
        }
        audioCapture.onLevelUpdate = { [weak self] telemetry in
            guard let self else { return }
            self.hudPanel.updateAudioDebugTelemetry(
                rmsDBFS: telemetry.rmsDBFS,
                peakDBFS: telemetry.peakDBFS,
                vadSpeech: telemetry.vadSpeech,
                enabled: self.state.showAudioDebugHUD
            )
        }
        audioCapture.onPCMChunk = { [weak self] chunk in
            guard let self else { return }
            guard chunk.sampleRate == 16_000 else { return }
            guard let session = self.activePretranscriptionSession else { return }
            Task {
                await session.append(samples: chunk.samples)
            }
        }
    }

    func handleContextSnapshotUpdated(_ snapshot: ContextSnapshot) {
        state.contextLatestSnapshot = snapshot
        if !isRecording, !isInferenceRunning {
            let resolution = ContextPresetResolver.resolve(
                mode: .dictate,
                autoSwitchEnabled: state.contextAutoPresetSwitchingEnabled,
                lockCurrentPreset: state.contextLockCurrentPreset,
                currentPresetId: state.contextActiveDictationPresetID,
                defaultPresetId: state.contextDefaultDictationPresetID,
                rules: state.contextRoutingRules,
                snapshot: snapshot
            )
            let selectedPresetID = state.normalizedPromptPresetID(
                resolution.presetId,
                fallbackID: state.contextDefaultDictationPresetID
            )
            let selectedPresetTitle = state.promptPreset(by: selectedPresetID)?.name ?? selectedPresetID
            state.applyContextRoutingDecision(
                snapshot: snapshot,
                matchedRule: resolution.matchedRule,
                selectedPresetID: selectedPresetID,
                selectedPresetTitle: selectedPresetTitle
            )
        }
    }

}
