import XCTest
@testable import GhostType

@MainActor
final class EngineConfigTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for suiteName in suiteNames {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    func testDefaultValues() {
        let defaults = makeDefaults()
        let config = EngineConfig(defaults: defaults)

        XCTAssertEqual(config.asrEngine, .localMLX)
        XCTAssertEqual(config.llmEngine, .localMLX)
        XCTAssertEqual(config.localASRProvider, .mlxWhisper)
        XCTAssertEqual(config.selectedLocalASRModelID, LocalASRModelCatalog.defaultModelID)
        XCTAssertEqual(config.asrModel, LocalASRModelCatalog.defaultModelID)
        XCTAssertEqual(config.localHTTPASRBaseURL, LocalASRModelCatalog.defaultLocalHTTPBaseURL)
        XCTAssertEqual(config.localHTTPASRModelName, LocalASRModelCatalog.defaultLocalHTTPModelName)
        XCTAssertEqual(config.llmModel, "mlx-community/gemma-3-270m-it-4bit")
        XCTAssertEqual(config.deepgram.transcriptionMode, .batch)
        XCTAssertEqual(config.deepgram.region, .standard)
        XCTAssertTrue(config.deepgram.smartFormat)
        XCTAssertTrue(config.deepgram.punctuate)
        XCTAssertTrue(config.shouldUseLocalProvider)
        XCTAssertEqual(config.llmTemperature, 0.4, accuracy: 0.001)
        XCTAssertEqual(config.llmTopP, 0.95, accuracy: 0.001)
        XCTAssertEqual(config.llmMaxTokens, 4096)
    }

    func testASREngineRoundTrip() {
        let defaults = makeDefaults()
        let config = EngineConfig(defaults: defaults)

        config.asrEngine = .deepgram
        config.cloudASRBaseURL = "https://api.eu.deepgram.com"
        config.cloudASRModelName = "nova-3"
        config.cloudASRLanguage = "en-US"
        config.deepgram.transcriptionMode = .streaming
        config.deepgram.interimResults = false
        config.llmEngine = .openAI
        config.cloudLLMBaseURL = "https://api.openai.com/v1"
        config.cloudLLMModelName = "gpt-4o-mini"
        config.privacyModeEnabled = false

        let reloaded = EngineConfig(defaults: defaults)
        XCTAssertEqual(reloaded.asrEngine, .deepgram)
        XCTAssertEqual(reloaded.cloudASRBaseURL, "https://api.eu.deepgram.com")
        XCTAssertEqual(reloaded.cloudASRModelName, "nova-3")
        XCTAssertEqual(reloaded.cloudASRLanguage, "en-US")
        XCTAssertEqual(reloaded.deepgram.transcriptionMode, .streaming)
        XCTAssertFalse(reloaded.deepgram.interimResults)
        XCTAssertEqual(reloaded.llmEngine, .openAI)
        XCTAssertEqual(reloaded.cloudLLMBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(reloaded.cloudLLMModelName, "gpt-4o-mini")
        XCTAssertFalse(reloaded.privacyModeEnabled)
    }

    func testDeepgramEndpointingClampsToSupportedRange() {
        let defaults = makeDefaults()
        let config = EngineConfig(defaults: defaults)

        config.deepgram.endpointingMS = 1
        XCTAssertEqual(config.deepgram.endpointingMS, 10)

        config.deepgram.endpointingMS = 99_999
        XCTAssertEqual(config.deepgram.endpointingMS, 10_000)
    }

    func testDeepgramBatchQueryConfigStripsStreamingOnlyFlags() {
        let defaults = makeDefaults()
        let config = EngineConfig(defaults: defaults)

        config.asrEngine = .deepgram
        config.deepgram.transcriptionMode = .batch
        config.deepgram.endpointingEnabled = true
        config.deepgram.endpointingMS = 500
        config.deepgram.interimResults = true

        let query = config.deepgramQueryConfig
        XCTAssertEqual(query.mode, .batch)
        XCTAssertNil(query.endpointingMS)
        XCTAssertFalse(query.interimResults)
    }

    func testDeepgramStreamingQueryConfigPreservesStreamingFlags() {
        let defaults = makeDefaults()
        let config = EngineConfig(defaults: defaults)

        config.asrEngine = .deepgram
        config.deepgram.transcriptionMode = .streaming
        config.deepgram.endpointingEnabled = true
        config.deepgram.endpointingMS = 750
        config.deepgram.interimResults = true

        let query = config.deepgramQueryConfig
        XCTAssertEqual(query.mode, .streaming)
        XCTAssertEqual(query.endpointingMS, 750)
        XCTAssertTrue(query.interimResults)
    }

    func testLLMParametersRoundTrip() {
        let defaults = makeDefaults()
        let config = EngineConfig(defaults: defaults)

        config.llmTemperature = 1.2
        config.llmTopP = 0.8
        config.llmMaxTokens = 8192

        let reloaded = EngineConfig(defaults: defaults)
        XCTAssertEqual(reloaded.llmTemperature, 1.2, accuracy: 0.001)
        XCTAssertEqual(reloaded.llmTopP, 0.8, accuracy: 0.001)
        XCTAssertEqual(reloaded.llmMaxTokens, 8192)
    }

    func testLLMTemperatureClamping() {
        let defaults = makeDefaults()
        let config = EngineConfig(defaults: defaults)

        config.llmTemperature = -0.5
        XCTAssertEqual(config.llmTemperature, 0.0, accuracy: 0.001)

        config.llmTemperature = 3.0
        XCTAssertEqual(config.llmTemperature, 2.0, accuracy: 0.001)
    }

    func testLLMTopPClamping() {
        let defaults = makeDefaults()
        let config = EngineConfig(defaults: defaults)

        config.llmTopP = -0.1
        XCTAssertEqual(config.llmTopP, 0.0, accuracy: 0.001)

        config.llmTopP = 1.5
        XCTAssertEqual(config.llmTopP, 1.0, accuracy: 0.001)
    }

    func testLLMMaxTokensClamping() {
        let defaults = makeDefaults()
        let config = EngineConfig(defaults: defaults)

        config.llmMaxTokens = 0
        XCTAssertEqual(config.llmMaxTokens, 1)

        config.llmMaxTokens = 99999
        XCTAssertEqual(config.llmMaxTokens, 32768)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "EngineConfigTests.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create UserDefaults suite: \(suiteName)")
            return .standard
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
