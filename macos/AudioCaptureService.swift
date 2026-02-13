import AVFoundation
import Foundation

enum AudioCaptureError: LocalizedError {
    case permissionDenied
    case alreadyRecording
    case notRecording
    case fileCreationFailed
    case normalizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission denied."
        case .alreadyRecording:
            return "Recording is already active."
        case .notRecording:
            return "Recording is not active."
        case .fileCreationFailed:
            return "Could not create output audio file."
        case .normalizationFailed(let reason):
            return "Audio normalization failed: \(reason)"
        }
    }
}

struct AudioLevelTelemetry {
    let rmsDBFS: Float
    let peakDBFS: Float
    let vadSpeech: Bool
}

struct AudioPCMChunk {
    let sampleRate: Int
    let startSampleIndex: Int64
    let samples: [Int16]
}

protocol AudioRecordingService: AnyObject {
    var onLevelUpdate: ((AudioLevelTelemetry) -> Void)? { get set }
    var onPCMChunk: ((AudioPCMChunk) -> Void)? { get set }
    func startRecording(enhancementMode: AudioEnhancementModeOption) throws
    func stopRecording() async throws -> URL
}

final class AudioCaptureService {
    private enum CaptureConstants {
        static let normalizationDelaySeconds: TimeInterval = 0.2
        static let minimumSourceFileSizeBytes: UInt64 = 1024
        static let normalizationTimeoutSeconds: TimeInterval = 15
        static let levelUpdateIntervalSeconds: TimeInterval = 0.05
        static let speechRMSGateDBFS: Float = -52
        static let speechPeakGateDBFS: Float = -42
    }

    private let engine = AVAudioEngine()
    private let appLogger = AppLogger.shared
    private let recordingStateLock = NSLock()
    private var outputFile: AVAudioFile?
    private var outputURL: URL?
    private var tapInstalled = false
    private var tapWriteError: Error?
    private var didCaptureFrames = false
    private var lastLevelUpdateTimestamp: TimeInterval = 0
    private var pcmConverter: AVAudioConverter?
    private var pcmOutputFormat: AVAudioFormat?
    private var pcmStartSampleIndex: Int64 = 0
    private var didLogPCMConversionError = false
    private(set) var isRecording = false
    var onLevelUpdate: ((AudioLevelTelemetry) -> Void)?
    var onPCMChunk: ((AudioPCMChunk) -> Void)?

    func startRecording(enhancementMode: AudioEnhancementModeOption = .webRTC) throws {
        guard !isRecording else { throw AudioCaptureError.alreadyRecording }
        guard requestMicrophonePermissionIfNeeded() else { throw AudioCaptureError.permissionDenied }
        appLogger.log("Audio capture start requested.")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GhostTypeAudio",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Record raw input first, then normalize to 16kHz/mono/Int16 PCM WAV on stop.
        let targetURL = folder.appendingPathComponent("capture-\(UUID().uuidString).caf")
        let inputNode = engine.inputNode
        configureSystemVoiceProcessingIfNeeded(inputNode: inputNode, mode: enhancementMode)
        let format = inputNode.outputFormat(forBus: 0)
        guard let file = try? AVAudioFile(forWriting: targetURL, settings: format.settings) else {
            throw AudioCaptureError.fileCreationFailed
        }

        outputFile = file
        outputURL = targetURL
        configurePCMChunkConverter(sourceFormat: format)
        recordingStateLock.lock()
        tapWriteError = nil
        didCaptureFrames = false
        lastLevelUpdateTimestamp = 0
        pcmStartSampleIndex = 0
        didLogPCMConversionError = false
        recordingStateLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let outputFile = self.outputFile else { return }
            do {
                try outputFile.write(from: buffer)
                self.recordingStateLock.lock()
                self.didCaptureFrames = true
                self.recordingStateLock.unlock()
            } catch {
                self.recordingStateLock.lock()
                let shouldLog = self.tapWriteError == nil
                self.tapWriteError = error
                self.recordingStateLock.unlock()
                if shouldLog {
                    self.appLogger.log("Audio tap write failed: \(error.localizedDescription)", type: .error)
                }
            }
            self.emitAudioLevelTelemetry(from: buffer)
            self.emitPCMChunk(from: buffer)
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
        isRecording = true
        appLogger.log("Audio capture started: \(targetURL.path)")
    }

