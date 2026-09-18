import Foundation

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Shared stopword tables for the insights word analyzer.
///
/// Keyed by BCP-47 language code so the Apple NaturalLanguage path and the
/// portable Windows path consume exactly the same data.
enum InsightsStopwords {
    static let lists: [String: Set<String>] = [
        "en": ["a", "about", "actually", "all", "also", "an", "and", "are", "as", "at", "basically", "be", "been", "but", "by", "can", "could", "did", "do", "does", "even", "for", "from", "get", "go", "gonna", "got", "had", "has", "have", "he", "her", "here", "hers", "him", "his", "hmm", "how", "i", "if", "in", "into", "is", "it", "its", "just", "kind", "let", "like", "literally", "me", "more", "my", "no", "not", "of", "okay", "on", "one", "or", "other", "our", "ours", "really", "right", "she", "should", "so", "some", "sort", "still", "than", "that", "the", "their", "them", "then", "there", "these", "they", "this", "to", "too", "uh", "um", "up", "us", "very", "wanna", "want", "was", "we", "well", "were", "what", "when", "where", "which", "who", "why", "will", "with", "would", "yeah", "yes", "you", "your", "yours"],
        "es": ["a", "al", "algo", "como", "con", "de", "del", "el", "ella", "en", "es", "esta", "este", "la", "las", "lo", "los", "más", "no", "o", "para", "pero", "por", "que", "se", "sin", "su", "sus", "un", "una", "y", "ya"],
        "fr": ["à", "au", "aux", "avec", "ce", "ces", "dans", "de", "des", "du", "elle", "en", "est", "et", "il", "je", "la", "le", "les", "mais", "ne", "nous", "on", "ou", "pas", "pour", "que", "qui", "se", "sur", "tu", "un", "une", "vous"],
        "de": ["aber", "als", "am", "an", "auch", "auf", "aus", "bei", "das", "der", "die", "ein", "eine", "er", "es", "für", "hat", "ich", "im", "in", "ist", "mit", "nicht", "oder", "sie", "sind", "und", "von", "war", "was", "wir", "zu"],
        "it": ["a", "al", "che", "con", "da", "del", "della", "di", "e", "è", "gli", "ha", "i", "il", "in", "la", "le", "lo", "ma", "non", "o", "per", "più", "se", "sono", "su", "un", "una"],
        "pt": ["a", "as", "com", "como", "da", "das", "de", "do", "dos", "e", "é", "em", "essa", "este", "eu", "foi", "mais", "mas", "na", "não", "no", "o", "os", "ou", "para", "por", "que", "se", "um", "uma"],
        "hi": ["और", "का", "की", "के", "को", "है", "हैं", "था", "थी", "में", "से", "पर", "यह", "वह", "एक", "नहीं", "भी", "तो"],
    ]

    static let diacritics: [String: Set<Unicode.Scalar>] = [
        "es": Set("áéíóúñü".unicodeScalars),
        "fr": Set("àâçéèêëîïôùûüÿœ".unicodeScalars),
        "de": Set("äöüß".unicodeScalars),
        "it": Set("àèéìòù".unicodeScalars),
        "pt": Set("áâãàçéêíóôõú".unicodeScalars),
    ]

    /// Common irregular English forms that a light stemmer cannot recover.
    static let englishIrregulars: [String: String] = [
        "was": "be", "were": "be", "is": "be", "are": "be", "am": "be",
        "has": "have", "had": "have",
        "does": "do", "did": "do",
        "went": "go", "gone": "go",
        "said": "say", "made": "make", "got": "get",
        "better": "good", "best": "good",
    ]
}

/// Platform-neutral insights word accumulation.
///
/// macOS keeps Apple NaturalLanguage (language recognition, tokenization and
/// lemma tagging). Windows uses an internal implementation of exactly the
/// behavior Muesli needs: script/stopword language detection, Unicode word
/// tokenization, shared stopword filtering and a conservative English stemmer.
/// No ICU dependency is required.
enum InsightsTextAnalysis {

    static func accumulate(_ text: String, into counts: inout [String: Int]) {
        #if canImport(NaturalLanguage)
        accumulateUsingNaturalLanguage(text, into: &counts)
        #else
        accumulatePortable(text, into: &counts)
        #endif
    }

    // MARK: - Apple NaturalLanguage

    #if canImport(NaturalLanguage)
    private static let appleStopwords: [NLLanguage: Set<String>] = Dictionary(
        uniqueKeysWithValues: InsightsStopwords.lists.map { (NLLanguage(rawValue: $0.key), $0.value) }
    )

