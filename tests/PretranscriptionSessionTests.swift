import XCTest
@testable import GhostType

final class PretranscriptionSessionTests: XCTestCase {
    private enum TestError: Error, Sendable {
        case simulatedFailure
    }

    func testMergeWithOverlapProducesStableTranscript() async throws {
        let responses = ResponseQueue(values: [
            .success(PretranscriptionASRResult(text: "你好世界", detectedLanguage: "zh", timingMS: [:])),
            .success(PretranscriptionASRResult(text: "世界今天", detectedLanguage: "zh", timingMS: [:])),
            .success(PretranscriptionASRResult(text: "", detectedLanguage: "zh", timingMS: [:])),
        ])
        let snapshots = SnapshotRecorder()
        let session = PretranscriptionSession(
            config: makeConfig(fallback: .off),
            sessionID: UUID(),
            chunkTranscriber: { _ in try await responses.next() },
            fullASRTranscriber: nil,
            runtimeUpdate: { snapshot in
                Task { await snapshots.append(snapshot) }
            },
            logger: { _ in }
        )

        await appendSpeech(to: session, seconds: 2.2, chunkSamples: 8_000)
        let finalURL = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: finalURL) }
        let result = await session.finish(finalAudioURL: finalURL)

        XCTAssertEqual(result.transcript, "你好世界今天")
        XCTAssertFalse(result.fallbackUsed)
        XCTAssertEqual(result.lowConfidenceMerges, 0)
        XCTAssertGreaterThanOrEqual(result.completedChunks, 2)

        let statuses = await snapshots.statuses()
        XCTAssertTrue(statuses.contains("On"))
        XCTAssertTrue(statuses.contains("Done"))
    }

    func testLowConfidenceMergeCountsWhenNoTextAlignment() async throws {
        let responses = ResponseQueue(values: [
            .success(PretranscriptionASRResult(text: "alpha", detectedLanguage: "en", timingMS: [:])),
            .success(PretranscriptionASRResult(text: "beta", detectedLanguage: "en", timingMS: [:])),
            .success(PretranscriptionASRResult(text: "", detectedLanguage: "en", timingMS: [:])),
        ])
        let session = PretranscriptionSession(
            config: makeConfig(fallback: .off),
            sessionID: UUID(),
            chunkTranscriber: { _ in try await responses.next() },
            fullASRTranscriber: nil,
            runtimeUpdate: { _ in },
            logger: { _ in }
        )

        await appendSpeech(to: session, seconds: 2.2, chunkSamples: 8_000)
        let finalURL = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: finalURL) }
        let result = await session.finish(finalAudioURL: finalURL)

        XCTAssertGreaterThanOrEqual(result.lowConfidenceMerges, 1)
        XCTAssertTrue(result.transcript.contains("alpha"))
        XCTAssertTrue(result.transcript.contains("beta"))
    }

    func testFallbackRunsFullASRWhenChunkFailuresExceedThreshold() async throws {
        let responses = ResponseQueue(values: [
            .failure(TestError.simulatedFailure),
            .failure(TestError.simulatedFailure),
        ])
        let session = PretranscriptionSession(
            config: makeConfig(fallback: .fullASROnHighFailure),
            sessionID: UUID(),
            chunkTranscriber: { _ in try await responses.next() },
            fullASRTranscriber: { _ in
                PretranscriptionASRResult(
                    text: "fallback final transcript",
                    detectedLanguage: "en",
                    timingMS: ["asr": 1200]
                )
            },
            runtimeUpdate: { _ in },
            logger: { _ in }
        )

        await appendSpeech(to: session, seconds: 2.4, chunkSamples: 8_000)
        let finalURL = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: finalURL) }
        let result = await session.finish(finalAudioURL: finalURL)

        XCTAssertTrue(result.fallbackUsed)
        XCTAssertEqual(result.transcript, "fallback final transcript")
        XCTAssertGreaterThanOrEqual(result.failedChunks, 1)
    }

    private func makeConfig(fallback: PretranscribeFallbackPolicyOption) -> PretranscriptionConfig {
        PretranscriptionConfig(
            enabled: true,
            stepSeconds: 0.8,
            overlapSeconds: 0.2,
            maxChunkSeconds: 2.0,
            minSpeechSeconds: 0.1,
            endSilenceMS: 240,
            maxInFlight: 1,
            fallbackPolicy: fallback,
            failureRateThreshold: 0.35,
            backlogThresholdSeconds: 20.0
        )
    }

    private func appendSpeech(
        to session: PretranscriptionSession,
        seconds: Double,
        chunkSamples: Int
    ) async {
        let samples = speechSamples(seconds: seconds)
        var index = 0
        while index < samples.count {
            let nextIndex = min(samples.count, index + chunkSamples)
            await session.append(samples: Array(samples[index..<nextIndex]))
            index = nextIndex
        }
    }

    private func speechSamples(seconds: Double, amplitude: Int16 = 6_000) -> [Int16] {
        let count = max(1, Int(seconds * 16_000))
        return Array(repeating: amplitude, count: count)
    }

    private func makeDummyAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pretranscribe-test-\(UUID().uuidString).wav")
        try Data([0]).write(to: url)
        return url
    }
}

private actor ResponseQueue {
    private var values: [Result<PretranscriptionASRResult, Error>]
    private var fallbackValue: Result<PretranscriptionASRResult, Error>

    init(values: [Result<PretranscriptionASRResult, Error>]) {
        self.values = values
        self.fallbackValue = .success(PretranscriptionASRResult(text: "", detectedLanguage: nil, timingMS: [:]))
    }

    func next() throws -> PretranscriptionASRResult {
        let value = values.isEmpty ? fallbackValue : values.removeFirst()
        switch value {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}

private actor SnapshotRecorder {
    private var snapshots: [PretranscriptionRuntimeSnapshot] = []

    func append(_ snapshot: PretranscriptionRuntimeSnapshot) {
        snapshots.append(snapshot)
    }

    func statuses() -> [String] {
        snapshots.map(\.status)
    }
}
