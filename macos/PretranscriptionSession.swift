import Foundation

struct PretranscriptionConfig: Sendable {
    let enabled: Bool
    let stepSeconds: Double
    let overlapSeconds: Double
    let maxChunkSeconds: Double
    let minSpeechSeconds: Double
    let endSilenceMS: Int
    let maxInFlight: Int
    let fallbackPolicy: PretranscribeFallbackPolicyOption
    let failureRateThreshold: Double
    let backlogThresholdSeconds: Double

    @MainActor
    static func from(state: AppState) -> PretranscriptionConfig {
        PretranscriptionConfig(
            enabled: state.pretranscribeEnabled,
            stepSeconds: Self.clamp(state.pretranscribeStepSeconds, min: 1.0, max: 30.0, fallback: 5.0),
            overlapSeconds: Self.clamp(state.pretranscribeOverlapSeconds, min: 0.1, max: 3.0, fallback: 0.6),
            maxChunkSeconds: Self.clamp(state.pretranscribeMaxChunkSeconds, min: 2.0, max: 60.0, fallback: 10.0),
            minSpeechSeconds: Self.clamp(state.pretranscribeMinSpeechSeconds, min: 0.3, max: 10.0, fallback: 1.2),
            endSilenceMS: max(120, min(state.pretranscribeEndSilenceMS, 1500)),
            maxInFlight: max(1, min(state.pretranscribeMaxInFlight, 4)),
            fallbackPolicy: state.pretranscribeFallbackPolicy,
            failureRateThreshold: 0.35,
            backlogThresholdSeconds: 20.0
        )
    }

    private static func clamp(_ value: Double, min lower: Double, max upper: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return Swift.max(lower, Swift.min(upper, value))
    }
}

struct PretranscriptionASRResult: Sendable {
    let text: String
    let detectedLanguage: String?
    let timingMS: [String: Double]
}

struct PretranscriptionRuntimeSnapshot: Sendable {
    let status: String
    let completedChunks: Int
    let queueDepth: Int
    let lastChunkLatencyMS: Double
}

struct PretranscriptionFinalResult: Sendable {
    let transcript: String
    let detectedLanguage: String?
    let fallbackUsed: Bool
    let lowConfidenceMerges: Int
    let asrRequestsCount: Int
    let completedChunks: Int
    let failedChunks: Int
    let firstChunkLatencyMS: Double?
    let lastChunkLatencyMS: Double
    let maxBacklogSeconds: Double
}