    static func accumulateUsingNaturalLanguage(_ text: String, into counts: inout [String: Int]) {
        guard !text.isEmpty else { return }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let language = recognizer.dominantLanguage
        let ignored = language.flatMap { appleStopwords[$0] } ?? []

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
    #endif

    // MARK: - Portable implementation (all platforms)

    static func accumulatePortable(_ text: String, into counts: inout [String: Int]) {
        guard !text.isEmpty else { return }
        let language = detectLanguage(in: text)
        let ignored = InsightsStopwords.lists[language] ?? []

        for token in tokenize(text) {
            let raw = token.lowercased()
            let word = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard word.count > 1,
                  word.rangeOfCharacter(from: .letters) != nil,
                  word.rangeOfCharacter(from: .decimalDigits) == nil,
                  !ignored.contains(word) else { continue }
            let normalized = normalize(word, language: language)
            guard !ignored.contains(normalized) else { continue }
            counts[normalized, default: 0] += 1
        }
    }

    /// Lightweight language detection: Devanagari script wins outright,
    /// otherwise score each language by stopword hits and distinctive
    /// diacritics, defaulting to English when there is no signal.
    static func detectLanguage(in text: String) -> String {
        if text.unicodeScalars.contains(where: { (0x0900...0x097F).contains($0.value) }) {
            return "hi"
        }

        let tokens = tokenize(text)
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }

        var scores: [String: Int] = [:]
        for (code, words) in InsightsStopwords.lists where code != "hi" {
            var score = 0
            for token in tokens where words.contains(token) { score += 1 }
            if let marks = InsightsStopwords.diacritics[code] {
                score += text.unicodeScalars.filter { marks.contains($0) }.count / 3
            }
            scores[code] = score
        }

        let best = scores.max { lhs, rhs in
            lhs.value < rhs.value || (lhs.value == rhs.value && lhs.key > rhs.key)
        }
        if let best, best.value > 0 { return best.key }
        return "en"
    }

    /// Unicode word tokenization: maximal runs of letters, numbers, combining
    /// marks and intra-word apostrophes. Equivalent to `NLTokenizer(unit: .word)`
    /// for the inputs Muesli handles.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        for scalar in text.unicodeScalars {
            let properties = scalar.properties
            let isWordCharacter =
                properties.isAlphabetic ||
                properties.numericType != nil ||
                properties.generalCategory == .nonspacingMark ||
                properties.generalCategory == .spacingMark ||
                scalar == "'" || scalar == "\u{2019}"
            if isWordCharacter {
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// Normalize a token for counting. Non-English languages only get case
    /// folding and possessive stripping; English additionally gets a
    /// conservative stemmer so inflections merge.
    static func normalize(_ word: String, language: String) -> String {
        var normalized = word
        if normalized.hasSuffix("'s") || normalized.hasSuffix("\u{2019}s") {
            normalized = String(normalized.dropLast(2))
        }
        guard language == "en" else { return normalized }
        if let irregular = InsightsStopwords.englishIrregulars[normalized] {
            return irregular
        }
        return stemEnglish(normalized)
    }

    /// Conservative, deterministic English stemmer covering the inflections
    /// that matter for insights word frequency. Not a full Porter stemmer.
    static func stemEnglish(_ word: String) -> String {
        guard word.count > 3 else { return word }

        if word.hasSuffix("ies"), word.count > 4 {
            return String(word.dropLast(3)) + "y"
        }
        if word.hasSuffix("sses") {
            return String(word.dropLast(2))
        }
        if word.hasSuffix("ches") || word.hasSuffix("shes") || word.hasSuffix("xes") || word.hasSuffix("zes") {
            return String(word.dropLast(2))
        }
        if word.hasSuffix("ied") {
            return String(word.dropLast(3)) + "y"
        }
        if word.hasSuffix("ing"), word.count > 5 {
            return undoubleFinalConsonant(String(word.dropLast(3)))
        }
        if word.hasSuffix("ed"), word.count > 4 {
            return undoubleFinalConsonant(String(word.dropLast(2)))
        }
        if word.hasSuffix("s"),
           !word.hasSuffix("ss"),
           !word.hasSuffix("us"),
           !word.hasSuffix("is") {
            return String(word.dropLast())
        }
        return word
    }

    private static func undoubleFinalConsonant(_ stem: String) -> String {
        guard stem.count > 2 else { return stem }
        let characters = Array(stem)
        let last = characters[characters.count - 1]
        let previous = characters[characters.count - 2]
        // 'l' is excluded: "called" -> "call", not "cal".
        if last == previous, last != "l", !"aeiou".contains(last) {
            return String(stem.dropLast())
        }
        return stem
    }
}
