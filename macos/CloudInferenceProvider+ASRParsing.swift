import Foundation

// MARK: - ASR Parsing
// Responsibility: Parse provider-specific ASR payloads into normalized transcript text.
// Public entry points: extractGeminiTranscriptionText, extractOpenAITranscriptionText, extractDeepgramTranscriptionText.
extension CloudInferenceProvider {
    func extractGeminiTranscriptionText(from payload: [String: Any]) -> String {
        if let candidates = payload["candidates"] as? [[String: Any]] {
            let text = candidates
                .flatMap { candidate -> [String] in
                    guard
                        let content = candidate["content"] as? [String: Any],
                        let parts = content["parts"] as? [[String: Any]]
                    else {
                        return []
                    }
                    return parts.compactMap { part in
                        normalizedString(part["text"]) ?? normalizedString((part["text"] as? [String: Any])?["value"])
                    }
                }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }

        return extractTranscriptionText(from: payload)
    }
    func extractTranscriptionText(from payload: [String: Any]) -> String {
        if let direct = normalizedString(payload["text"])
            ?? normalizedString(payload["transcript"])
            ?? normalizedString(payload["transcription"])
            ?? normalizedString(payload["output_text"]) {
            return direct
        }

        if let segments = payload["segments"] as? [[String: Any]] {
            let segmentText = joinedTranscriptionText(from: segments)
            if !segmentText.isEmpty {
                return segmentText
            }
        }

        if let outputItems = payload["output"] as? [[String: Any]] {
            let outputText = outputItems
                .flatMap { item -> [String] in
                    if let nested = item["content"] as? [[String: Any]] {
                        return nested.compactMap { content in
                            normalizedString(content["text"])
                                ?? normalizedString((content["text"] as? [String: Any])?["value"])
                                ?? normalizedString(content["transcript"])
                        }
                    }
                    return []
                }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !outputText.isEmpty {
                return outputText
            }
        }

        let deepgramTranscript = extractDeepgramTranscriptionText(from: payload)
        if !deepgramTranscript.isEmpty {
            return deepgramTranscript
        }

        for wrapperKey in ["data", "result", "response", "payload"] {
            if let nested = payload[wrapperKey] as? [String: Any] {
                let nestedText = extractTranscriptionText(from: nested)
                if !nestedText.isEmpty {
                    return nestedText
                }
            }
        }

        return ""
    }


    func extractDeepgramTranscriptionText(from payload: [String: Any]) -> String {
        let deepgramResult = payload["results"] as? [String: Any] ?? payload
        // Prefer one high-quality transcript source. Only fall back to words if all richer fields are empty.
        let utterancePreferred = normalizedDeepgramJoinedText(
            from: deepgramUtteranceChunks(from: deepgramResult, includeWordsFallback: false)
        )
        if !utterancePreferred.isEmpty {
            return utterancePreferred
        }

        let channelPreferred = normalizedDeepgramJoinedText(
            from: deepgramChannelChunks(from: deepgramResult, includeWordsFallback: false)
        )
        if !channelPreferred.isEmpty {
            return channelPreferred
        }

        let utteranceWordsFallback = normalizedDeepgramJoinedText(
            from: deepgramUtteranceChunks(from: deepgramResult, includeWordsFallback: true)
        )
        if !utteranceWordsFallback.isEmpty {
            return utteranceWordsFallback
        }

        return normalizedDeepgramJoinedText(
            from: deepgramChannelChunks(from: deepgramResult, includeWordsFallback: true)
        )
    }

    func extractDetectedLanguageTag(from payload: [String: Any]) -> String? {
        if let direct = normalizedString(payload["language_detected"])
            ?? normalizedString(payload["language"])
            ?? normalizedString(payload["language_code"]) {
            return normalizeLanguageTag(direct)
        }

        if let results = payload["results"] as? [String: Any],
           let channels = results["channels"] as? [[String: Any]],
           let firstChannel = channels.first {
            if let channelLang = normalizedString(firstChannel["detected_language"]) {
                return normalizeLanguageTag(channelLang)
            }
            if let alternatives = firstChannel["alternatives"] as? [[String: Any]],
               let firstAlt = alternatives.first,
               let altLang = normalizedString(firstAlt["detected_language"])
                ?? normalizedString(firstAlt["language"])
                ?? normalizedString(firstAlt["language_code"]) {
                return normalizeLanguageTag(altLang)
            }
        }

        if let candidates = payload["candidates"] as? [[String: Any]],
           let first = candidates.first,
           let metadata = first["metadata"] as? [String: Any],
           let metadataLang = normalizedString(metadata["language"]) {
            return normalizeLanguageTag(metadataLang)
        }

        for wrapperKey in ["results", "data", "result", "response", "payload"] {
            if let nested = payload[wrapperKey] as? [String: Any],
               let nestedLang = extractDetectedLanguageTag(from: nested) {
                return nestedLang
            }
        }

        return nil
    }

