import Foundation
import NaturalLanguage

public enum InsightsWordAnalyzer {
    private static let stopWords: [NLLanguage: Set<String>] = [
        .english: ["a", "about", "actually", "all", "also", "an", "and", "are", "as", "at", "basically", "be", "been", "but", "by", "can", "could", "did", "do", "does", "even", "for", "from", "get", "go", "gonna", "got", "had", "has", "have", "he", "her", "here", "hers", "him", "his", "hmm", "how", "i", "if", "in", "into", "is", "it", "its", "just", "kind", "let", "like", "literally", "me", "more", "my", "no", "not", "of", "okay", "on", "one", "or", "other", "our", "ours", "really", "right", "she", "should", "so", "some", "sort", "still", "than", "that", "the", "their", "them", "then", "there", "these", "they", "this", "to", "too", "uh", "um", "up", "us", "very", "wanna", "want", "was", "we", "well", "were", "what", "when", "where", "which", "who", "why", "will", "with", "would", "yeah", "yes", "you", "your", "yours"],
        .spanish: ["a", "al", "algo", "como", "con", "de", "del", "el", "ella", "en", "es", "esta", "este", "la", "las", "lo", "los", "más", "no", "o", "para", "pero", "por", "que", "se", "sin", "su", "sus", "un", "una", "y", "ya"],
        .french: ["à", "au", "aux", "avec", "ce", "ces", "dans", "de", "des", "du", "elle", "en", "est", "et", "il", "je", "la", "le", "les", "mais", "ne", "nous", "on", "ou", "pas", "pour", "que", "qui", "se", "sur", "tu", "un", "une", "vous"],
        .german: ["aber", "als", "am", "an", "auch", "auf", "aus", "bei", "das", "der", "die", "ein", "eine", "er", "es", "für", "hat", "ich", "im", "in", "ist", "mit", "nicht", "oder", "sie", "sind", "und", "von", "war", "was", "wir", "zu"],
        .italian: ["a", "al", "che", "con", "da", "del", "della", "di", "e", "è", "gli", "ha", "i", "il", "in", "la", "le", "lo", "ma", "non", "o", "per", "più", "se", "sono", "su", "un", "una"],
        .portuguese: ["a", "as", "com", "como", "da", "das", "de", "do", "dos", "e", "é", "em", "essa", "este", "eu", "foi", "mais", "mas", "na", "não", "no", "o", "os", "ou", "para", "por", "que", "se", "um", "uma"],
        .hindi: ["और", "का", "की", "के", "को", "है", "हैं", "था", "थी", "में", "से", "पर", "यह", "वह", "एक", "नहीं", "भी", "तो"],
    ]

    public static func frequencies(in text: String, limit: Int = 48) -> [InsightsWordFrequency] {
        var counts: [String: Int] = [:]
        accumulate(text, into: &counts)
        return ranked(counts, limit: limit)
    }

    public static func meetingFrequencies(in transcript: String, limit: Int = 48) -> [InsightsWordFrequency] {
        frequencies(in: cleanedMeetingTranscript(transcript), limit: limit)
    }

    static func accumulateMeetingTranscript(_ transcript: String, into counts: inout [String: Int]) {
        accumulate(cleanedMeetingTranscript(transcript), into: &counts)
    }

    static func cleanedMeetingTranscript(_ transcript: String) -> String {
        let withoutSpeakerLabels = transcript.replacingOccurrences(
            of: #"(?im)^\s*(?:\[[^\]\n]+\]\s*)?(?:speaker\s*\d+|you|others)\s*:\s*"#,
            with: "",
            options: .regularExpression
        )
        return withoutSpeakerLabels.replacingOccurrences(
            of: #"(?i)\[(?:blank_audio|music playing|audience laughing|applause|laughter|inaudible|silence)[^\]]*\]"#,
            with: " ",
            options: .regularExpression
        )
    }

    static func accumulate(_ text: String, into counts: inout [String: Int]) {
        guard !text.isEmpty else { return }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let language = recognizer.dominantLanguage
        let ignored = language.flatMap { stopWords[$0] } ?? []

        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let raw = String(text[range]).lowercased(with: Locale(identifier: language?.rawValue ?? "und"))
            let word = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard word.count > 1,
                  word.rangeOfCharacter(from: .letters) != nil,
                  word.rangeOfCharacter(from: .decimalDigits) == nil,
                  !ignored.contains(word) else { return true }
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            let normalized = (lemma?.isEmpty == false ? lemma! : word).lowercased()
            guard !ignored.contains(normalized) else { return true }
            counts[normalized, default: 0] += 1
            return true
        }
    }

    static func ranked(_ counts: [String: Int], limit: Int) -> [InsightsWordFrequency] {
        var frequencies = counts.map { word, count in
            InsightsWordFrequency(word: word, count: count)
        }
        frequencies.sort {
            if $0.count == $1.count { return $0.word < $1.word }
            return $0.count > $1.count
        }
        return Array(frequencies.prefix(max(0, limit)))
    }
}
