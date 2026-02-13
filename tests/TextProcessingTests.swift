import XCTest
@testable import GhostType

final class TextProcessingTests: XCTestCase {
    func testTextDeduperRemovesConsecutiveDuplicateSentence() {
        let input = "今天开会讨论方案。今天开会讨论方案。然后继续推进。"
        let output = TextDeduper.dedupe(input)
        XCTAssertEqual(output, "今天开会讨论方案。然后继续推进。")
    }

    func testTextDeduperRemovesRepeatedTailBlock() {
        let input = "Please update the roadmap. Please update the roadmap."
        let output = TextDeduper.dedupe(input)
        XCTAssertEqual(output, "Please update the roadmap.")
    }

    func testTextDeduperRemovesRepeatedTailBlockSequence() {
        let input = "Step one. Step two. Step three. Step two. Step three."
        let output = TextDeduper.dedupe(input)
        XCTAssertEqual(output, "Step one. Step two. Step three.")
    }

    func testStreamTextAccumulatorHandlesDeltaTokens() {
        var accumulator = StreamTextAccumulator()
        XCTAssertEqual(accumulator.ingest("Hello"), .append("Hello"))
        XCTAssertEqual(accumulator.ingest(" world"), .append(" world"))
        XCTAssertEqual(accumulator.text, "Hello world")
    }

    func testStreamTextAccumulatorHandlesAccumulatedSnapshots() {
        var accumulator = StreamTextAccumulator()
        XCTAssertEqual(accumulator.ingest("Hello"), .append("Hello"))
        XCTAssertEqual(accumulator.ingest("Hello world"), .replace("Hello world"))
        XCTAssertEqual(accumulator.ingest("Hello world"), .ignore)
        XCTAssertEqual(accumulator.text, "Hello world")
    }
}
