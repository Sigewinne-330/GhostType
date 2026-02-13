import XCTest
@testable import GhostType

@MainActor
final class DeepgramParsingTests: XCTestCase {
    func testDeepgramPrefersTranscriptOverWordsFallback() {
        let payload: [String: Any] = [
            "results": [
                "channels": [
                    [
                        "alternatives": [
                            [
                                "transcript": "今天我们讨论发布计划。",
                                "words": [
                                    ["word": "今天"],
                                    ["word": "我们"],
                                    ["word": "讨论"],
                                    ["word": "发布"],
                                    ["word": "计划"],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let provider = CloudInferenceProvider()
        let text = provider.extractDeepgramTranscriptionText(from: payload)
        XCTAssertEqual(text, "今天我们讨论发布计划。")
    }

    func testDeepgramWordsFallbackCompactsCJKCharacterSpacing() {
        let payload: [String: Any] = [
            "results": [
                "channels": [
                    [
                        "alternatives": [
                            [
                                "words": [
                                    ["word": "今"],
                                    ["word": "天"],
                                    ["word": "开"],
                                    ["word": "会"],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let provider = CloudInferenceProvider()
        let text = provider.extractDeepgramTranscriptionText(from: payload)
        XCTAssertEqual(text, "今天开会")
    }

    func testDeepgramWordsFallbackKeepsEnglishWordBoundaries() {
        let payload: [String: Any] = [
            "results": [
                "channels": [
                    [
                        "alternatives": [
                            [
                                "words": [
                                    ["word": "hello"],
                                    ["word": "world"],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let provider = CloudInferenceProvider()
        let text = provider.extractDeepgramTranscriptionText(from: payload)
        XCTAssertEqual(text, "hello world")
    }
}
