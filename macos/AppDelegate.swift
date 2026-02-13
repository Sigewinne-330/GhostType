import AppKit
import AVFoundation
import Combine
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState.shared
    private let historyStore = HistoryStore.shared
    private let backendManager = BackendManager.shared
    private let contextSnapshotService = ContextSnapshotService.shared
    private let appLogger = AppLogger.shared
    private lazy var inferenceCoordinator: InferenceCoordinator = {
        InferenceCoordinator(
            state: state,
            historyStore: historyStore,
            backendManager: backendManager,
            hudPanel: HUDPanelController(),
            resultOverlay: ResultOverlayController(),
            audioCapture: AudioCaptureService(),
            clipboardService: ClipboardContextService(),
            localProvider: PythonStreamRunner(),
            cloudProvider: CloudInferenceProvider(),
            contextSnapshotService: contextSnapshotService,
            appLogger: appLogger,
            pasteCoordinator: PasteCoordinator()
        )
    }()
    private var hotkeyMonitorRetryTimer: Timer?
    private lazy var duplicateBundleCleanupCoordinator = DuplicateBundleCleanupCoordinator(
        appLogger: appLogger,
        isTestingEnvironment: { [weak self] in self?.isRunningUnderXCTest ?? false }
    )
    private let logger = UnifiedLogger(subsystem: "com.codeandchill.ghosttype", category: "app")
    private var subscriptions = Set<AnyCancellable>()
    private var monitor: GlobalHotkeyManager {
        GlobalHotkeyManager.shared
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if isRunningUnderXCTest {
            state.processStatus = "Idle"
            appLogger.log("Running under XCTest; skipping runtime bootstrap.", type: .debug)
            return
        }
        guard enforceSingleRunningInstance() else { return }
        duplicateBundleCleanupCoordinator.start()
        NSApp.setActivationPolicy(.regular)
        state.processStatus = "Idle"
        logger.log("Application launch sequence started.")
        if !state.ensurePersonalizationFilesExist() {
            logger.log("Warning: could not create personalization directories.", type: .error)
        }
        inferenceCoordinator.onOpenSettingsRequested = { [weak self] in
            self?.openSettingsWindow()
        }
        backendManager.reapUnexpectedBackendsSync()
        configureBackendForCurrentEngines()
        configureSubscriptions()
        contextSnapshotService.onSnapshotUpdated = { [weak self] snapshot in
            self?.inferenceCoordinator.handleContextSnapshotUpdated(snapshot)
        }
        contextSnapshotService.start()
        monitor.onModeStart = { [weak self] mode in
            self?.inferenceCoordinator.handleModeStart(mode)
        }
        monitor.onModeStop = { [weak self] mode in
            self?.inferenceCoordinator.handleModeStop(mode)
        }
        monitor.onModePromote = { [weak self] previous, next in
            self?.inferenceCoordinator.handleModePromotion(from: previous, to: next)
        }
        monitor.updateHotkeys(
            dictate: state.dictateShortcut,
            ask: state.askShortcut,
            translate: state.translateShortcut
        )
        requestPermissionsSequentiallyOnLaunch()
        logger.log("Application did finish launching.")
    }
    private var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCInjectBundleInto"] != nil {
            return true
        }

        if NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest") != nil {
            return true
        }

        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }
    private func enforceSingleRunningInstance() -> Bool {
        if isRunningUnderXCTest {
            return true
        }
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return true
        }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        let others = runningApps.filter { $0.processIdentifier != currentPID }
        guard !others.isEmpty else {
            return true
        }
        let canonicalPath = "/Applications/GhostType.app"
        let currentBundlePath = Bundle.main.bundleURL.path
        if currentBundlePath != canonicalPath,
           FileManager.default.fileExists(atPath: canonicalPath) {
            appLogger.log(
                "Duplicate instance detected from non-canonical path (\(currentBundlePath)). Relaunching canonical app.",
                type: .warning
            )
            NSWorkspace.shared.open(URL(fileURLWithPath: canonicalPath))
            NSApp.terminate(nil)
            return false
        }
        var terminatedCount = 0
        for app in others {
            if app.terminate() {
                terminatedCount += 1
            } else if app.forceTerminate() {
                terminatedCount += 1
            }
        }
        appLogger.log("Duplicate instance detected. Terminated \(terminatedCount) extra instance(s).", type: .warning)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.log("Application termination started.")
        subscriptions.removeAll()
        hotkeyMonitorRetryTimer?.invalidate()
        hotkeyMonitorRetryTimer = nil
        duplicateBundleCleanupCoordinator.stop()
        monitor.stop()
        inferenceCoordinator.terminate()
        contextSnapshotService.onSnapshotUpdated = nil
        contextSnapshotService.stop()
        backendManager.stopIfNeededSync()
        logger.log("Application termination completed.")
    }
    private func startHotkeyMonitor(promptForAccessibility: Bool) {
        if monitor.start(promptForAccessibility: promptForAccessibility) {
            hotkeyMonitorRetryTimer?.invalidate()
            hotkeyMonitorRetryTimer = nil
            logger.log("Hotkey monitor running.")
            return
        }
        if let error = monitor.lastStartError {
            state.lastError = error.localizedDescription
            logger.log("Hotkey monitor failed: \(error.localizedDescription)", type: .error)
        }
        guard hotkeyMonitorRetryTimer == nil else { return }
        hotkeyMonitorRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else {
                    timer.invalidate()
                    return
                }
                if self.monitor.start(promptForAccessibility: false) {
                    timer.invalidate()
                    self.hotkeyMonitorRetryTimer = nil
                    self.logger.log("Global hotkey monitor retry succeeded.")
                    if self.state.lastError == GlobalHotkeyManagerStartError.accessibilityNotTrusted.localizedDescription {
                        self.state.lastError = ""
                    }
                }
            }
        }
    }
    private func configureBackendForCurrentEngines() {
        do {
            switch try InferenceProviderFactory.providerKind(for: state) {
            case .local:
                state.backendStatus = "Starting"
                state.lastError = ""
                logger.log("Backend mode switched to Local MLX.")
                let backendManager = self.backendManager
                let state = self.state
                backendManager.startIfNeeded(
                    asrModel: state.asrModel,
                    llmModel: state.llmModel,
                    idleTimeoutSeconds: state.memoryTimeoutSeconds
                ) { result in
                    switch result {
                    case .success:
                        state.backendStatus = "Ready"
                        self.logger.log("Local backend is ready.")
                    case .failure(let error):
                        state.backendStatus = "Failed"
                        state.lastError = "Backend startup failed: \(error.localizedDescription)"
                        self.logger.log("Backend startup failed: \(error.localizedDescription)", type: .error)
                    }
                }
            case .cloud:
                backendManager.stopIfNeeded()
                state.backendStatus = "Cloud Mode"
                logger.log("Backend mode switched to Cloud API.")
            case .hybrid:
                state.backendStatus = "Starting"
                state.lastError = ""
                logger.log("Backend mode switched to Hybrid (Local + Cloud).")
                let backendManager = self.backendManager
                let state = self.state
                backendManager.startIfNeeded(
                    asrModel: state.asrModel,
                    llmModel: state.llmModel,
                    idleTimeoutSeconds: state.memoryTimeoutSeconds
                ) { result in
                    switch result {
                    case .success:
                        state.backendStatus = "Hybrid Mode"
                        self.logger.log("Hybrid mode local backend is ready.")
                    case .failure(let error):
                        state.backendStatus = "Failed"
                        state.lastError = "Backend startup failed: \(error.localizedDescription)"
                        self.logger.log("Hybrid backend startup failed: \(error.localizedDescription)", type: .error)
                    }
                }
            }
        } catch {
            backendManager.stopIfNeeded()
            state.backendStatus = "Config Error"
            state.lastError = error.localizedDescription
            logger.log("Backend configuration error: \(error.localizedDescription)", type: .error)
        }
    }
    private func openSettingsWindow() {
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
    private func requestPermissionsSequentiallyOnLaunch() {
        logger.log("Starting launch permission sequence.")
        requestMicrophonePermissionOnLaunchIfNeeded { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.logger.log("Requesting hotkey monitor startup after permission sequence.")
                self.startHotkeyMonitor(promptForAccessibility: true)
            }
        }
    }
    private func requestMicrophonePermissionOnLaunchIfNeeded(completion: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            logger.log("Microphone permission already authorized.")
            completion()
        case .denied, .restricted:
            state.lastError = "Microphone permission is disabled in System Settings."
            logger.log("Microphone permission denied or restricted.", type: .error)
            completion()
        case .notDetermined:
            logger.log("Microphone permission not determined; requesting.")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if !granted {
                        self?.state.lastError = "Microphone permission denied."
                        self?.logger.log("Microphone permission denied by user.", type: .error)
                    } else {
                        self?.logger.log("Microphone permission granted by user.")
                    }
                    completion()
                }
            }
        @unknown default:
            completion()
        }
    }

    private func configureSubscriptions() {
        subscriptions.removeAll()

        state.engine.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.configureBackendForCurrentEngines()
            }
            .store(in: &subscriptions)

        state.prefs.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.state.requiresLocalBackend {
                    self.backendManager.updateIdleTimeout(seconds: self.state.memoryTimeoutSeconds)
                }
                self.monitor.updateHotkeys(
                    dictate: self.state.dictateShortcut,
                    ask: self.state.askShortcut,
                    translate: self.state.translateShortcut
                )
                self.configureBackendForCurrentEngines()
            }
            .store(in: &subscriptions)
    }
}
