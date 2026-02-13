import XCTest
@testable import GhostType

@MainActor
final class InferenceTextPostProcessorTests: XCTestCase {
    private final class SpyDeduper: TextDeduping {
        private(set) var received: [String] = []
        private let transform: (String) -> String

        init(transform: @escaping (String) -> String) {
            self.transform = transform
        }

        func dedupe(_ text: String) -> String {
            received.append(text)
            return transform(text)
        }
    }

    override func tearDown() {
        AppLogger.shared.clear()
        super.tearDown()
    }

    func testDedupeUsesInjectedDeduperWhenEnabled() {
        let deduper = SpyDeduper { _ in "deduped" }
        let processor = InferenceTextPostProcessor(
            logger: .shared,
            deduper: deduper,
            shouldDedupe: { true },
            isIMNaturalChatPreset: { _ in false }
        )

        let output = processor.dedupe("raw text", stage: "LLM", sessionID: UUID())

        XCTAssertEqual(output, "deduped")
        XCTAssertEqual(deduper.received, ["raw text"])
    }

    func testDedupeSkipsInjectedDeduperWhenDisabled() {
        let deduper = SpyDeduper { _ in "deduped" }
        let processor = InferenceTextPostProcessor(
            logger: .shared,
            deduper: deduper,
            shouldDedupe: { false },
            isIMNaturalChatPreset: { _ in false }
        )

        let output = processor.dedupe("raw text", stage: "LLM", sessionID: UUID())

        XCTAssertEqual(output, "raw text")
        XCTAssertTrue(deduper.received.isEmpty)
    }

    func testProcessForIMPresetNormalizesBulletsAndParagraphs() {
        let processor = InferenceTextPostProcessor(
            logger: .shared,
            deduper: SpyDeduper(transform: { $0 }),
            shouldDedupe: { true },
            isIMNaturalChatPreset: { $0 == "im-preset" }
        )

        let request = makeRequest(mode: .dictate, presetID: "im-preset")
        let raw = "- 你好\n- 世界\n\n\n下一行   \n 继续"

        let output = processor.process(raw, request: request, sessionID: UUID())

        XCTAssertEqual(output, "你好 世界\n\n下一行 继续")
    }

    func testProcessDoesNotApplyIMFormattingOutsideIMPreset() {
        let processor = InferenceTextPostProcessor(
            logger: .shared,
            deduper: SpyDeduper(transform: { $0 }),
            shouldDedupe: { true },
            isIMNaturalChatPreset: { $0 == "im-preset" }
        )

        let request = makeRequest(mode: .dictate, presetID: "other-preset")
        let raw = "- 你好\n- 世界"

        let output = processor.process(raw, request: request, sessionID: UUID())

        XCTAssertEqual(output, raw)
    }

    func testProcessDoesNotApplyIMFormattingForNonDictateMode() {
        let processor = InferenceTextPostProcessor(
            logger: .shared,
            deduper: SpyDeduper(transform: { $0 }),
            shouldDedupe: { true },
            isIMNaturalChatPreset: { $0 == "im-preset" }
        )

        let request = makeRequest(mode: .ask, presetID: "im-preset")
        let raw = "- 你好\n- 世界"

        let output = processor.process(raw, request: request, sessionID: UUID())

        XCTAssertEqual(output, raw)
    }

    private func makeRequest(mode: WorkflowMode, presetID: String) -> InferenceRequest {
        InferenceRequest(
            state: .shared,
            mode: mode,
            audioURL: URL(fileURLWithPath: "/tmp/dummy.wav"),
            selectedText: "",
            dictationContext: DictationContextSelection(
                snapshot: ContextSnapshot(
                    timestamp: Date(),
                    frontmostAppBundleId: "com.example.test",
                    frontmostAppName: "Test",
                    browserType: nil,
                    activeDomain: nil,
                    activeUrl: nil,
                    windowTitle: nil,
                    confidence: .low,
                    source: .appOnly
                ),
                preset: DictationResolvedPreset(
                    id: presetID,
                    title: "Preset",
                    dictationPrompt: "Prompt"
                ),
                matchedRule: nil
            )
        )
    }
}