    func inferLanguageTag(from text: String) -> String? {
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


    private func joinedTranscriptionText(from array: [[String: Any]]) -> String {
        array.compactMap { item in
            normalizedString(item["text"])
                ?? normalizedString(item["transcript"])
                ?? normalizedString(item["transcription"])
        }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }


    private func joinedDeepgramSentenceText(from sentences: [[String: Any]]?) -> String {
        guard let sentences else { return "" }
        return sentences
            .compactMap { sentence in
                normalizedString(sentence["text"])
                    ?? normalizedString(sentence["transcript"])
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }


    private func joinedDeepgramWordsText(from words: [[String: Any]]?) -> String {
        guard let words else { return "" }
        let tokens = words
            .compactMap { word in
                normalizedString(word["punctuated_word"])
                    ?? normalizedString(word["word"])
                    ?? normalizedString(word["text"])
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return "" }
        return smartJoinDeepgramWordTokens(tokens)
    }


    private func deepgramUtteranceChunks(
        from deepgramResult: [String: Any],
        includeWordsFallback: Bool
    ) -> [String] {
        guard let utterances = deepgramResult["utterances"] as? [[String: Any]] else {
            return []
        }
        return utterances.compactMap { utterance in
            preferredDeepgramChunk(from: utterance, includeWordsFallback: includeWordsFallback)
        }
    }


    private func deepgramChannelChunks(
        from deepgramResult: [String: Any],
        includeWordsFallback: Bool
    ) -> [String] {
        guard let channels = deepgramResult["channels"] as? [[String: Any]] else {
            return []
        }

        return channels.compactMap { channel in
            let alternatives = channel["alternatives"] as? [[String: Any]] ?? []
            for alternative in alternatives {
                let preferred = preferredDeepgramChunk(
                    from: alternative,
                    includeWordsFallback: includeWordsFallback
                )
                if !preferred.isEmpty {
                    return preferred
                }
            }
            return nil
        }
    }


    private func preferredDeepgramChunk(
        from source: [String: Any],
        includeWordsFallback: Bool
    ) -> String {
        if let direct = normalizedString(source["transcript"]) ?? normalizedString(source["text"]) {
            return direct
        }

        if let paragraphs = source["paragraphs"] as? [String: Any] {
            if let paragraphTranscript = normalizedString(paragraphs["transcript"]) {
                return paragraphTranscript
            }

            if let paragraphItems = paragraphs["paragraphs"] as? [[String: Any]] {
                let paragraphText = normalizedDeepgramJoinedText(
                    from: paragraphItems.compactMap { paragraph in
                        normalizedString(paragraph["text"])
                            ?? joinedDeepgramSentenceText(from: paragraph["sentences"] as? [[String: Any]])
                    }
                )
                if !paragraphText.isEmpty {
                    return paragraphText
                }
            }
        }

        let sentenceText = joinedDeepgramSentenceText(from: source["sentences"] as? [[String: Any]])
        if !sentenceText.isEmpty {
            return sentenceText
        }

        if includeWordsFallback {
            return joinedDeepgramWordsText(from: source["words"] as? [[String: Any]])
        }

        return ""
    }


    private func normalizedDeepgramJoinedText(from chunks: [String]) -> String {
        var seen: Set<String> = []
        let merged = chunks
            .compactMap { chunk -> String? in
                let cleaned = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return nil }
                guard !seen.contains(cleaned) else { return nil }
                seen.insert(cleaned)
                return cleaned
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !merged.isEmpty else { return "" }
        var normalized = merged.replacingOccurrences(
            of: #"(?<=[\u3400-\u9FFF])\s+(?=[\u3400-\u9FFF])"#,
            with: "",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"\s+([，。！？；：、,.!?;:])"#,
            with: "$1",
            options: .regularExpression
        )
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }


    private func smartJoinDeepgramWordTokens(_ tokens: [String]) -> String {
        let lexicalTokens = tokens.filter { !isStandalonePunctuationToken($0) }
        let singleCharacterTokenCount = lexicalTokens.filter { $0.count == 1 }.count
        let shouldCompactSingleCharacters =
            lexicalTokens.count >= 4 &&
            singleCharacterTokenCount * 5 >= lexicalTokens.count * 4

        if shouldCompactSingleCharacters {
            return tokens.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var output = ""
        var previousToken: String?

        for token in tokens {
            if output.isEmpty {
                output = token
                previousToken = token
                continue
            }

            if let previousToken, shouldInsertSpaceBetweenWordTokens(previousToken, token) {
                output += " "
            }
            output += token
            previousToken = token
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }


    private func shouldInsertSpaceBetweenWordTokens(_ previous: String, _ next: String) -> Bool {
        if isStandalonePunctuationToken(previous) || isStandalonePunctuationToken(next) {
            return false
        }
        return isLatinOrDigitToken(previous) && isLatinOrDigitToken(next)
    }


    private func isStandalonePunctuationToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        return token.range(
            of: #"^[\p{P}\p{S}]+$"#,
            options: .regularExpression
        ) != nil
    }


    private func isLatinOrDigitToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            if CharacterSet.decimalDigits.contains(scalar) {
                return true
            }
            if CharacterSet.letters.contains(scalar), scalar.value < 0x0250 {
                return true
            }
            return false
        }
    }


    func deepgramResponseSummary(_ payload: [String: Any]) -> String {
        let deepgramResult = payload["results"] as? [String: Any] ?? payload
        let channels = deepgramResult["channels"] as? [[String: Any]] ?? []
        let utterances = deepgramResult["utterances"] as? [[String: Any]] ?? []

        let alternativeCount = channels.reduce(0) { partial, channel in
            partial + ((channel["alternatives"] as? [[String: Any]])?.count ?? 0)
        }
        let firstAlternative = channels
            .compactMap { ($0["alternatives"] as? [[String: Any]])?.first }
            .first
        let firstAltKeys = (firstAlternative?.keys.sorted().joined(separator: ",")) ?? "none"
        let firstAltTranscriptLength = normalizedString(firstAlternative?["transcript"])?.count ?? 0
        let firstAltParagraphTranscriptLength: Int = {
            guard
                let paragraphs = firstAlternative?["paragraphs"] as? [String: Any],
                let text = normalizedString(paragraphs["transcript"])
            else {
                return 0
            }
            return text.count
        }()

        return "channels=\(channels.count), alternatives=\(alternativeCount), utterances=\(utterances.count), firstAltKeys=\(firstAltKeys), firstAltTranscriptLen=\(firstAltTranscriptLength), firstAltParagraphTranscriptLen=\(firstAltParagraphTranscriptLength)"
    }


    func jsonSnippet(_ payload: [String: Any], maxLength: Int = 1600) -> String {
        guard JSONSerialization.isValidJSONObject(payload) else {
            return "<invalid-json-object>"
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]),
            let raw = String(data: data, encoding: .utf8)
        else {
            return "<json-serialization-failed>"
        }
        let compact = raw.replacingOccurrences(of: "\n", with: "")
        if compact.count <= maxLength {
            return compact
        }
        let endIndex = compact.index(compact.startIndex, offsetBy: maxLength)
        return String(compact[..<endIndex]) + "...<truncated>"
    }


