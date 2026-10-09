import Foundation
import NaturalLanguage

/// Bodhan selects one language for each audio window, not for each word.
public struct BodhanLanguageSample: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let languageCode: String
    public let wasAutoDetected: Bool

    public init(startSeconds: Double, endSeconds: Double, languageCode: String, wasAutoDetected: Bool) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.languageCode = languageCode
        self.wasAutoDetected = wasAutoDetected
    }
}

/// A nil run list means this Bodhan output mode cannot locate language boundaries.
public struct BodhanWBCSMeasurement: Equatable, Sendable {
    public let languageSamples: [BodhanLanguageSample]
    public let runLengths: [Int]?

    public init(languageSamples: [BodhanLanguageSample], runLengths: [Int]?) {
        self.languageSamples = languageSamples
        self.runLengths = runLengths
    }
}

/// Estimates completed English runs in Bodhan Flex Mixed transcripts.
public enum WordsBeforeCodeSwitch {
    private enum Language {
        case english
        case other
    }

    // Strong cues only. Shared short words (for example "no" or "me") are
    // intentionally omitted because they also occur in English.
    private static let romanizedHindiCues: Set<String> = [
        "accha", "achha", "aaya", "aayi", "bahut", "bilkul", "chahiye", "dekho",
        "hain", "humko", "kaise", "kahan", "kyunki", "mujhe", "nahi", "nahin",
        "samajh", "shayad", "theek", "tumhe", "tumko", "waise", "yeh",
    ]

    /// Bodhan Flex's Mixed output keeps Indic speech in Indic script and
    /// English in Latin script. The window language alone cannot locate a
    /// switch inside a window, so use the raw merged transcript for boundaries.
    public static func bodhanMixedRunLengths(in text: String) -> [Int] {
        let words = tokenizedWords(in: text)
        guard !Task<Never, Never>.isCancelled else { return [] }
        return runLengths(for: words.map { word in
            let lower = word.lowercased()
            if romanizedHindiCues.contains(lower) { return .other }
            return word.unicodeScalars.contains(where: {
                CharacterSet.letters.contains($0) && !(0x0041...0x024F).contains($0.value)
            }) ? .other : .english
        })
    }

    private static func tokenizedWords(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var words: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            guard !Task<Never, Never>.isCancelled else { return false }
            let word = String(text[range])
            if word.rangeOfCharacter(from: .letters) != nil { words.append(word) }
            return true
        }
        return words
    }

    private static func runLengths(for languages: [Language]) -> [Int] {
        var result: [Int] = []
        var englishWords = 0
        for language in languages {
            switch language {
            case .english:
                englishWords += 1
            case .other:
                if englishWords > 0 { result.append(englishWords) }
                englishWords = 0
            }
        }
        return result
    }

    static func median(of lengths: [Int]) -> Double? {
        guard !lengths.isEmpty else { return nil }
        let sorted = lengths.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (Double(sorted[middle - 1]) + Double(sorted[middle])) / 2
        }
        return Double(sorted[middle])
    }

}
