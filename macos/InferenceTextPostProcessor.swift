import Foundation

protocol TextDeduping {
    func dedupe(_ text: String) -> String
}

struct DefaultTextDeduper: TextDeduping {
    func dedupe(_ text: String) -> String {
        TextDeduper.dedupe(text)
    }
}

@MainActor
struct InferenceTextPostProcessor {
    private let logger: AppLogger
    private let deduper: any TextDeduping
    private let shouldDedupe: () -> Bool
    private let isIMNaturalChatPreset: (String) -> Bool

    init(
        logger: AppLogger,
        deduper: any TextDeduping = DefaultTextDeduper(),
        shouldDedupe: @escaping () -> Bool,
        isIMNaturalChatPreset: @escaping (String) -> Bool
    ) {
        self.logger = logger
        self.deduper = deduper
        self.shouldDedupe = shouldDedupe
        self.isIMNaturalChatPreset = isIMNaturalChatPreset
    }

    func dedupe(_ text: String, stage: String, sessionID: UUID) -> String {
        guard shouldDedupe() else { return text }
        let deduped = deduper.dedupe(text)
        if deduped != text {
            logger.log(
                "Deduper changed \(stage) text. sessionId=\(sessionID.uuidString) beforeChars=\(text.count) afterChars=\(deduped.count)",
                type: .debug
            )
        }
        return deduped
    }

    func process(_ raw: String, request: InferenceRequest, sessionID: UUID) -> String {
        let deduped = dedupe(raw, stage: "LLM", sessionID: sessionID)
        guard request.mode == .dictate,
              let dictationContext = request.dictationContext,
              isIMNaturalChatPreset(dictationContext.preset.id) else {
            return deduped
        }

        var output = deduped
        output = output.replacingOccurrences(
            of: #"(?m)^\s*[-*•·]+\s+"#,
            with: "",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"[ \t]+\n"#,
            with: "\n",
            options: .regularExpression
        )
        output = mergeLinesIntoParagraphs(output)

        if output != deduped {
            logger.log(
                "WeChat deterministic postprocess changed output. sessionId=\(sessionID.uuidString) beforeChars=\(deduped.count) afterChars=\(output.count)",
                type: .debug
            )
        }

        return output
    }

    private func mergeLinesIntoParagraphs(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var paragraphs: [String] = []
        var buffer: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if !buffer.isEmpty {
                    paragraphs.append(buffer.joined(separator: " "))
                    buffer.removeAll(keepingCapacity: true)
                }
                if paragraphs.last != "" {
                    paragraphs.append("")
                }
                continue
            }
            buffer.append(trimmed)
        }

        if !buffer.isEmpty {
            paragraphs.append(buffer.joined(separator: " "))
        }

        return paragraphs.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
