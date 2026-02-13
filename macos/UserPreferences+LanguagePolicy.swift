import Foundation

extension UserPreferences {
    func outputLanguageDirective(
        asrDetectedLanguage: String?,
        transcriptText: String
    ) -> OutputLanguageDirective {
        if let forcedCode = outputLanguage.forcedLanguageTag {
            return OutputLanguageDirective(
                resolvedCode: forcedCode,
                policyLabel: "\(forcedCode) (forced)",
                promptInstruction: """
                Output language policy (highest priority):
                - This policy overrides any conflicting language instruction above.
                - The final output MUST be \(outputLanguage.promptLanguageName) (\(forcedCode)).
                - Minor mixed-language fragments MAY remain only when translation is unnecessary or harmful (for example: proper nouns, brand names, code, commands, URLs, file paths, quotes, or standard technical terms).
                """
            )
        }

        let normalizedDetected = Self.normalizedLanguageTag(asrDetectedLanguage)
            ?? Self.inferLanguageTag(from: transcriptText)
        if let normalizedDetected {
            return OutputLanguageDirective(
                resolvedCode: normalizedDetected,
                policyLabel: "auto->\(normalizedDetected)",
                promptInstruction: """
                Output language policy (highest priority):
                - Follow the ASR language for this turn. Detected language: \(normalizedDetected).
                - Minor mixed-language fragments MAY remain only when translation is unnecessary or harmful (for example: proper nouns, brand names, code, commands, URLs, file paths, quotes, or standard technical terms).
                """
            )
        }
        return OutputLanguageDirective(
            resolvedCode: "auto",
            policyLabel: "auto->undetermined",
            promptInstruction: """
            Output language policy (highest priority):
            - Follow the same language as the transcript content in this turn.
            - Minor mixed-language fragments MAY remain only when translation is unnecessary or harmful (for example: proper nouns, brand names, code, commands, URLs, file paths, quotes, or standard technical terms).
            """
        )
    }

    private static func normalizedLanguageTag(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return nil }
        if cleaned.hasPrefix("zh") {
            return "zh-Hans"
        }
        if cleaned.hasPrefix("en") {
            return "en"
        }
        return cleaned
    }

    private static func inferLanguageTag(from text: String) -> String? {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return nil }

        var cjkCount = 0
        var latinCount = 0
        for scalar in scalars {
            let value = scalar.value
            if (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) {
                cjkCount += 1
            } else if CharacterSet.letters.contains(scalar), value < 0x024F {
                latinCount += 1
            }
        }

        if cjkCount >= 3, cjkCount >= latinCount {
            return "zh-Hans"
        }
        if latinCount >= 3 {
            return "en"
        }
        return nil
    }
}
