import Foundation
import CryptoKit
import Darwin

enum BackendError: LocalizedError {
    case missingBundledScript
    case missingBundledRequirements
    case bootstrapFailed(String)
    case startFailed(String)
    case healthCheckTimeout
    case invalidRequirementsHash
    case backendUnavailable
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBundledScript:
            return "Missing bundled service.py in app resources."
        case .missingBundledRequirements:
            return "Missing bundled requirements.txt in app resources."
        case .bootstrapFailed(let message):
            return "Backend bootstrap failed: \(message)"
        case .startFailed(let message):
            return "Backend startup failed: \(message)"
        case .healthCheckTimeout:
            return "Backend health check timed out."
        case .invalidRequirementsHash:
            return "Invalid requirements hash."
        case .backendUnavailable:
            return "Backend is not available."
        case .requestFailed(let message):
            return "Backend request failed: \(message)"
        }
    }
}

final class BackendManager {
    static let shared = BackendManager()

    private enum AppIdentity {
        static let currentAppName = "GhostType"
        static let legacyAppName = "GhostType"
        static let currentSupportDirectoryName = "GhostType"
        static let legacySupportDirectoryName = "GhostType"
        static let serviceScriptName = "service.py"
        static let apmInstallerScriptName = "install_webrtc_apm_macos.sh"
    }

    private let queue = DispatchQueue(label: "ghosttype.backend.manager", qos: .utility)
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var startedByManager = false
    private var runningLaunchConfig: LaunchConfig?
    private var isStarting = false
    private var pendingCompletions: [(Result<Void, Error>) -> Void] = []
    private var stderrTail = Data()

    private let stderrTailLimit = 16 * 1024
    private let appLogger = AppLogger.shared

    private let host = "127.0.0.1"
    private let port = 8765

