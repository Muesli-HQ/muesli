import Foundation
import NaturalLanguage

/// Estimates the length of English runs that end at a change of language.
/// Transcript text has no word-level language labels, so uncertain words do
/// not establish a language boundary.
enum WordsBeforeCodeSwitch {
    enum Language {
        case english
        case other
        case uncertain
    }

    private static let englishCues: Set<String> = [
        "a", "am", "and", "are", "as", "at", "be", "but", "can", "do", "for", "from",
        "good", "have", "he", "hello", "i", "in", "is", "it", "my", "of", "on", "or", "our",
        "she", "should", "so", "that", "the", "then", "there", "these", "think", "this",
        "to", "we", "what", "when", "where", "which", "will", "with", "would", "you",
    ]

    // Strong cues only. Shared short words (for example "no" or "me") are
    // intentionally omitted because they also occur in English.
    private static let romanizedHindiCues: Set<String> = [
        "accha", "achha", "aaya", "aayi", "bahut", "bilkul", "chahiye", "dekho",
        "hain", "humko", "kaise", "kahan", "kyunki", "mujhe", "nahi", "nahin",
        "samajh", "shayad", "theek", "tumhe", "tumko", "waise", "yeh",
    ]

    static func runLengths(in text: String) -> [Int] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var words: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            if word.rangeOfCharacter(from: .letters) != nil {
                words.append(word)
            }
            return true
        }
        let languages = words.indices.map { classify(words: words, at: $0) }
        return runLengths(for: languages)
    }

    static func runLengths(for languages: [Language]) -> [Int] {
        var result: [Int] = []
        var englishWords = 0
        for language in languages {
            switch language {
            case .english:
                englishWords += 1
            case .uncertain:
                if englishWords > 0 { englishWords += 1 }
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

    private static func classify(words: [String], at index: Int) -> Language {
        let word = words[index].lowercased()
        // Accented Latin letters still need context; other scripts are a
        // clear switch even when the surrounding phrase is short.
        if word.unicodeScalars.contains(where: {
            CharacterSet.letters.contains($0) && !(0x0041...0x024F).contains($0.value)
        }) {
            return .other
        }
        if romanizedHindiCues.contains(word) { return .other }
        if englishCues.contains(word) { return .english }

        let end = min(words.count, index + 4)
        let window = words[index..<end].map { $0.lowercased() }
        if window.dropFirst().contains(where: {
            englishCues.contains($0) || romanizedHindiCues.contains($0)
        }) {
            return .uncertain
        }
        let phrase = window.joined(separator: " ")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(phrase)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let best = hypotheses.max(by: { $0.value < $1.value }), best.value >= 0.95 else {
            return .uncertain
        }
        return best.key == .english ? .english : .other
    }
}