actor PretranscriptionSession {
    typealias ChunkASRTranscriber = @Sendable (URL) async throws -> PretranscriptionASRResult
    typealias FullASRTranscriber = @Sendable (URL) async throws -> PretranscriptionASRResult
    typealias RuntimeUpdateHandler = @Sendable (PretranscriptionRuntimeSnapshot) -> Void
    typealias LogHandler = @Sendable (String) -> Void

    private struct ChunkJob: Sendable {
        let id: Int
        let startSample: Int
        let endSample: Int
        let anchorEndSample: Int
        let createdAt: Date
    }

    private struct ChunkResult: Sendable {
        let id: Int
        let anchorEndSample: Int
        let text: String
        let detectedLanguage: String?
        let latencyMS: Double
    }

    private enum Constants {
        static let sampleRate = 16_000
        static let vadFrameSamples = 320 // 20ms @ 16k
        static let speechRMSGateDBFS: Float = -52
        static let speechPeakGateDBFS: Float = -42
        static let overlapAlignmentMaxChars = 160
        static let overlapAlignmentMinChars = 6
        static let overlapAlignmentMinCharsCJK = 2
    }

    private let config: PretranscriptionConfig
    private let chunkTranscriber: ChunkASRTranscriber
    private let fullASRTranscriber: FullASRTranscriber?
    private let runtimeUpdate: RuntimeUpdateHandler
    private let logger: LogHandler
    private let chunkDirectory: URL
    private let startedAt = Date()

    private var samples: [Int16] = []
    private var frameRemainder: [Int16] = []
    private var speechFrames: [Bool] = []

    private var queuedJobs: [ChunkJob] = []
    private var inFlightJobs = 0
    private var nextChunkID = 0
    private var nextExpectedResultID = 0
    private var receivedResults: [Int: ChunkResult] = [:]

    private var lastChunkAnchorSample = 0
    private var committedAnchorSample = 0
    private var committedTranscript = ""
    private var committedDetectedLanguage: String?

    private var completedChunks = 0
    private var failedChunks = 0
    private var asrRequestsCount = 0
    private var lowConfidenceMerges = 0
    private var firstChunkLatencyMS: Double?
    private var lastChunkLatencyMS: Double = 0
    private var maxBacklogSeconds: Double = 0
    private var stopRequested = false
    private var fallbackRequired = false
    private var finalAudioURL: URL?
    private var finishContinuation: CheckedContinuation<PretranscriptionFinalResult, Never>?
    private var finalResult: PretranscriptionFinalResult?

    init(
        config: PretranscriptionConfig,
        sessionID: UUID,
        chunkTranscriber: @escaping ChunkASRTranscriber,
        fullASRTranscriber: FullASRTranscriber?,
        runtimeUpdate: @escaping RuntimeUpdateHandler,
        logger: @escaping LogHandler
    ) {
        self.config = config
        self.chunkTranscriber = chunkTranscriber
        self.fullASRTranscriber = fullASRTranscriber
        self.runtimeUpdate = runtimeUpdate
        self.logger = logger
        self.chunkDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosttype-pretranscribe", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
        runtimeUpdate(
            PretranscriptionRuntimeSnapshot(
                status: config.enabled ? "On" : "Off",
                completedChunks: 0,
                queueDepth: 0,
                lastChunkLatencyMS: 0
            )
        )
    }

    func append(samples newSamples: [Int16]) {
        guard config.enabled, !stopRequested, !newSamples.isEmpty else { return }
        samples.append(contentsOf: newSamples)
        updateVADFrames(with: newSamples)
        scheduleChunkIfNeeded(force: false)
        dispatchQueuedJobsIfNeeded()
        updateBacklogSeconds()
        evaluateFallbackConditions()
        pushRuntimeSnapshot(status: fallbackRequired ? "Fallback Pending" : "On")
    }

    func finish(finalAudioURL: URL) async -> PretranscriptionFinalResult {
        if let finalResult {
            return finalResult
        }
        self.finalAudioURL = finalAudioURL
        stopRequested = true

        scheduleChunkIfNeeded(force: true)
        dispatchQueuedJobsIfNeeded()

        if queuedJobs.isEmpty, inFlightJobs == 0 {
            let result = await finalizeResult()
            finalResult = result
            return result
        }

        return await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func cancel() {
        stopRequested = true
        queuedJobs.removeAll()
        if let continuation = finishContinuation {
            finishContinuation = nil
            let result = PretranscriptionFinalResult(
                transcript: committedTranscript,
                detectedLanguage: committedDetectedLanguage,
                fallbackUsed: false,
                lowConfidenceMerges: lowConfidenceMerges,
                asrRequestsCount: asrRequestsCount,
                completedChunks: completedChunks,
                failedChunks: failedChunks,
                firstChunkLatencyMS: firstChunkLatencyMS,
                lastChunkLatencyMS: lastChunkLatencyMS,
                maxBacklogSeconds: maxBacklogSeconds
            )
            continuation.resume(returning: result)
        }
        try? FileManager.default.removeItem(at: chunkDirectory)
    }

    private func scheduleChunkIfNeeded(force: Bool) {
        guard config.enabled else { return }
        let availableEnd = availableEndSample(force: force)
        guard availableEnd > lastChunkAnchorSample else { return }

        let deltaSec = seconds(forSamples: availableEnd - lastChunkAnchorSample)
        let speechSec = speechSeconds(fromSample: lastChunkAnchorSample, toSample: availableEnd)
        let shouldSubmit = force || deltaSec >= config.stepSeconds || speechSec >= config.maxChunkSeconds
        guard shouldSubmit else { return }

        let overlapSamples = sampleCount(seconds: config.overlapSeconds)
        let startSample = max(0, lastChunkAnchorSample - overlapSamples)
        let endSample = availableEnd
        guard endSample > startSample else { return }

        let chunkSpeechSec = speechSeconds(fromSample: startSample, toSample: endSample)
        if !force, chunkSpeechSec < config.minSpeechSeconds {
            return
        }

        queuedJobs.append(
            ChunkJob(
                id: nextChunkID,
                startSample: startSample,
                endSample: endSample,
                anchorEndSample: endSample,
                createdAt: Date()
            )
        )
        nextChunkID += 1
        lastChunkAnchorSample = endSample
    }

    private func dispatchQueuedJobsIfNeeded() {
        guard config.enabled else { return }
        guard !fallbackRequired else {
            queuedJobs.removeAll()
            return
        }

        while inFlightJobs < config.maxInFlight, !queuedJobs.isEmpty {
            let job = queuedJobs.removeFirst()
            inFlightJobs += 1
            asrRequestsCount += 1

            let chunkSamples = Array(samples[job.startSample..<job.endSample])
            let chunkURL = chunkDirectory.appendingPathComponent("chunk-\(job.id).wav")

            Task.detached(priority: .utility) { [chunkTranscriber, logger] in
                do {
                    try Self.writeMonoPCM16WAV(
                        samples: chunkSamples,
                        sampleRate: Constants.sampleRate,
                        destinationURL: chunkURL
                    )
                    let response = try await chunkTranscriber(chunkURL)
                    try? FileManager.default.removeItem(at: chunkURL)
                    await self.handleChunkSuccess(job: job, response: response)
                } catch {
                    try? FileManager.default.removeItem(at: chunkURL)
                    logger("Pretranscribe chunk \(job.id) failed: \(error.localizedDescription)")
                    await self.handleChunkFailure(job: job)
                }
            }
        }
    }

    private func handleChunkSuccess(job: ChunkJob, response: PretranscriptionASRResult) async {
        inFlightJobs = max(0, inFlightJobs - 1)
        let latency = max(0, Date().timeIntervalSince(job.createdAt) * 1000)
        lastChunkLatencyMS = latency
        if firstChunkLatencyMS == nil {
            firstChunkLatencyMS = Date().timeIntervalSince(startedAt) * 1000
        }

        receivedResults[job.id] = ChunkResult(
            id: job.id,
            anchorEndSample: job.anchorEndSample,
            text: response.text.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: response.detectedLanguage,
            latencyMS: latency
        )

        mergeReadyChunks()
        updateBacklogSeconds()
        evaluateFallbackConditions()
        dispatchQueuedJobsIfNeeded()
        pushRuntimeSnapshot(status: fallbackRequired ? "Fallback Pending" : "On")
        await maybeCompleteIfNeeded()
    }

    private func handleChunkFailure(job: ChunkJob) async {
        inFlightJobs = max(0, inFlightJobs - 1)
        failedChunks += 1
        receivedResults[job.id] = ChunkResult(
            id: job.id,
            anchorEndSample: job.anchorEndSample,
            text: "",
            detectedLanguage: nil,
            latencyMS: 0
        )

        mergeReadyChunks()
        updateBacklogSeconds()
        evaluateFallbackConditions()
        dispatchQueuedJobsIfNeeded()
        pushRuntimeSnapshot(status: fallbackRequired ? "Fallback Pending" : "On")
        await maybeCompleteIfNeeded()
    }

    private func mergeReadyChunks() {
        while let result = receivedResults.removeValue(forKey: nextExpectedResultID) {
            nextExpectedResultID += 1
            committedAnchorSample = max(committedAnchorSample, result.anchorEndSample)

            let cleaned = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                if committedTranscript.isEmpty {
                    committedTranscript = cleaned
                } else {
                    let merged = Self.mergeWithSuffixPrefixAlignment(
                        existing: committedTranscript,
                        incoming: cleaned
                    )
                    committedTranscript = merged.text
                    if !merged.aligned {
                        lowConfidenceMerges += 1
                    }
                }
                if committedDetectedLanguage == nil {
                    committedDetectedLanguage = result.detectedLanguage
                }
            }
            completedChunks += 1
        }
    }

    private func evaluateFallbackConditions() {
        let totalFinished = completedChunks + failedChunks
        guard totalFinished > 0 else { return }
        let failureRate = Double(failedChunks) / Double(totalFinished)
        if failureRate >= config.failureRateThreshold {
            fallbackRequired = true
        }
        if maxBacklogSeconds >= config.backlogThresholdSeconds {
            fallbackRequired = true
        }
    }

    private func availableEndSample(force: Bool) -> Int {
        if force {
            return samples.count
        }
        let overlapSamples = sampleCount(seconds: config.overlapSeconds)
        let trailingSilenceMS = trailingSilenceDurationMS()
        let holdbackSamples = trailingSilenceMS >= config.endSilenceMS ? 0 : overlapSamples
        return max(0, samples.count - holdbackSamples)
    }

    private func updateVADFrames(with newSamples: [Int16]) {
        var working = frameRemainder
        working.append(contentsOf: newSamples)
        var cursor = 0

        while cursor + Constants.vadFrameSamples <= working.count {
            let frame = Array(working[cursor..<(cursor + Constants.vadFrameSamples)])
            speechFrames.append(Self.isSpeechFrame(frame))
            cursor += Constants.vadFrameSamples
        }

        if cursor < working.count {
            frameRemainder = Array(working[cursor...])
        } else {
            frameRemainder.removeAll(keepingCapacity: true)
        }
    }

    private func trailingSilenceDurationMS() -> Int {
        guard !speechFrames.isEmpty else { return 0 }
        var silentFrames = 0
        for flag in speechFrames.reversed() {
            if flag {
                break
            }
            silentFrames += 1
        }
        return Int(seconds(forSamples: silentFrames * Constants.vadFrameSamples) * 1000.0)
    }

    private func speechSeconds(fromSample startSample: Int, toSample endSample: Int) -> Double {
        guard endSample > startSample else { return 0 }
        let startFrame = max(0, startSample / Constants.vadFrameSamples)
        let endFrameExclusive = max(startFrame, Int(ceil(Double(endSample) / Double(Constants.vadFrameSamples))))
        guard startFrame < speechFrames.count else { return 0 }

        let clampedEnd = min(endFrameExclusive, speechFrames.count)
        guard clampedEnd > startFrame else { return 0 }
        let speechFrameCount = speechFrames[startFrame..<clampedEnd].filter { $0 }.count
        return seconds(forSamples: speechFrameCount * Constants.vadFrameSamples)
    }

    private func updateBacklogSeconds() {
        let recordedSeconds = seconds(forSamples: samples.count)
        let committedSeconds = seconds(forSamples: committedAnchorSample)
        maxBacklogSeconds = max(maxBacklogSeconds, max(0, recordedSeconds - committedSeconds))
    }

    private func pushRuntimeSnapshot(status: String) {
        runtimeUpdate(
            PretranscriptionRuntimeSnapshot(
                status: status,
                completedChunks: completedChunks,
                queueDepth: queuedJobs.count + inFlightJobs,
                lastChunkLatencyMS: lastChunkLatencyMS
            )
        )
    }

    private func maybeCompleteIfNeeded() async {
        guard stopRequested else { return }
        guard queuedJobs.isEmpty, inFlightJobs == 0 else { return }
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        let result = await finalizeResult()
        finalResult = result
        continuation.resume(returning: result)
    }

    private func finalizeResult() async -> PretranscriptionFinalResult {
        var finalTranscript = committedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        var detectedLanguage = committedDetectedLanguage
        var fallbackUsed = false

        let shouldFallback = config.fallbackPolicy == .fullASROnHighFailure
            && (fallbackRequired || finalTranscript.isEmpty)
        if shouldFallback,
           let finalAudioURL,
           let fullASRTranscriber {
            do {
                let fallbackResult = try await fullASRTranscriber(finalAudioURL)
                let fallbackText = fallbackResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !fallbackText.isEmpty {
                    finalTranscript = fallbackText
                    detectedLanguage = fallbackResult.detectedLanguage
                    fallbackUsed = true
                }
            } catch {
                logger("Pretranscribe fallback ASR failed: \(error.localizedDescription)")
            }
        }

        let result = PretranscriptionFinalResult(
            transcript: finalTranscript,
            detectedLanguage: detectedLanguage,
            fallbackUsed: fallbackUsed,
            lowConfidenceMerges: lowConfidenceMerges,
            asrRequestsCount: asrRequestsCount,
            completedChunks: completedChunks,
            failedChunks: failedChunks,
            firstChunkLatencyMS: firstChunkLatencyMS,
            lastChunkLatencyMS: lastChunkLatencyMS,
            maxBacklogSeconds: maxBacklogSeconds
        )

        pushRuntimeSnapshot(status: fallbackUsed ? "Fallback Used" : "Done")
        try? FileManager.default.removeItem(at: chunkDirectory)
        return result
    }

    private func seconds(forSamples sampleCount: Int) -> Double {
        Double(sampleCount) / Double(Constants.sampleRate)
    }

    private func sampleCount(seconds: Double) -> Int {
        Int((seconds * Double(Constants.sampleRate)).rounded(.toNearestOrEven))
    }

    private static func isSpeechFrame(_ frame: [Int16]) -> Bool {
        guard !frame.isEmpty else { return false }
        let minAmplitude = 1e-7
        var sumSquares = 0.0
        var peak = 0.0

        for sample in frame {
            let value = Double(sample) / 32768.0
            let absValue = abs(value)
            peak = max(peak, absValue)
            sumSquares += value * value
        }

        let rms = sqrt(sumSquares / Double(frame.count))
        let rmsDBFS = Float(20.0 * log10(max(rms, minAmplitude)))
        let peakDBFS = Float(20.0 * log10(max(peak, minAmplitude)))
        return rmsDBFS >= Constants.speechRMSGateDBFS || peakDBFS >= Constants.speechPeakGateDBFS
    }

    private static func mergeWithSuffixPrefixAlignment(existing: String, incoming: String) -> (text: String, aligned: Bool) {
        let existingTrimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingTrimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existingTrimmed.isEmpty else { return (incomingTrimmed, true) }
        guard !incomingTrimmed.isEmpty else { return (existingTrimmed, true) }

        let minimumOverlapLength: Int = (containsCJK(existingTrimmed) || containsCJK(incomingTrimmed))
            ? Constants.overlapAlignmentMinCharsCJK
            : Constants.overlapAlignmentMinChars
        let maxLength = min(Constants.overlapAlignmentMaxChars, existingTrimmed.count, incomingTrimmed.count)
        if maxLength < minimumOverlapLength {
            return ("\(existingTrimmed)\n\(incomingTrimmed)", false)
        }

        for length in stride(from: maxLength, through: minimumOverlapLength, by: -1) {
            let existingSuffix = String(existingTrimmed.suffix(length)).lowercased()
            let incomingPrefix = String(incomingTrimmed.prefix(length)).lowercased()
            if existingSuffix == incomingPrefix {
                let remainder = String(incomingTrimmed.dropFirst(length)).trimmingCharacters(in: .whitespacesAndNewlines)
                if remainder.isEmpty {
                    return (existingTrimmed, true)
                }
                return ("\(existingTrimmed)\(remainder)", true)
            }
        }

        return ("\(existingTrimmed)\n\(incomingTrimmed)", false)
    }

    private static func containsCJK(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, // Hiragana + Katakana
                 0x3400...0x4DBF, // CJK Unified Ideographs Extension A
                 0x4E00...0x9FFF, // CJK Unified Ideographs
                 0xF900...0xFAFF, // CJK Compatibility Ideographs
                 0xAC00...0xD7AF: // Hangul Syllables
                return true
            default:
                continue
            }
        }
        return false
    }

    private static func writeMonoPCM16WAV(samples: [Int16], sampleRate: Int, destinationURL: URL) throws {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)

        var pcmData = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            var value = sample.littleEndian
            withUnsafeBytes(of: &value) { pcmData.append(contentsOf: $0) }
        }

        let subchunk2Size = UInt32(pcmData.count)
        let chunkSize = 36 + subchunk2Size

        var data = Data(capacity: Int(44 + subchunk2Size))
        data.append("RIFF".data(using: .ascii)!)
        data.append(uint32LE(chunkSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(uint32LE(16))
        data.append(uint16LE(1)) // PCM
        data.append(uint16LE(numChannels))
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(byteRate))
        data.append(uint16LE(blockAlign))
        data.append(uint16LE(bitsPerSample))
        data.append("data".data(using: .ascii)!)
        data.append(uint32LE(subchunk2Size))
        data.append(pcmData)

        try data.write(to: destinationURL, options: .atomic)
    }

    private static func uint16LE(_ value: UInt16) -> Data {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }

    private static func uint32LE(_ value: UInt32) -> Data {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }
}
