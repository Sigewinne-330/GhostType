import Foundation

// MARK: - LLM Stream Parsing
// Responsibility: Parse streaming token payloads from OpenAI-compatible, Anthropic, and Gemini responses.
// Public entry point: parseToken(parserKind:payloadLine:emittedText:).
extension CloudInferenceProvider {
    func parseToken(
        parserKind: LLMTokenParserKind,
        payloadLine: String,
        emittedText: inout String
    ) -> String? {
        switch parserKind {
        case .openAIChat:
            return parseOpenAICompatibleToken(payloadLine)
        case .openAIResponses:
            return parseOpenAIResponsesToken(payloadLine, emittedText: &emittedText)
        case .anthropic:
            return parseAnthropicToken(payloadLine)
        case .gemini:
            return parseGeminiToken(payloadLine, emittedText: &emittedText)
        }
    }


    private func parseOpenAICompatibleToken(_ payloadLine: String) -> String? {
        guard let data = payloadLine.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else { return nil }
        guard let delta = first["delta"] as? [String: Any] else { return nil }

        if let content = delta["content"] as? String {
            return content
        }
        if let rich = delta["content"] as? [[String: Any]] {
            let text = rich.compactMap { chunk -> String? in
                if let direct = chunk["text"] as? String {
                    return direct
                }
                if let inner = chunk["text"] as? [String: Any] {
                    return inner["value"] as? String
                }
                return nil
            }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }


    private func parseOpenAIResponsesToken(_ payloadLine: String, emittedText: inout String) -> String? {
        guard let data = payloadLine.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let type = object["type"] as? String else { return nil }

        if type == "response.output_text.delta" || type == "response.refusal.delta" {
            let delta = object["delta"] as? String ?? ""
            guard !delta.isEmpty else { return nil }
            emittedText += delta
            return delta
        }

        if type == "response.output_text.done", let fullText = object["text"] as? String {
            let delta = deltaText(from: fullText, emittedText: &emittedText)
            return delta.isEmpty ? nil : delta
        }

        return nil
    }


    private func parseAnthropicToken(_ payloadLine: String) -> String? {
        guard let data = payloadLine.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let type = object["type"] as? String else { return nil }

        if type == "content_block_delta",
           let delta = object["delta"] as? [String: Any],
           let text = delta["text"] as? String {
            return text
        }

        if type == "content_block_start",
           let block = object["content_block"] as? [String: Any],
           let text = block["text"] as? String {
            return text
        }

        return nil
    }


    private func parseGeminiToken(_ payloadLine: String, emittedText: inout String) -> String? {
        guard let data = payloadLine.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        guard
            let candidates = object["candidates"] as? [[String: Any]],
            let firstCandidate = candidates.first,
            let content = firstCandidate["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else {
            return nil
        }

        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { return nil }

        let delta = deltaText(from: text, emittedText: &emittedText)
        return delta.isEmpty ? nil : delta
    }


    private func deltaText(from incoming: String, emittedText: inout String) -> String {
        guard !incoming.isEmpty else { return "" }
        if incoming.hasPrefix(emittedText) {
            let index = incoming.index(incoming.startIndex, offsetBy: emittedText.count)
            let delta = String(incoming[index...])
            emittedText = incoming
            return delta
        }

        emittedText += incoming
        return incoming
    }


    func sseDataPayload(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        return payload.isEmpty ? nil : payload
    }
}
