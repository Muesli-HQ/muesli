import Foundation

/// A user-defined dictionary entry: a word or phrase Muesli's ASR output should be
/// corrected to, applied post-transcription by `CustomWordMatcher`.
public struct CustomWord: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var word: String
    public var replacement: String?
    public var matchingThreshold: Double = 0.85

    enum CodingKeys: String, CodingKey {
        case id
        case word
        case replacement
        case matchingThreshold = "matching_threshold"
    }

    public init(id: UUID = UUID(), word: String, replacement: String?, matchingThreshold: Double = 0.85) {
        self.id = id
        self.word = word
        self.replacement = replacement
        self.matchingThreshold = Self.clampedThreshold(matchingThreshold)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        word = try c.decode(String.self, forKey: .word)
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement)
        matchingThreshold = Self.clampedThreshold(try c.decodeIfPresent(Double.self, forKey: .matchingThreshold) ?? 0.85)
    }

    public var displayLabel: String {
        if let replacement, !replacement.isEmpty {
            return "\(word) → \(replacement)"
        }
        return word
    }

    public var targetWord: String {
        replacement ?? word
    }

    private static func clampedThreshold(_ value: Double) -> Double {
        min(max(value, 0.70), 0.95)
    }
}

/// Post-processing step that replaces transcribed words with entries from
/// the user's personal dictionary using fuzzy matching.
///
/// Matching stages (first match wins):
/// 1. Exact case-insensitive match
/// 2. Jaro-Winkler similarity >= the entry's configured threshold, for words
///    of plausibly similar length (see `isPlausibleMisrecognition`)
///
/// A trailing possessive ("'s") on the matched text is kept, and a multi-word
/// replacement is not duplicated when the surrounding words already spell it.
public struct CustomWordMatcher {

    struct Entry {
        let replacement: String
        let matchingThreshold: Double
        let tokens: [String]
        /// Words of `replacement`, and their normalized forms, used to avoid
        /// re-inserting words of a multi-word replacement that are already present.
        let replacementWords: [String]
        let replacementTokens: [String]
        let endsWithPossessive: Bool

        init?(word: String, replacement: String, matchingThreshold: Double) {
            let tokens = Self.normalizedTokens(in: word)
            guard let lastToken = tokens.last else { return nil }
            self.replacement = replacement
            self.matchingThreshold = matchingThreshold
            self.tokens = tokens
            replacementWords = replacement.components(separatedBy: " ")
                .filter { CustomWordMatcher.tokenParts(for: $0) != nil }
            replacementTokens = Self.normalizedTokens(in: replacement)
            endsWithPossessive = !CustomWordMatcher.possessiveSuffix(of: lastToken).isEmpty
        }

        private static func normalizedTokens(in text: String) -> [String] {
            text.components(separatedBy: " ")
                .compactMap { CustomWordMatcher.tokenParts(for: $0)?.core.lowercased() }
        }
    }