    func stopRecording() async throws -> URL {
        let rawURL = try await Task.detached(priority: .utility) { [weak self] in
            guard let self else {
                throw AudioCaptureError.normalizationFailed("Audio capture service released before stop.")
            }
            return try self.stopRecordingPrepareOffMainThread()
        }.value
        let delayNanos = UInt64(CaptureConstants.normalizationDelaySeconds * 1_000_000_000)

        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw AudioCaptureError.normalizationFailed("Audio capture service released before normalization.")
                }
                try await Task.sleep(nanoseconds: delayNanos)
                return try await Task.detached(priority: .utility) {
                    try self.normalizeStoppedRecordingOffMainThread(rawURL: rawURL)
                }.value
            }

            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(CaptureConstants.normalizationTimeoutSeconds * 1_000_000_000)
                )
                throw AudioCaptureError.normalizationFailed("Normalization timed out after file finalization delay.")
            }

            guard let firstResult = try await group.next() else {
                throw AudioCaptureError.normalizationFailed("Normalization finished without a result.")
            }
            group.cancelAll()
            return firstResult
        }
    }

    private func stopRecordingPrepareOffMainThread() throws -> URL {
        guard isRecording else { throw AudioCaptureError.notRecording }
        appLogger.log("Audio capture stop requested.")

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        isRecording = false

        outputFile = nil
        pcmConverter = nil
        pcmOutputFormat = nil
        guard let rawURL = outputURL else { throw AudioCaptureError.fileCreationFailed }
        outputURL = nil

        recordingStateLock.lock()
        let bufferedTapError = tapWriteError
        tapWriteError = nil
        let capturedFrames = didCaptureFrames
        didCaptureFrames = false
        recordingStateLock.unlock()

        if let bufferedTapError {
            throw AudioCaptureError.normalizationFailed("Tap write failed: \(bufferedTapError.localizedDescription)")
        }
        if !capturedFrames {
            throw AudioCaptureError.normalizationFailed("No audio frames were captured.")
        }
        appLogger.log("Recorder stopped. Waiting for file finalization...")
        return rawURL
    }

    private func normalizeStoppedRecordingOffMainThread(rawURL: URL) throws -> URL {
        do {
            let normalizedURL = try normalizeToPCM16Mono16k(sourceURL: rawURL)
            try? FileManager.default.removeItem(at: rawURL)
            appLogger.log("Audio capture normalized successfully: \(normalizedURL.path)")
            return normalizedURL
        } catch let error as AudioCaptureError {
            appLogger.log("Audio normalization failed: \(error.localizedDescription)", type: .error)
            throw error
        } catch {
            appLogger.log("Audio normalization failed: \(error.localizedDescription)", type: .error)
            throw AudioCaptureError.normalizationFailed(error.localizedDescription)
        }
    }

    private func requestMicrophonePermissionIfNeeded() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] isGranted in
                guard let self else { return }
                self.appLogger.log(
                    "Microphone permission request completed: \(isGranted ? "granted" : "denied").",
                    type: isGranted ? .info : .warning
                )
            }
            appLogger.log(
                "Microphone permission not determined; request started and current recording start will be skipped.",
                type: .warning
            )
            return false
        @unknown default:
            return false
        }
    }

    private func configureSystemVoiceProcessingIfNeeded(inputNode: AVAudioInputNode, mode: AudioEnhancementModeOption) {
        if #available(macOS 10.15, *) {
            let shouldEnable = mode == .systemVoiceProcessing
            do {
                if inputNode.isVoiceProcessingEnabled != shouldEnable {
                    try inputNode.setVoiceProcessingEnabled(shouldEnable)
                    appLogger.log("Audio voice processing mode set to \(shouldEnable ? "enabled" : "disabled").")
                }
            } catch {
                appLogger.log("Failed to toggle system voice processing: \(error.localizedDescription)", type: .warning)
            }
        } else {
            if mode == .systemVoiceProcessing {
                appLogger.log("System voice processing is not available on this macOS version.", type: .warning)
            }
        }
    }

    private func emitAudioLevelTelemetry(from buffer: AVAudioPCMBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        recordingStateLock.lock()
        let shouldEmit = now - lastLevelUpdateTimestamp >= CaptureConstants.levelUpdateIntervalSeconds
        if shouldEmit {
            lastLevelUpdateTimestamp = now
        }
        recordingStateLock.unlock()
        guard shouldEmit else { return }

        guard let levels = computeLevels(buffer: buffer) else { return }
        let vadSpeech =
            levels.rmsDBFS >= CaptureConstants.speechRMSGateDBFS
            || levels.peakDBFS >= CaptureConstants.speechPeakGateDBFS
        let telemetry = AudioLevelTelemetry(
            rmsDBFS: levels.rmsDBFS,
            peakDBFS: levels.peakDBFS,
            vadSpeech: vadSpeech
        )

        DispatchQueue.main.async { [weak self] in
            self?.onLevelUpdate?(telemetry)
        }
    }

    private func configurePCMChunkConverter(sourceFormat: AVAudioFormat) {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ),
            let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            pcmConverter = nil
            pcmOutputFormat = nil
            appLogger.log("Failed to initialize PCM chunk converter.", type: .warning)
            return
        }
        pcmConverter = converter
        pcmOutputFormat = targetFormat
    }

    private func emitPCMChunk(from buffer: AVAudioPCMBuffer) {
        guard let onPCMChunk else { return }
        guard let converter = pcmConverter, let targetFormat = pcmOutputFormat else { return }

        let ratio = targetFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let estimatedFrames = max(1, Int(Double(buffer.frameLength) * ratio) + 32)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(estimatedFrames)
        ) else {
            return
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            recordingStateLock.lock()
            let shouldLog = !didLogPCMConversionError
            didLogPCMConversionError = true
            recordingStateLock.unlock()
            if shouldLog {
                appLogger.log("PCM chunk conversion failed: \(conversionError.localizedDescription)", type: .warning)
            }
            return
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            break
        case .error:
            recordingStateLock.lock()
            let shouldLog = !didLogPCMConversionError
            didLogPCMConversionError = true
            recordingStateLock.unlock()
            if shouldLog {
                appLogger.log("PCM chunk conversion returned converter error status.", type: .warning)
            }
            return
        @unknown default:
            return
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return }
        guard let channelData = outputBuffer.int16ChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        guard !samples.isEmpty else { return }

        let startSampleIndex: Int64
        recordingStateLock.lock()
        startSampleIndex = pcmStartSampleIndex
        pcmStartSampleIndex += Int64(samples.count)
        recordingStateLock.unlock()

        onPCMChunk(
            AudioPCMChunk(
                sampleRate: 16_000,
                startSampleIndex: startSampleIndex,
                samples: samples
            )
        )
    }

    private func computeLevels(buffer: AVAudioPCMBuffer) -> (rmsDBFS: Float, peakDBFS: Float)? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        let minAmplitude = 1e-7
        var sumSquares = 0.0
        var peak = 0.0

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData else { return nil }
            let samples = channelData[0]
            for i in 0..<frameCount {
                let value = Double(samples[i])
                let absValue = abs(value)
                if absValue > peak {
                    peak = absValue
                }
                sumSquares += value * value
            }
        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData else { return nil }
            let samples = channelData[0]
            for i in 0..<frameCount {
                let value = Double(samples[i]) / 32768.0
                let absValue = abs(value)
                if absValue > peak {
                    peak = absValue
                }
                sumSquares += value * value
            }
        case .pcmFormatInt32:
            guard let channelData = buffer.int32ChannelData else { return nil }
            let samples = channelData[0]
            for i in 0..<frameCount {
                let value = Double(samples[i]) / 2_147_483_648.0
                let absValue = abs(value)
                if absValue > peak {
                    peak = absValue
                }
                sumSquares += value * value
            }
        default:
            return nil
        }

        let rms = sqrt(sumSquares / Double(frameCount))
        let rmsDBFS = Float(20.0 * log10(max(rms, minAmplitude)))
        let peakDBFS = Float(20.0 * log10(max(peak, minAmplitude)))
        return (rmsDBFS, peakDBFS)
    }

    private func normalizeToPCM16Mono16k(sourceURL: URL) throws -> URL {
        try validateSourceAudioFile(sourceURL)
        appLogger.log("Starting audio normalization for: \(sourceURL.lastPathComponent)")

        let tempNormalized: URL
        do {
            tempNormalized = try normalizeWithAFConvert(sourceURL: sourceURL)
        } catch {
            appLogger.log(
                "afconvert normalization failed, falling back to AVFoundation: \(error.localizedDescription)",
                type: .warning
            )
            tempNormalized = try normalizeWithAVFoundation(sourceURL: sourceURL)
        }

        // Move normalized WAV to dedicated App Support folder, replacing the previous capture.
        let capturesFolder = audioCapturesDirectory()
        try FileManager.default.createDirectory(at: capturesFolder, withIntermediateDirectories: true)
        let destinationURL = capturesFolder.appendingPathComponent("latest_capture.wav")
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tempNormalized, to: destinationURL)
        appLogger.log("Audio capture saved to: \(destinationURL.path)")
        return destinationURL
    }

    private func audioCapturesDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("GhostType", isDirectory: true)
            .appendingPathComponent("AudioCaptures", isDirectory: true)
    }

    private func normalizeWithAFConvert(sourceURL: URL) throws -> URL {
        let outputURL = sourceURL.deletingPathExtension().appendingPathExtension("wav")
        try? FileManager.default.removeItem(at: outputURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
            sourceURL.path,
            outputURL.path,
        ]
        process.qualityOfService = .utility

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw AudioCaptureError.normalizationFailed("Failed to launch afconvert: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown afconvert failure."
            throw AudioCaptureError.normalizationFailed(
                "afconvert exited with code \(process.terminationStatus): \(detail)"
            )
        }

        try validateSourceAudioFile(outputURL)
        try validateNormalizedFormat(url: outputURL)
        appLogger.log("Audio normalization finished with afconvert.")
        return outputURL
    }

    private func normalizeWithAVFoundation(sourceURL: URL) throws -> URL {
        let outputURL = sourceURL.deletingPathExtension()
            .appendingPathExtension("wav")
        try? FileManager.default.removeItem(at: outputURL)

        let sourceFile = try AVAudioFile(forReading: sourceURL)
        let sourceFormat = sourceFile.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.normalizationFailed("Failed to create target format.")
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioCaptureError.normalizationFailed("Failed to create audio converter.")
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )

        let inputBufferCapacity: AVAudioFrameCount = 4096
        while true {
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: inputBufferCapacity
            ) else {
                throw AudioCaptureError.normalizationFailed("Failed to allocate input buffer.")
            }
            try sourceFile.read(into: inputBuffer)
            if inputBuffer.frameLength == 0 {
                break
            }

            let expectedRatio = targetFormat.sampleRate / sourceFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * expectedRatio) + 1024

            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: max(outputCapacity, 1024)
            ) else {
                throw AudioCaptureError.normalizationFailed("Failed to allocate output buffer.")
            }

            var consumed = false
            var convertError: NSError?

            let status = converter.convert(to: convertedBuffer, error: &convertError) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                } else {
                    consumed = true
                    outStatus.pointee = .haveData
                    return inputBuffer
                }
            }

            if let convertError {
                throw AudioCaptureError.normalizationFailed(convertError.localizedDescription)
            }

            switch status {
            case .haveData, .inputRanDry, .endOfStream:
                if convertedBuffer.frameLength > 0 {
                    try outputFile.write(from: convertedBuffer)
                }
            case .error:
                throw AudioCaptureError.normalizationFailed("AVAudioConverter returned .error.")
            @unknown default:
                throw AudioCaptureError.normalizationFailed("Unknown AVAudioConverter status.")
            }
        }

        try validateNormalizedFormat(url: outputURL)
        appLogger.log("Audio normalization finished with AVFoundation fallback.")
        return outputURL
    }

    private func validateSourceAudioFile(_ sourceURL: URL) throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            appLogger.log("Normalization failed: source file does not exist at \(sourceURL.path).", type: .error)
            throw AudioCaptureError.normalizationFailed("Source file does not exist at \(sourceURL.path).")
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            if let size = attributes[.size] as? UInt64,
               size < CaptureConstants.minimumSourceFileSizeBytes
            {
                appLogger.log(
                    "Recording too short (\(size) bytes); skipping normalization.",
                    type: .warning
                )
                throw AudioCaptureError.normalizationFailed(
                    "Recording too short: source file is only \(size) bytes."
                )
            }
        } catch let error as AudioCaptureError {
            throw error
        } catch {
            appLogger.log("Failed to read source file attributes: \(error.localizedDescription)", type: .error)
            throw AudioCaptureError.normalizationFailed(
                "Failed to read source file attributes: \(error.localizedDescription)"
            )
        }
    }

    private func validateNormalizedFormat(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.fileFormat
        let settings = format.settings
        let formatID: UInt32 = {
            if let raw = settings[AVFormatIDKey] as? UInt32 {
                return raw
            }
            if let raw = settings[AVFormatIDKey] as? NSNumber {
                return raw.uint32Value
            }
            return 0
        }()
        let bitDepth: Int = {
            if let raw = settings[AVLinearPCMBitDepthKey] as? Int {
                return raw
            }
            if let raw = settings[AVLinearPCMBitDepthKey] as? NSNumber {
                return raw.intValue
            }
            return 0
        }()
        let isValid =
            format.channelCount == 1 &&
            abs(format.sampleRate - 16_000) < 1 &&
            formatID == kAudioFormatLinearPCM &&
            bitDepth == 16

        if !isValid {
            throw AudioCaptureError.normalizationFailed(
                "Unexpected output format sr=\(format.sampleRate), channels=\(format.channelCount), formatID=\(formatID), bitDepth=\(bitDepth)"
            )
        }
    }
}

extension AudioCaptureService: AudioRecordingService {}