    /// Dedicated URLSession for backend health/config calls.
    /// Health polling is async and callbacks are marshalled back to `self.queue`.
    private let healthSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 30
        let opQueue = OperationQueue()
        opQueue.name = "ghosttype.backend.health"
        opQueue.maxConcurrentOperationCount = 2
        return URLSession(configuration: config, delegate: nil, delegateQueue: opQueue)
    }()

    private struct LaunchConfig: Equatable {
        let asrModel: String
        let llmModel: String
        let idleTimeoutSeconds: Int?
    }

    private init() {}

    func startIfNeeded(
        asrModel: String,
        llmModel: String,
        idleTimeoutSeconds: Int?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async {
            self.appLogger.log("Backend start requested.")
            let requestedConfig = LaunchConfig(
                asrModel: asrModel,
                llmModel: llmModel,
                idleTimeoutSeconds: idleTimeoutSeconds
            )
            self.pendingCompletions.append(completion)
            guard !self.isStarting else { return }
            self.isStarting = true
            self.startFlowLocked(requestedConfig: requestedConfig)
        }
    }

    private func startFlowLocked(requestedConfig: LaunchConfig) {
        // Avoid reusing stale backend daemons launched by old app bundles (e.g. DerivedData).
        if !startedByManager {
            terminateUnexpectedServiceProcessesLocked()
            terminateUnexpectedBackendOnPortLocked()
        }

        if startedByManager,
           let process,
           process.isRunning,
           let currentConfig = runningLaunchConfig,
           currentConfig != requestedConfig {
            terminateManagedProcessLocked()
        }

        checkHealth(timeout: 1.0) { healthy in
            if healthy {
                self.runningLaunchConfig = requestedConfig
                self.postIdleTimeoutConfig(seconds: requestedConfig.idleTimeoutSeconds)
                self.appLogger.log("Backend already healthy; reusing existing process.")
                self.finishStarting(with: .success(()))
                return
            }

            do {
                let context = try self.prepareBootstrapContext()
                try self.bootstrapEnvironment(context: context)
                try self.launchService(context: context, config: requestedConfig)
            } catch {
                self.finishStarting(with: .failure(error))
                return
            }

            self.checkHealth(timeout: 120.0) { healthy in
                if healthy {
                    self.runningLaunchConfig = requestedConfig
                    self.postIdleTimeoutConfig(seconds: requestedConfig.idleTimeoutSeconds)
                    self.finishStarting(with: .success(()))
                } else {
                    let stderrExcerpt = self.recentStderrLocked()
                    self.terminateManagedProcessLocked()
                    if stderrExcerpt.isEmpty {
                        self.finishStarting(with: .failure(BackendError.healthCheckTimeout))
                    } else {
                        self.finishStarting(
                            with: .failure(
                                BackendError.startFailed("Health check timeout. stderr tail:\n\(stderrExcerpt)")
                            )
                        )
                    }
                }
            }
        }
    }

    func stopIfNeeded() {
        queue.async {
            self.appLogger.log("Backend stop requested.")
            self.terminateManagedProcessLocked()
        }
    }

    func stopIfNeededSync() {
        queue.sync {
            terminateManagedProcessLocked()
        }
    }

    func reapUnexpectedBackendsSync() {
        queue.sync {
            terminateUnexpectedServiceProcessesLocked()
            terminateUnexpectedBackendOnPortLocked()
        }
    }

    func updateIdleTimeout(seconds: Int?) {
        queue.async {
            self.postIdleTimeoutConfig(seconds: seconds)
        }
    }

    func clearStyleProfile(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            self.checkHealth(timeout: 1.5) { healthy in
                guard healthy else {
                    self.appLogger.log("Clear style profile failed: backend unavailable.", type: .error)
                    DispatchQueue.main.async {
                        completion(.failure(BackendError.backendUnavailable))
                    }
                    return
                }

                let url = URL(string: "http://\(self.host):\(self.port)/style/clear")!
                var request = URLRequest(url: url, timeoutInterval: 6.0)
                request.httpMethod = "POST"

                URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error {
                        self.appLogger.log("Clear style profile request failed: \(error.localizedDescription)", type: .error)
                        DispatchQueue.main.async {
                            completion(.failure(BackendError.requestFailed(error.localizedDescription)))
                        }
                        return
                    }

                    guard let http = response as? HTTPURLResponse else {
                        self.appLogger.log("Clear style profile request failed: no HTTP response.", type: .error)
                        DispatchQueue.main.async {
                            completion(.failure(BackendError.requestFailed("No HTTP response.")))
                        }
                        return
                    }

                    guard (200...299).contains(http.statusCode) else {
                        let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
                        self.appLogger.log("Clear style profile request failed: HTTP \(http.statusCode): \(body)", type: .error)
                        DispatchQueue.main.async {
                            completion(.failure(BackendError.requestFailed("HTTP \(http.statusCode): \(body)")))
                        }
                        return
                    }

                    self.appLogger.log("Style profile cleared successfully.")
                    DispatchQueue.main.async {
                        completion(.success(()))
                    }
                }.resume()
            }
        }
    }

    private struct BootstrapContext {
        let appSupportDir: URL
        let venvPython: URL
        let serviceScriptURL: URL
        let requirementsURL: URL
        let apmInstallerScriptURL: URL?
    }

    private func prepareBootstrapContext() throws -> BootstrapContext {
        guard let serviceScriptURL = Bundle.main.url(forResource: "service", withExtension: "py") else {
            throw BackendError.missingBundledScript
        }
        guard let requirementsURL = Bundle.main.url(forResource: "requirements", withExtension: "txt") else {
            throw BackendError.missingBundledRequirements
        }

        let appSupportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let appSupportDir = preferredAppSupportDirectory(baseURL: appSupportBase)
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        let venvPython = appSupportDir.appendingPathComponent(".venv/bin/python")
        let apmInstallerScriptURL = Bundle.main.url(
            forResource: AppIdentity.apmInstallerScriptName.replacingOccurrences(of: ".sh", with: ""),
            withExtension: "sh"
        )
        return BootstrapContext(
            appSupportDir: appSupportDir,
            venvPython: venvPython,
            serviceScriptURL: serviceScriptURL,
            requirementsURL: requirementsURL,
            apmInstallerScriptURL: apmInstallerScriptURL
        )
    }

    private func preferredAppSupportDirectory(baseURL: URL) -> URL {
        let fileManager = FileManager.default
        let current = baseURL.appendingPathComponent(AppIdentity.currentSupportDirectoryName, isDirectory: true)
        let legacy = baseURL.appendingPathComponent(AppIdentity.legacySupportDirectoryName, isDirectory: true)

        if fileManager.fileExists(atPath: current.path) {
            return current
        }
        guard fileManager.fileExists(atPath: legacy.path) else {
            return current
        }

        do {
            try fileManager.moveItem(at: legacy, to: current)
            appLogger.log("Migrated Application Support from \(legacy.lastPathComponent) to \(current.lastPathComponent).")
            return current
        } catch {
            appLogger.log(
                "Application Support migration failed (\(error.localizedDescription)); continuing with legacy directory.",
                type: .warning
            )
            return legacy
        }
    }

    private func bootstrapEnvironment(context: BootstrapContext) throws {
        let venvDir = context.appSupportDir.appendingPathComponent(".venv")

        // Determine which Python to use for the venv.
        let bestPython = findBestPython()
        let pythonPath: String = bestPython?.path ?? "/usr/bin/python3"
        if let bp = bestPython {
            appLogger.log("Selected Python \(bp.version.0).\(bp.version.1) at \(bp.path) for backend venv.")
        } else {
            appLogger.log("No Python >= \(Self.minimumPythonVersion.major).\(Self.minimumPythonVersion.minor) found; falling back to /usr/bin/python3.", type: .warning)
        }

        // Check if existing venv needs recreation (e.g. was built with Python < 3.10).
        var needsRecreate = !FileManager.default.fileExists(atPath: context.venvPython.path)
        if !needsRecreate, let venvVer = venvPythonVersion(at: context.venvPython) {
            if venvVer.0 < Self.minimumPythonVersion.major ||
                (venvVer.0 == Self.minimumPythonVersion.major && venvVer.1 < Self.minimumPythonVersion.minor) {
                if bestPython != nil {
                    appLogger.log(
                        "Existing venv uses Python \(venvVer.0).\(venvVer.1) (< \(Self.minimumPythonVersion.major).\(Self.minimumPythonVersion.minor)). Recreating with newer Python.",
                        type: .warning
                    )
                    try? FileManager.default.removeItem(at: venvDir)
                    // Also clear the requirements marker so dependencies get reinstalled.
                    let marker = context.appSupportDir.appendingPathComponent(".requirements.sha256")
                    try? FileManager.default.removeItem(at: marker)
                    needsRecreate = true
                }
            }
        }

        if needsRecreate {
            let create = Process()
            create.executableURL = URL(fileURLWithPath: pythonPath)
            create.arguments = ["-m", "venv", venvDir.path]
            create.qualityOfService = .background

            let errPipe = Pipe()
            create.standardError = errPipe
            create.standardOutput = Pipe()
            try create.run()
            create.waitUntilExit()
            if create.terminationStatus != 0 {
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw BackendError.bootstrapFailed(err)
            }
        }

        let marker = context.appSupportDir.appendingPathComponent(".requirements.sha256")
        let expectedHash = try requirementsHash(url: context.requirementsURL)
        let installedHash: String?
        do {
            installedHash = try String(contentsOf: marker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            installedHash = nil
        } catch {
            installedHash = nil
            appLogger.log(
                "Failed to read requirements marker (\(marker.lastPathComponent)): \(error.localizedDescription). Reinstalling dependencies.",
                type: .warning
            )
        }

        if let installedHash, installedHash == expectedHash {
            installOptionalWebRTCAPMIfPossible(context: context)
            return
        }

        let install = Process()
        install.executableURL = context.venvPython
        install.arguments = [
            "-m",
            "pip",
            "install",
            "-r",
            context.requirementsURL.path,
            "--quiet",
            "--disable-pip-version-check",
        ]
        install.qualityOfService = .background
        install.currentDirectoryURL = context.appSupportDir

        let errPipe = Pipe()
        install.standardError = errPipe
        install.standardOutput = Pipe()
        try install.run()
        install.waitUntilExit()
        if install.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BackendError.bootstrapFailed(err)
        }

        try expectedHash.write(to: marker, atomically: true, encoding: .utf8)
        installOptionalWebRTCAPMIfPossible(context: context)
    }

    private func installOptionalWebRTCAPMIfPossible(context: BootstrapContext) {
        guard let swigPath = availableSwigPath() else {
            appLogger.log("Optional WebRTC APM install skipped: swig not found.", type: .warning)
            return
        }
        guard !pythonModuleExists(moduleName: "webrtc_audio_processing", python: context.venvPython) else {
            return
        }

        let install = Process()
        install.executableURL = context.venvPython
        install.arguments = [
            "-m",
            "pip",
            "install",
            "webrtc-audio-processing>=0.1.3",
            "--quiet",
            "--disable-pip-version-check",
        ]
        install.currentDirectoryURL = context.appSupportDir
        install.qualityOfService = .background

        let errPipe = Pipe()
        install.standardError = errPipe
        install.standardOutput = Pipe()

        do {
            try install.run()
            install.waitUntilExit()
            if install.terminationStatus == 0 {
                appLogger.log("Optional WebRTC APM installed successfully via \(swigPath).")
                return
            }
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if installPatchedWebRTCAPMOnMac(context: context) {
                appLogger.log("Optional WebRTC APM installed via patched macOS fallback.")
                return
            }
            appLogger.log(
                "Optional WebRTC APM install failed (non-fatal): \(err.trimmingCharacters(in: .whitespacesAndNewlines))",
                type: .warning
            )
        } catch {
            if installPatchedWebRTCAPMOnMac(context: context) {
                appLogger.log("Optional WebRTC APM installed via patched macOS fallback.")
                return
            }
            appLogger.log("Optional WebRTC APM install launch failed (non-fatal): \(error.localizedDescription)", type: .warning)
        }
    }

    private func installPatchedWebRTCAPMOnMac(context: BootstrapContext) -> Bool {
        guard let scriptURL = context.apmInstallerScriptURL else {
            appLogger.log("Patched WebRTC APM fallback skipped: installer script missing in bundle.", type: .warning)
            return false
        }

        let fallback = Process()
        fallback.executableURL = URL(fileURLWithPath: "/bin/zsh")
        fallback.arguments = [scriptURL.path, context.venvPython.path]
        fallback.currentDirectoryURL = context.appSupportDir
        fallback.qualityOfService = .background
        fallback.environment = ProcessInfo.processInfo.environment

        let errPipe = Pipe()
        let outPipe = Pipe()
        fallback.standardError = errPipe
        fallback.standardOutput = outPipe

        do {
            try fallback.run()
            fallback.waitUntilExit()
            guard fallback.terminationStatus == 0 else {
                let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let detail = [output, err]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                appLogger.log(
                    "Patched WebRTC APM fallback failed (non-fatal): \(detail)",
                    type: .warning
                )
                return false
            }
            return pythonModuleExists(moduleName: "webrtc_audio_processing", python: context.venvPython)
        } catch {
            appLogger.log(
                "Patched WebRTC APM fallback launch failed (non-fatal): \(error.localizedDescription)",
                type: .warning
            )
            return false
        }
    }

    private func pythonModuleExists(moduleName: String, python: URL) -> Bool {
        let probe = Process()
        probe.executableURL = python
        probe.arguments = [
            "-c",
            "import importlib.util,sys;sys.exit(0 if importlib.util.find_spec('\(moduleName)') else 1)",
        ]
        probe.qualityOfService = .background
        probe.standardError = Pipe()
        probe.standardOutput = Pipe()
        do {
            try probe.run()
            probe.waitUntilExit()
            return probe.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Minimum Python version required by MLX and other dependencies.
    private static let minimumPythonVersion = (major: 3, minor: 10)

    /// Finds the best available `python3` executable that meets the minimum version.
    /// Checks Homebrew installations first, then falls back to the system PATH `python3`.
    private func findBestPython() -> (path: String, version: (Int, Int))? {
        let candidates: [String] = [
            "/opt/homebrew/bin/python3",      // Homebrew ARM
            "/usr/local/bin/python3",         // Homebrew Intel
        ]

        // Also discover Homebrew-versioned Python binaries (e.g. python3.12, python3.11)
        var versionedCandidates: [String] = []
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            for minor in stride(from: 13, through: 10, by: -1) {
                versionedCandidates.append("\(dir)/python3.\(minor)")
            }
        }

        let allCandidates = candidates + versionedCandidates + ["/usr/bin/python3"]

        var best: (path: String, version: (Int, Int))?
        for path in allCandidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard let ver = pythonVersion(at: path) else { continue }
            if ver.0 < Self.minimumPythonVersion.major || (ver.0 == Self.minimumPythonVersion.major && ver.1 < Self.minimumPythonVersion.minor) {
                continue
            }
            if let current = best {
                if ver.0 > current.version.0 || (ver.0 == current.version.0 && ver.1 > current.version.1) {
                    best = (path, ver)
                }
            } else {
                best = (path, ver)
            }
        }
        return best
    }

    /// Returns (major, minor) version tuple for the Python executable at `path`, or nil on failure.
    private func pythonVersion(at path: String) -> (Int, Int)? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["-c", "import sys; print(sys.version_info.major, sys.version_info.minor)"]
        proc.qualityOfService = .background
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parts = output.split(separator: " ")
            guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
            return (major, minor)
        } catch {
            return nil
        }
    }

    /// Returns the Python version inside the venv, or nil if it cannot be determined.
    private func venvPythonVersion(at venvPython: URL) -> (Int, Int)? {
        guard FileManager.default.isExecutableFile(atPath: venvPython.path) else { return nil }
        return pythonVersion(at: venvPython.path)
    }

    private func availableSwigPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/swig",
            "/usr/local/bin/swig",
            "/usr/bin/swig",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private func launchService(context: BootstrapContext, config: LaunchConfig) throws {
        if let running = process, running.isRunning {
            return
        }

        let serviceProcess = Process()
        serviceProcess.executableURL = context.venvPython
        serviceProcess.arguments = [
            context.serviceScriptURL.path,
            "--host",
            host,
            "--port",
            "\(port)",
            "--state-dir",
            context.appSupportDir.appendingPathComponent("state").path,
            "--asr-model",
            config.asrModel,
            "--llm-model",
            config.llmModel,
            "--idle-timeout",
            "\(config.idleTimeoutSeconds ?? 0)",
        ]
        serviceProcess.currentDirectoryURL = context.appSupportDir
        serviceProcess.qualityOfService = .background

        let outPipe = Pipe()
        let errPipe = Pipe()
        serviceProcess.standardOutput = outPipe
        serviceProcess.standardError = errPipe

        stderrTail.removeAll(keepingCapacity: true)
        stdoutPipe = outPipe
        stderrPipe = errPipe
        startDrainingPipesLocked(stdout: outPipe, stderr: errPipe)
        serviceProcess.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                let stderrExcerpt = self.recentStderrLocked()
                if stderrExcerpt.isEmpty {
                    self.appLogger.log("Python backend process terminated.")
                } else {
                    self.appLogger.log("Python backend process terminated. stderr tail: \(stderrExcerpt)", type: .error)
                }
                self.stopDrainingPipesLocked()
                self.process = nil
                self.startedByManager = false
                self.runningLaunchConfig = nil
            }
        }

        do {
            try serviceProcess.run()
        } catch {
            stopDrainingPipesLocked()
            throw BackendError.startFailed(error.localizedDescription)
        }

        process = serviceProcess
        startedByManager = true
        appLogger.log("Python backend launched with script: \(context.serviceScriptURL.path)")
    }

    private func finishStarting(with result: Result<Void, Error>) {
        let completions = pendingCompletions
        pendingCompletions.removeAll()
        isStarting = false
        switch result {
        case .success:
            appLogger.log("Backend start flow completed successfully.")
        case .failure(let error):
            appLogger.log("Backend start flow failed: \(error.localizedDescription)", type: .error)
        }
        DispatchQueue.main.async {
            for completion in completions {
                completion(result)
            }
        }
    }

    private func requirementsHash(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw BackendError.invalidRequirementsHash
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func terminateManagedProcessLocked() {
        guard startedByManager, let process else { return }
        guard process.isRunning else {
            stopDrainingPipesLocked()
            self.process = nil
            self.startedByManager = false
            self.runningLaunchConfig = nil
            return
        }

        process.terminate()
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            usleep(120_000)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }

        appLogger.log("Managed Python backend terminated.")
        stopDrainingPipesLocked()
        self.process = nil
        self.startedByManager = false
        self.runningLaunchConfig = nil
    }

    private func terminateUnexpectedBackendOnPortLocked() {
        let pids = listeningPIDsOnPortLocked(port)
        guard !pids.isEmpty else { return }

        for pid in pids {
            guard pid > 0 else { continue }
            if let owned = process?.processIdentifier, owned == pid {
                continue
            }
            guard let command = commandLineForPIDLocked(pid) else { continue }
            let isManagedService =
                (command.contains(AppIdentity.currentAppName) || command.contains(AppIdentity.legacyAppName))
                && command.contains(AppIdentity.serviceScriptName)
            guard isManagedService else { continue }
            terminateExternalProcessLocked(pid)
        }
    }

    private func terminateUnexpectedServiceProcessesLocked() {
        let patterns = [
            "\(AppIdentity.currentAppName).app/Contents/Resources/\(AppIdentity.serviceScriptName)",
            "\(AppIdentity.legacyAppName).app/Contents/Resources/\(AppIdentity.serviceScriptName)",
        ]
        let candidates = Set(patterns.flatMap { pidsMatchingPatternLocked($0) })
        guard !candidates.isEmpty else { return }

        for pid in candidates {
            guard pid > 0, pid != Int32(getpid()) else { continue }
            if let owned = process?.processIdentifier, owned == pid {
                continue
            }
            guard let command = commandLineForPIDLocked(pid) else { continue }
            let isPythonService =
                command.contains("Python")
                && command.contains(AppIdentity.serviceScriptName)
                && command.contains("--host")
                && command.contains("--port")
            guard isPythonService else { continue }
            terminateExternalProcessLocked(pid)
        }
    }

    private func pidsMatchingPatternLocked(_ pattern: String) -> [Int32] {
        let output = runCommandLocked(executable: "/usr/bin/pgrep", arguments: ["-f", pattern])
        guard !output.isEmpty else { return [] }
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 }
    }

    private func terminateExternalProcessLocked(_ pid: Int32) {
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(1.5)
        while processExists(pid), Date() < deadline {
            usleep(120_000)
        }
        if processExists(pid) {
            kill(pid, SIGKILL)
        }
    }

    private func listeningPIDsOnPortLocked(_ port: Int) -> [Int32] {
        let output = runCommandLocked(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        )
        guard !output.isEmpty else { return [] }
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 }
    }

    private func commandLineForPIDLocked(_ pid: Int32) -> String? {
        let output = runCommandLocked(
            executable: "/bin/ps",
            arguments: ["-p", "\(pid)", "-o", "command="]
        )
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func runCommandLocked(executable: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return ""
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            return ""
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func processExists(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func startDrainingPipesLocked(stdout: Pipe, stderr: Pipe) {
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.queue.async {
                self.logPipeChunkLocked(data, source: "PY STDOUT", type: .info)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async {
                self?.appendStderrTailLocked(data)
                self?.logPipeChunkLocked(data, source: "PY STDERR", type: .error)
            }
        }
    }

    private func stopDrainingPipesLocked() {
        if let outHandle = stdoutPipe?.fileHandleForReading {
            outHandle.readabilityHandler = nil
            outHandle.closeFile()
        }
        if let errHandle = stderrPipe?.fileHandleForReading {
            errHandle.readabilityHandler = nil
            errHandle.closeFile()
        }
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func appendStderrTailLocked(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrTail.append(data)
        if stderrTail.count > stderrTailLimit {
            let extra = stderrTail.count - stderrTailLimit
            stderrTail.removeFirst(extra)
        }
    }

    private func logPipeChunkLocked(_ data: Data, source: String, type: LogType) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }

        for line in lines {
            appLogger.log("\(source): \(line)", type: type)
        }
    }

    private func recentStderrLocked() -> String {
        String(data: stderrTail, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func postIdleTimeoutConfig(seconds: Int?) {
        if Thread.isMainThread {
            appLogger.log("Idle-timeout update called on main thread; dispatching to backend queue.", type: .warning)
            queue.async { [weak self] in
                self?.postIdleTimeoutConfig(seconds: seconds)
            }
            return
        }

        checkHealth(timeout: 1.5) { healthy in
            guard healthy else { return }
            let url = URL(string: "http://\(self.host):\(self.port)/config/memory-timeout")!
            var request = URLRequest(url: url, timeoutInterval: 3.0)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let timeoutValue = seconds ?? -1
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: ["idle_timeout_seconds": timeoutValue])
            } catch {
                self.appLogger.log("Failed to encode idle-timeout payload: \(error.localizedDescription)", type: .error)
                return
            }

            Task.detached(priority: .utility) { [healthSession = self.healthSession, appLogger = self.appLogger] in
                do {
                    let (_, response) = try await healthSession.data(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        appLogger.log("Idle-timeout update failed: missing HTTP response.", type: .warning)
                        return
                    }
                    guard (200...299).contains(http.statusCode) else {
                        appLogger.log("Idle-timeout update failed: HTTP \(http.statusCode).", type: .warning)
                        return
                    }
                } catch {
                    appLogger.log("Idle-timeout update request failed: \(error.localizedDescription)", type: .warning)
                }
            }
        }
    }

    private func checkHealth(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let healthy = await self.isHealthy(timeout: timeout)
            self.queue.async {
                completion(healthy)
            }
        }
    }

    private func isHealthy(timeout: TimeInterval) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/health") else {
            appLogger.log("Invalid backend health URL for host \(host):\(port).", type: .error)
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        var didLogInvalidPayload = false

        while Date() < deadline {
            let request = URLRequest(url: url, timeoutInterval: 0.9)
            do {
                let (data, response) = try await healthSession.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    continue
                }

                do {
                    let object = try JSONSerialization.jsonObject(with: data, options: [])
                    guard let payload = object as? [String: Any] else {
                        if !didLogInvalidPayload {
                            didLogInvalidPayload = true
                            appLogger.log("Backend health check returned a non-object JSON payload.", type: .warning)
                        }
                        continue
                    }
                    if String(describing: payload["status"] ?? "") == "ok" {
                        return true
                    }
                    if !didLogInvalidPayload {
                        didLogInvalidPayload = true
                        appLogger.log("Backend health check payload missing status=ok.", type: .warning)
                    }
                } catch {
                    if !didLogInvalidPayload {
                        didLogInvalidPayload = true
                        appLogger.log("Failed to parse backend health payload: \(error.localizedDescription)", type: .warning)
                    }
                }
            } catch {
                // Retry until timeout.
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let sleepNanos = UInt64(min(0.18, remaining) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: sleepNanos)
            } catch {
                return false
            }
        }
        return false
    }
}
