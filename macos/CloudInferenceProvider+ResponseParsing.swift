import Foundation

// MARK: - Shared Response Parsing
// Responsibility: Shared JSON/text extraction helpers used by CloudInferenceProvider runtime and EngineProbeClient.

func parseJSONObjectPayload(
    _ data: Data,
    invalidPayload: (String) -> Error
) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        let raw = String(data: data, encoding: .utf8) ?? ""
        throw invalidPayload(raw)
    }
    return object
}

func extractDeepgramTranscript(from object: [String: Any]) -> String {
    let results = object["results"] as? [String: Any] ?? object
    let channels = results["channels"] as? [[String: Any]] ?? []
    for channel in channels {
        let alternatives = channel["alternatives"] as? [[String: Any]] ?? []
        for alternative in alternatives {
            if let transcript = alternative["transcript"] as? String {
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
    }

    if let transcript = object["transcript"] as? String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
    }

    return ""
}

func extractOpenAIChatText(from object: [String: Any]) -> String {
    let choices = object["choices"] as? [[String: Any]] ?? []
    guard let first = choices.first else { return "" }

    if let message = first["message"] as? [String: Any] {
        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let contentArray = message["content"] as? [[String: Any]] {
            let parts = contentArray.compactMap { item -> String? in
                if let text = item["text"] as? String { return text }
                if let value = item["content"] as? String { return value }
                return nil
            }
            return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    if let text = first["text"] as? String {
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return ""
}

func extractOpenAIResponsesText(from object: [String: Any]) -> String {
    if let output = object["output"] as? [[String: Any]] {
        for entry in output {
            let content = entry["content"] as? [[String: Any]] ?? []
            for item in content {
                if let text = item["text"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }
    return ""
}

func extractGeminiText(from object: [String: Any]) -> String {
    let candidates = object["candidates"] as? [[String: Any]] ?? []
    guard let first = candidates.first else { return "" }

    let content = first["content"] as? [String: Any]
    let parts = content?["parts"] as? [[String: Any]] ?? []
    for part in parts {
        if let text = part["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
    }

    return ""
}
