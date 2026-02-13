import XCTest
@testable import GhostType

final class CloudResponseParsingTests: XCTestCase {
    private enum ParsingTestError: Error, Equatable {
        case invalidPayload(String)
    }

    func testParseJSONObjectPayloadReturnsDictionary() throws {
        let data = Data(#"{"text":"hello"}"#.utf8)

        let parsed = try parseJSONObjectPayload(data) { ParsingTestError.invalidPayload($0) }

        XCTAssertEqual(parsed["text"] as? String, "hello")
    }

    func testParseJSONObjectPayloadThrowsForNonObject() {
        let data = Data(#"["not-an-object"]"#.utf8)

        XCTAssertThrowsError(
            try parseJSONObjectPayload(data) { ParsingTestError.invalidPayload($0) }
        ) { error in
            guard case let ParsingTestError.invalidPayload(raw) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(raw, #"["not-an-object"]"#)
        }
    }

    func testExtractOpenAIChatTextPrefersMessageContentString() {
        let payload: [String: Any] = [
            "choices": [
                [
                    "message": [
                        "content": "  hello world  ",
                    ],
                ],
            ],
        ]

        XCTAssertEqual(extractOpenAIChatText(from: payload), "hello world")
    }

    func testExtractOpenAIChatTextSupportsContentArray() {
        let payload: [String: Any] = [
            "choices": [
                [
                    "message": [
                        "content": [
                            ["text": "Part A"],
                            ["content": "Part B"],
                        ],
                    ],
                ],
            ],
        ]

        XCTAssertEqual(extractOpenAIChatText(from: payload), "Part A Part B")
    }

    func testExtractOpenAIResponsesTextReadsOutputArray() {
        let payload: [String: Any] = [
            "output": [
                [
                    "content": [
                        ["text": "  "],
                        ["text": "response text"],
                    ],
                ],
            ],
        ]

        XCTAssertEqual(extractOpenAIResponsesText(from: payload), "response text")
    }

    func testExtractGeminiTextReadsCandidateParts() {
        let payload: [String: Any] = [
            "candidates": [
                [
                    "content": [
                        "parts": [
                            ["text": " Gemini output "],
                        ],
                    ],
                ],
            ],
        ]

        XCTAssertEqual(extractGeminiText(from: payload), "Gemini output")
    }
}
