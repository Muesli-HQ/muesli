import Foundation
import MuesliCore

/// Post-processing step that replaces transcribed words with entries from
/// the user's personal dictionary using fuzzy matching.
///
/// Matching stages (first match wins):
/// 1. Exact case-insensitive match
/// 2. Jaro-Winkler similarity >= the entry's configured threshold
struct CustomWordMatcher {

    struct Entry {
        let replacement: String
        let matchingThreshold: Double
        let tokens: [String]
        let normalizedPhrase: String

        init?(word: String, replacement: String, matchingThreshold: Double) {
            let tokens = Self.normalizedTokens(in: word)
            guard !tokens.isEmpty else { return nil }
            self.replacement = replacement
            self.matchingThreshold = matchingThreshold
            self.tokens = tokens
            normalizedPhrase = tokens.joined(separator: " ")
        }

        private static func normalizedTokens(in text: String) -> [String] {
            text.components(separatedBy: " ")
                .compactMap { CustomWordMatcher.tokenParts(for: $0)?.core.lowercased() }
        }
    }

    /// Apply custom word replacements to transcribed text.
    static func apply(text: String, customWords: [CustomWord]) -> String {
        guard !text.isEmpty, !customWords.isEmpty else { return text }

        let entries = customWords.compactMap {
            Entry(word: $0.word, replacement: $0.targetWord, matchingThreshold: $0.matchingThreshold)
        }
        guard !entries.isEmpty else { return text }

        let entriesByTokenCount = Dictionary(grouping: entries, by: { $0.tokens.count })
        let tokenCounts = entriesByTokenCount.keys.sorted(by: >)
        let words = text.components(separatedBy: " ")
        var result: [String] = []
        var index = 0

        while index < words.count {
            guard let match = bestMatch(in: words, startingAt: index, tokenCounts: tokenCounts, entriesByTokenCount: entriesByTokenCount) else {
                result.append(words[index])
                index += 1
                continue
            }

            result.append(match.text)
            index += match.consumed
        }

        return result.joined(separator: " ")
    }

    private struct TokenParts {
        let prefix: String
        let core: String
        let suffix: String
    }

    private struct Match {
        let text: String
        let consumed: Int
    }

    private static let boundaryPunctuation = CharacterSet(charactersIn: ".,!?;:\"'()[]{}")

    private static func bestMatch(
        in words: [String],
        startingAt index: Int,
        tokenCounts: [Int],
        entriesByTokenCount: [Int: [Entry]]
    ) -> Match? {
        for count in tokenCounts {
            guard count > 0, index + count <= words.count, let entries = entriesByTokenCount[count] else { continue }
            let window = Array(words[index..<(index + count)])
            let parts = window.compactMap(tokenParts)
            guard parts.count == count else { continue }
            guard preservesPhraseBoundaryPunctuation(parts) else { continue }

            let candidateTokens = parts.map { $0.core.lowercased() }
            let candidate = candidateTokens.joined(separator: " ")
            if let exact = entries.first(where: { $0.normalizedPhrase == candidate }) {
                return Match(
                    text: parts[0].prefix + exact.replacement + parts[count - 1].suffix,
                    consumed: count
                )
            }

            var bestEntry: Entry?
            var bestScore = 0.0
            for entry in entries {
                guard let score = similarity(candidateTokens: candidateTokens, entry: entry) else { continue }
                if score > bestScore {
                    bestScore = score
                    bestEntry = entry
                }
            }

            if let bestEntry {
                return Match(
                    text: parts[0].prefix + bestEntry.replacement + parts[count - 1].suffix,
                    consumed: count
                )
            }
        }

        return nil
    }

    private static func preservesPhraseBoundaryPunctuation(_ parts: [TokenParts]) -> Bool {
        guard parts.count > 1 else { return true }

        for i in 0..<parts.count {
            if i > 0, !parts[i].prefix.isEmpty { return false }
            if i < parts.count - 1, !parts[i].suffix.isEmpty { return false }
        }

        return true
    }

    private static func similarity(candidateTokens: [String], entry: Entry) -> Double? {
        guard candidateTokens.count == entry.tokens.count else { return nil }

        if entry.tokens.count == 1 {
            let score = jaroWinklerSimilarity(candidateTokens[0], entry.tokens[0])
            return score >= entry.matchingThreshold ? score : nil
        }

        let tokenScores = zip(candidateTokens, entry.tokens).map(jaroWinklerSimilarity)
        guard tokenScores.allSatisfy({ $0 >= entry.matchingThreshold }) else { return nil }
        return tokenScores.reduce(0, +) / Double(tokenScores.count)
    }

    private static func tokenParts(for token: String) -> TokenParts? {
        var start = token.startIndex
        var end = token.endIndex

        while start < end, isBoundaryPunctuation(token[start]) {
            start = token.index(after: start)
        }

        while start < end {
            let beforeEnd = token.index(before: end)
            guard isBoundaryPunctuation(token[beforeEnd]) else { break }
            end = beforeEnd
        }

        let core = String(token[start..<end])
        guard !core.isEmpty else { return nil }

        return TokenParts(
            prefix: String(token[..<start]),
            core: core,
            suffix: String(token[end...])
        )
    }

    private static func isBoundaryPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { boundaryPunctuation.contains($0) }
    }

    // MARK: - Jaro-Winkler Similarity

    /// Computes Jaro-Winkler similarity between two strings (0.0 to 1.0).
    static func jaroWinklerSimilarity(_ s1: String, _ s2: String) -> Double {
        let jaro = jaroSimilarity(s1, s2)
        guard jaro > 0 else { return 0 }

        // Winkler modification: boost for common prefix (up to 4 chars)
        let chars1 = Array(s1)
        let chars2 = Array(s2)
        let prefixLen = min(4, min(chars1.count, chars2.count))
        var commonPrefix = 0
        for i in 0..<prefixLen {
            if chars1[i] == chars2[i] {
                commonPrefix += 1
            } else {
                break
            }
        }

        return jaro + Double(commonPrefix) * 0.1 * (1.0 - jaro)
    }

    /// Computes Jaro similarity between two strings.
    private static func jaroSimilarity(_ s1: String, _ s2: String) -> Double {
        let chars1 = Array(s1)
        let chars2 = Array(s2)

        if chars1.isEmpty && chars2.isEmpty { return 1.0 }
        if chars1.isEmpty || chars2.isEmpty { return 0.0 }
        if chars1 == chars2 { return 1.0 }

        let matchWindow = max(chars1.count, chars2.count) / 2 - 1
        guard matchWindow >= 0 else { return 0.0 }

        var s1Matches = [Bool](repeating: false, count: chars1.count)
        var s2Matches = [Bool](repeating: false, count: chars2.count)

        var matches: Double = 0
        var transpositions: Double = 0

        // Find matches
        for i in 0..<chars1.count {
            let start = max(0, i - matchWindow)
            let end = min(chars2.count - 1, i + matchWindow)
            guard start <= end else { continue }

            for j in start...end {
                if s2Matches[j] || chars1[i] != chars2[j] { continue }
                s1Matches[i] = true
                s2Matches[j] = true
                matches += 1
                break
            }
        }

        guard matches > 0 else { return 0.0 }

        // Count transpositions
        var k = 0
        for i in 0..<chars1.count {
            guard s1Matches[i] else { continue }
            while !s2Matches[k] { k += 1 }
            if chars1[i] != chars2[k] { transpositions += 1 }
            k += 1
        }

        let m = matches
        let t = transpositions / 2.0
        return (m / Double(chars1.count) + m / Double(chars2.count) + (m - t) / m) / 3.0
    }
}
