import Foundation

// MARK: - LLM Prompting
// Responsibility: Build mode-specific system/user prompts and inject output-language directives.
// Public entry point: buildPrompt(request:rawText:asrDetectedLanguage:state:).
extension CloudInferenceProvider {
    func buildPrompt(
        request: InferenceRequest,
        rawText: String,
        asrDetectedLanguage: String?,
        state: AppState
    ) -> (system: String, user: String, outputLanguagePolicy: String) {
        switch request.mode {
        case .dictate:
            let languageDirective = state.outputLanguageDirective(
                asrDetectedLanguage: asrDetectedLanguage,
                transcriptText: rawText
            )
            var system = state.resolvedDictateSystemPrompt(
                lockedDictationPrompt: request.dictationContext?.preset.dictationPrompt
            )
            system += "\n\n\(languageDirective.promptInstruction)"
            system = appendPersonalizationRules(system, state: state)
            let user = "Rewrite the following ASR transcript into clean written text while preserving all substantive details:\n\n\(rawText)"
            return (system, user, languageDirective.policyLabel)
        case .ask:
            let languageDirective = state.outputLanguageDirective(
                asrDetectedLanguage: asrDetectedLanguage,
                transcriptText: rawText
            )
            var system = state.resolvedAskSystemPrompt()
            system += "\n\n\(languageDirective.promptInstruction)"
            system = appendPersonalizationRules(system, state: state)
            let user = "Reference Text:\n\(request.selectedText)\n\nVoice Question:\n\(rawText)"
            return (system, user, languageDirective.policyLabel)
        case .translate:
            let targetLanguage = state.targetLanguage.rawValue
            var system = state.resolvedTranslateSystemPrompt(targetLanguage: targetLanguage)
            system = appendPersonalizationRules(system, state: state)
            let user = "Text to translate:\n\(rawText)"
            return (system, user, "translate.\(targetLanguage)")
        }
    }


    private func appendPersonalizationRules(_ systemPrompt: String, state: AppState) -> String {
        var prompt = systemPrompt

        let dictionaryItems = loadDictionaryItems(from: state.dictionaryFileURL)
        if !dictionaryItems.isEmpty {
            let payloadData = try? JSONSerialization.data(withJSONObject: ["items": dictionaryItems])
            let payload = payloadData.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"items\":[]}"
            prompt += "\n\nAdditional rule: strictly apply the following proper-noun mapping dictionary while processing text: \(payload)"
        }

        let styleProfileText = loadStyleProfileRules(from: state.styleProfileFileURL)
        if !styleProfileText.isEmpty {
            prompt += "\n\nAdditional rule: follow these abstract writing-style traits when generating the final text: \(styleProfileText)"
        }

        return prompt
    }


    private func loadDictionaryItems(from fileURL: URL) -> [[String: String]] {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }

        if let items = object["items"] as? [[String: Any]] {
            return items.compactMap { item in
                let original = String(describing: item["originalText"] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let corrected = String(describing: item["correctedText"] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !original.isEmpty, !corrected.isEmpty else { return nil }
                return [
                    "originalText": original,
                    "correctedText": corrected,
                ]
            }
        }

        if let terms = object["terms"] as? [Any] {
            return terms.compactMap { value in
                let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return [
                    "originalText": text,
                    "correctedText": text,
                ]
            }
        }

        return []
    }


    private func loadStyleProfileRules(from fileURL: URL) -> String {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rules = object["rules"] as? [Any]
        else {
            return ""
        }

        let cleaned = rules.compactMap { value -> String? in
            let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return cleaned.joined(separator: "；")
    }
}