    func extractTranscriptFallback(from payload: [String: Any]) -> String {
        let transcriptLikeKeys: Set<String> = [
            "text",
            "transcript",
            "transcription",
            "utterance",
            "utterances",
            "sentence",
            "sentences",
            "paragraph",
            "paragraphs",
            "content",
            "output_text",
        ]

        func isTranscriptLike(_ key: String) -> Bool {
            let normalized = key.lowercased()
            if transcriptLikeKeys.contains(normalized) {
                return true
            }
            return normalized.contains("transcript") || normalized.contains("utterance")
        }

        func walk(_ value: Any, keyHint: String?) -> [String] {
            if let dict = value as? [String: Any] {
                var collected: [String] = []
                for (key, child) in dict {
                    let childHint = isTranscriptLike(key) ? key : keyHint
                    collected.append(contentsOf: walk(child, keyHint: childHint))
                }
                return collected
            }
            if let array = value as? [Any] {
                return array.flatMap { walk($0, keyHint: keyHint) }
            }
            guard let keyHint else { return [] }
            guard isTranscriptLike(keyHint) else { return [] }
            if let text = normalizedString(value) {
                return [text]
            }
            return []
        }

        var seen: Set<String> = []
        return walk(payload, keyHint: nil)
            .compactMap { chunk -> String? in
                let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                guard !seen.contains(trimmed) else { return nil }
                seen.insert(trimmed)
                return trimmed
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }


    private func normalizedString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizeLanguageTag(_ raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.hasPrefix("zh") {
            return "zh-Hans"
        }
        if cleaned.hasPrefix("en") {
            return "en"
        }
        return cleaned
    }
}
