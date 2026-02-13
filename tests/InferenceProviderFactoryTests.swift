import XCTest
@testable import GhostType

@MainActor
final class InferenceProviderFactoryTests: XCTestCase {
    func testProviderKindMatrixCoversAllEngineCombinations() throws {
        let state = AppState.shared
        let originalASR = state.asrEngine
        let originalLLM = state.llmEngine
        defer {
            state.asrEngine = originalASR
            state.llmEngine = originalLLM
        }

        state.asrEngine = .localMLX
        state.llmEngine = .localMLX
        assertProviderKind(try InferenceProviderFactory.providerKind(for: state), is: .local)

        state.asrEngine = .localMLX
        state.llmEngine = .openAI
        assertProviderKind(try InferenceProviderFactory.providerKind(for: state), is: .hybrid)

        state.asrEngine = .openAIWhisper
        state.llmEngine = .localMLX
        assertProviderKind(try InferenceProviderFactory.providerKind(for: state), is: .hybrid)

        state.asrEngine = .openAIWhisper
        state.llmEngine = .openAI
        assertProviderKind(try InferenceProviderFactory.providerKind(for: state), is: .cloud)
    }

    private func assertProviderKind(
        _ actual: InferenceProviderKind,
        is expected: InferenceProviderKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (actual, expected) {
        case (.local, .local), (.hybrid, .hybrid), (.cloud, .cloud):
            return
        default:
            XCTFail("Expected \(expected), got \(actual).", file: file, line: line)
        }
    }
}
