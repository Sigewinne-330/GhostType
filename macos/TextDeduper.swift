import Foundation

enum TextDeduper {
    static func dedupe(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        var units = splitIntoUnits(trimmed)
        guard !units.isEmpty else { return trimmed }

        units = removeConsecutiveDuplicateUnits(units)
        units = removeRepeatedTailBlocks(units)

        let merged = units.joined()
        return merged.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitIntoUnits(_ text: String) -> [String] {
        let sentenceBreakers: Set<Character> = ["。", "！", "？", ".", "!", "?", ";", "；", "\n"]
        var units: [String] = []
        var current = ""
        units.reserveCapacity(max(4, text.count / 10))

        for character in text {
            current.append(character)
            if sentenceBreakers.contains(character) {
                units.append(current)
                current = ""
            }
        }

        if !current.isEmpty {
            units.append(current)
        }

        if units.isEmpty {
            return [text]
        }
        return units
    }

    private static func removeConsecutiveDuplicateUnits(_ units: [String]) -> [String] {
        var output: [String] = []
        output.reserveCapacity(units.count)
        var previousKey: String?

        for unit in units {
            let key = comparisonKey(unit)
            guard !key.isEmpty else { continue }
            if key == previousKey {
                continue
            }
            output.append(unit)
            previousKey = key
        }

        return output
    }

    private static func removeRepeatedTailBlocks(_ units: [String]) -> [String] {
        guard units.count >= 2 else { return units }
        let keys = units.map(comparisonKey)
        let maxBlockSize = min(8, keys.count / 2)
        guard maxBlockSize > 0 else { return units }

        for blockSize in stride(from: maxBlockSize, through: 1, by: -1) {
            let tailStart = keys.count - blockSize
            let tail = keys[tailStart..<keys.count]

            var cursor = tailStart
            var repeatCount = 1
            while cursor - blockSize >= 0 {
                let candidate = keys[(cursor - blockSize)..<cursor]
                if candidate == tail {
                    repeatCount += 1
                    cursor -= blockSize
                } else {
                    break
                }
            }

            if repeatCount > 1 {
                let keepEnd = cursor + blockSize
                return Array(units[..<keepEnd])
            }
        }

        return units
    }

    private static func comparisonKey(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let collapsed = trimmed.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return collapsed.lowercased()
    }
}
