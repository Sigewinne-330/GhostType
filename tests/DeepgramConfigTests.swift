import XCTest
@testable import GhostType

final class DeepgramConfigTests: XCTestCase {
    func testRecommendedModelByLanguage() {
        XCTAssertEqual(
            DeepgramConfig.recommendedModel(for: DeepgramLanguageStrategy.chineseSimplified.rawValue),
            "nova-2"
        )
        XCTAssertEqual(
            DeepgramConfig.recommendedModel(for: DeepgramLanguageStrategy.englishUS.rawValue),
            "nova-3"
        )
        XCTAssertEqual(
            DeepgramConfig.recommendedModel(for: DeepgramLanguageStrategy.multi.rawValue),
            "nova-3"
        )
    }

    func testEndpointURLSupportsHostOnlyAndStreamingScheme() {
        let batchURL = DeepgramConfig.endpointURL(
            baseURLRaw: "api.deepgram.com",
            mode: .batch,
            fallbackRegion: .standard
        )
        XCTAssertEqual(batchURL?.absoluteString, "https://api.deepgram.com/v1/listen")

        let normalizedV1URL = DeepgramConfig.endpointURL(
            baseURLRaw: "https://api.deepgram.com/v1",
            mode: .batch,
            fallbackRegion: .standard
        )
        XCTAssertEqual(normalizedV1URL?.absoluteString, "https://api.deepgram.com/v1/listen")

        let streamingURL = DeepgramConfig.endpointURL(
            baseURLRaw: "api.eu.deepgram.com",
            mode: .streaming,
            fallbackRegion: .standard
        )
        XCTAssertEqual(streamingURL?.absoluteString, "wss://api.eu.deepgram.com/v1/listen")
    }

    func testEndpointURLDropsLegacyQueryParameters() {
        let url = DeepgramConfig.endpointURL(
            baseURLRaw: "https://api.deepgram.com/v1/listen?endpointing=500&foo=bar#frag",
            mode: .batch,
            fallbackRegion: .standard
        )
        XCTAssertEqual(url?.absoluteString, "https://api.deepgram.com/v1/listen")
    }

    func testQueryItemsRespectSmartFormatAndStreamingFlags() {
        let config = DeepgramQueryConfig(
            modelName: "nova-3",
            language: DeepgramLanguageStrategy.englishUS.rawValue,
            endpointingMS: 500,
            interimResults: true,
            smartFormat: true,
            punctuate: false,
            paragraphs: true,
            diarize: true,
            terminologyRawValue: "GhostType, Dictation",
            mode: .streaming
        )

        let map = dictionary(from: DeepgramConfig.buildQueryItems(config: config))
        XCTAssertEqual(map["model"], ["nova-3"])
        XCTAssertEqual(map["language"], ["en-US"])
        XCTAssertEqual(map["smart_format"], ["true"])
        XCTAssertNil(map["punctuate"])
        XCTAssertEqual(map["paragraphs"], ["true"])
        XCTAssertEqual(map["interim_results"], ["true"])
        XCTAssertEqual(map["endpointing"], ["500"])
        XCTAssertEqual(map["diarize"], ["true"])
        XCTAssertEqual(map["keyterm"], ["GhostType", "Dictation"])
        XCTAssertNil(map["keywords"])
    }

    func testQueryItemsUseKeywordsForNova2() {
        let config = DeepgramQueryConfig(
            modelName: "nova-2",
            language: DeepgramLanguageStrategy.chineseSimplified.rawValue,
            endpointingMS: 500,
            interimResults: false,
            smartFormat: false,
            punctuate: true,
            paragraphs: false,
            diarize: false,
            terminologyRawValue: "GhostType:2,MLX",
            mode: .batch
        )

        let map = dictionary(from: DeepgramConfig.buildQueryItems(config: config))
        XCTAssertEqual(map["smart_format"], ["false"])
        XCTAssertEqual(map["punctuate"], ["true"])
        XCTAssertNil(map["endpointing"])
        XCTAssertEqual(map["keywords"], ["GhostType:2", "MLX"])
        XCTAssertNil(map["keyterm"])
    }

    private func dictionary(from items: [URLQueryItem]) -> [String: [String]] {
        var output: [String: [String]] = [:]
        for item in items {
            output[item.name, default: []].append(item.value ?? "")
        }
        return output
    }
}