    /// Apply custom word replacements to transcribed text.
    public static func apply(text: String, customWords: [CustomWord]) -> String {
        guard !text.isEmpty, !customWords.isEmpty else { return text }

        let entries = customWords.compactMap {
            Entry(word: $0.word, replacement: $0.targetWord, matchingThreshold: $0.matchingThreshold)
        }
        guard !entries.isEmpty else { return text }

        let entriesByTokenCount = Dictionary(grouping: entries, by: { $0.tokens.count })
        let tokenCounts = entriesByTokenCount.keys.sorted(by: >)
        let words = text.components(separatedBy: " ")
        // Only entries whose replacement has more words than they match look
        // at the words after a match, so the lookahead is filled just for them.
        let lookahead = Lookahead(count: words.count)
        if entries.contains(where: { $0.replacementTokens.count > $0.tokens.count }) {
            for position in stride(from: words.count - 1, through: 0, by: -1) {
                lookahead.matches[position] = bestMatch(
                    in: words, startingAt: position, emitted: [],
                    tokenCounts: tokenCounts, entriesByTokenCount: entriesByTokenCount, lookahead: lookahead
                )
            }
        }
        // Output so far, one word per element, so a match can see the words
        // already written before it.
        var result: [String] = []
        // Words before this point include words an earlier replacement added,
        // which are not reused as part of a later one, so separate matches each
        // keep their full replacement.
        var reusableStart = 0
        var index = 0

        while index < words.count {
            guard let match = bestMatch(
                in: words, startingAt: index, emitted: result[reusableStart...],
                tokenCounts: tokenCounts, entriesByTokenCount: entriesByTokenCount, lookahead: lookahead
            ) else {
                result.append(words[index])
                index += 1
                continue
            }

            let matchWords = match.text.components(separatedBy: " ")
            result.append(contentsOf: matchWords)
            // A match that keeps its word count only respells (or recases) the
            // words that were spoken, so they stay available for reuse.
            if matchWords.count != match.consumed {
                reusableStart = result.count
            }
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

    /// The match `bestMatch` finds at each position of the input when no
    /// output comes before it. It is filled from the last position back, and a
    /// lookup only reads positions after the one being filled, so checking the
    /// words after a match takes constant work instead of a recursive search.
    private final class Lookahead {
        var matches: [Match?]

        init(count: Int) {
            matches = Array(repeating: nil, count: count)
        }
    }

    private static let boundaryPunctuation = CharacterSet(charactersIn: ".,!?;:\"'()[]{}")
    private static let possessiveMarkers = ["'s", "\u{2019}s"]

    /// A shorter word below this fraction of the longer word's length is a
    /// different word, not a misrecognition ("yes" vs "Yonesh" scores 0.85).
    private static let minimumLengthRatio = 0.6
    /// A shorter word that is the start of the longer one, missing at least this
    /// many characters, is a different word ("north" vs "Northcap" scores 0.93).
    private static let minimumTruncatedCharacters = 3

    private static func bestMatch(
        in words: [String],
        startingAt index: Int,
        emitted: ArraySlice<String>,
        tokenCounts: [Int],
        entriesByTokenCount: [Int: [Entry]],
        lookahead: Lookahead
    ) -> Match? {
        for count in tokenCounts {
            guard count > 0, index + count <= words.count, let entries = entriesByTokenCount[count] else { continue }
            let window = Array(words[index..<(index + count)])
            let parts = window.compactMap(tokenParts)
            guard parts.count == count else { continue }
            guard preservesPhraseBoundaryPunctuation(parts) else { continue }

            // A trailing possessive is compared without its "'s" and put back
            // after the replacement, unless the entry itself ends in one.
            let candidateTokens = parts.map { $0.core.lowercased() }
            let possessive = possessiveSuffix(of: parts[count - 1].core)
            var strippedTokens = candidateTokens
            if !possessive.isEmpty {
                strippedTokens[count - 1] = String(strippedTokens[count - 1].dropLast(possessive.count))
            }
            func candidate(for entry: Entry) -> (tokens: [String], possessive: String) {
                possessive.isEmpty || entry.endsWithPossessive ? (candidateTokens, "") : (strippedTokens, possessive)
            }
            func match(_ entry: Entry, possessive: String) -> Match {
                // The "'s" goes after the match, so the words after it can't be
                // part of the replacement.
                let replacement = replacementText(
                    for: entry, in: words, at: index, count: count, emitted: emitted,
                    reusesFollowing: possessive.isEmpty, lookahead: lookahead
                )
                // A replacement that already ends in "'s" keeps its own ending,
                // and an empty replacement removes the word along with its "'s".
                let lastCore = replacement.components(separatedBy: " ").last.flatMap { tokenParts(for: $0)?.core } ?? ""
                let ending = replacement.isEmpty || !possessiveSuffix(of: lastCore).isEmpty ? "" : possessive
                return Match(
                    text: parts[0].prefix + replacement + ending + parts[count - 1].suffix,
                    consumed: count
                )
            }

            // An entry for the words exactly as spoken wins over one that only
            // matches once the "'s" is set aside.
            if let exact = entries.first(where: { $0.tokens == candidateTokens }) {
                return match(exact, possessive: "")
            }
            if !possessive.isEmpty,
               let exact = entries.first(where: { !$0.endsWithPossessive && $0.tokens == strippedTokens }) {
                return match(exact, possessive: possessive)
            }

            var bestEntry: Entry?
            var bestScore = 0.0
            for entry in entries {
                guard let score = similarity(candidateTokens: candidate(for: entry).tokens, entry: entry) else { continue }
                if score > bestScore {
                    bestScore = score
                    bestEntry = entry
                }
            }

            if let bestEntry {
                return match(bestEntry, possessive: candidate(for: bestEntry).possessive)
            }
        }

        return nil
    }

    /// The text to insert for a matched window. When the replacement has more
    /// words than the window and the words around it already spell the rest of
    /// it (before the match in the output so far, after it in the input, with
    /// no sentence break in between), only the window's own part of the
    /// replacement is inserted, so "XY Widget" stays "XY Widget" rather than
    /// becoming "XY XY Widget".
    ///
    /// Words are only reused when nothing is lost by doing so: the replacement
    /// words left out carry no punctuation of their own, and no other entry
    /// will later rewrite a reused following word into something else.
    private static func replacementText(
        for entry: Entry, in words: [String], at index: Int, count: Int, emitted: ArraySlice<String>,
        reusesFollowing: Bool, lookahead: Lookahead
    ) -> String {
        let extra = entry.replacementTokens.count - count
        guard extra > 0, entry.replacementWords.count == entry.replacementTokens.count else {
            return entry.replacement
        }
        func normalized<S: Sequence<String>>(_ span: S) -> [String] {
            span.map { tokenParts(for: $0)?.core.lowercased() ?? "" }
        }
        func isBare(_ word: String) -> Bool {
            tokenParts(for: word).map { $0.prefix.isEmpty && $0.suffix.isEmpty } ?? false
        }
        /// Whether the words in `range` come out of `apply` as the same words,
        /// ignoring case and punctuation.
        func staysUnchanged(_ range: Range<Int>) -> Bool {
            var position = range.lowerBound
            while position < range.upperBound {
                guard let later = lookahead.matches[position] else {
                    position += 1
                    continue
                }
                let original = words[position..<(position + later.consumed)]
                if normalized(later.text.components(separatedBy: " ")) != normalized(original) { return false }
                position += later.consumed
            }
            return true
        }

        let window = Array(words[index..<(index + count)])
        for before in stride(from: extra, through: 0, by: -1) {
            let after = extra - before
            guard after == 0 || reusesFollowing,
                  emitted.count >= before, index + count + after <= words.count else { continue }
            let preceding = Array(emitted.suffix(before))
            let followingRange = (index + count)..<(index + count + after)
            let following = Array(words[followingRange])
            guard normalized(preceding) == Array(entry.replacementTokens[..<before]),
                  normalized(following) == Array(entry.replacementTokens[(before + count)...]) else { continue }
            let span = (preceding + window + following).compactMap(tokenParts)
            guard span.count == before + count + after, preservesPhraseBoundaryPunctuation(span) else { continue }
            let omitted = entry.replacementWords[..<before] + entry.replacementWords[(before + count)...]
            guard omitted.allSatisfy(isBare), staysUnchanged(followingRange) else { continue }
            return entry.replacementWords[before..<(before + count)].joined(separator: " ")
        }
        return entry.replacement
    }

    /// The trailing "'s" (straight or curly apostrophe) of a word, in its
    /// original case, or "" when it has none.
    private static func possessiveSuffix(of word: String) -> String {
        for marker in possessiveMarkers where word.count > marker.count && word.lowercased().hasSuffix(marker) {
            return String(word.suffix(marker.count))
        }
        return ""
    }

    /// Jaro-Winkler rewards a shared prefix, so on its own it scores ordinary
    /// short words highly against longer entries that start the same way. A
    /// recognizer misspells a word; it rarely drops a large part of it.
    private static func isPlausibleMisrecognition(_ candidate: String, _ entry: String) -> Bool {
        let (short, long) = candidate.count <= entry.count ? (candidate, entry) : (entry, candidate)
        guard long.count > 0 else { return true }
        if Double(short.count) / Double(long.count) < minimumLengthRatio { return false }
        if long.hasPrefix(short), long.count - short.count >= minimumTruncatedCharacters { return false }
        return true
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
        guard zip(candidateTokens, entry.tokens).allSatisfy(isPlausibleMisrecognition) else { return nil }

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
    public static func jaroWinklerSimilarity(_ s1: String, _ s2: String) -> Double {
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
