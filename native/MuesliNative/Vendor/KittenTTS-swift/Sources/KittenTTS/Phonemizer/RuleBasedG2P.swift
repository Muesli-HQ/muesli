import Foundation

/// English grapheme-to-phoneme (G2P) engine.
///
/// Converts normalised English text to IPA phoneme strings compatible with the
/// KittenTTS symbol table. A hand-curated dictionary is consulted first; unknown
/// words fall back to simplified NRL-style letter-to-sound rules.
///
/// ```swift
/// let ipa = Phonemizer.phonemize("Hello, world!")
/// // "həˈloʊ, wɝːld!"
/// ```
enum Phonemizer {

    // MARK: - Public API

    /// Convert a normalised English sentence to an IPA phoneme string.
    ///
    /// Words are separated by a single space (token ID 16 in ``TextCleaner``).
    ///
    /// - Parameter sentence: Text that has already been processed by ``TextPreprocessor/process(_:)``.
    /// - Returns: IPA string ready to pass to ``TextCleaner/encode(_:)``.
    static func phonemize(_ sentence: String) -> String {
        let words = tokenize(sentence)
        return words.map { phonemizeWord($0) }.joined(separator: " ")
    }

    // MARK: - Tokenization

    private static func tokenize(_ sentence: String) -> [String] {
        // Match words (letters + apostrophes only — hyphens are treated as word boundaries)
        // and punctuation tokens separately.
        let pattern = #"[a-zA-Z']+|[;:,\.!?—…]"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = sentence as NSString
        var tokens: [String] = []
        for match in re.matches(in: sentence, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: match.range)
            // Split CamelCase so "KittenTTS" → ["Kitten", "TTS"],  "iPhone" → ["i", "Phone"]
            tokens.append(contentsOf: splitCamelCase(word))
        }
        return tokens
    }

    /// Splits a CamelCase or PascalCase word into its component words.
    /// "KittenTTS" → ["Kitten", "TTS"],  "iPhone" → ["i", "Phone"],  "hello" → ["hello"]
    private static func splitCamelCase(_ word: String) -> [String] {
        guard word.count > 1 else { return [word] }
        // If entirely lowercase or uppercase, return as-is
        let hasLower = word.contains(where: { $0.isLowercase })
        let hasUpper = word.contains(where: { $0.isUppercase })
        guard hasLower && hasUpper else { return [word] }

        var parts: [String] = []
        var current = ""
        let chars = Array(word)
        for i in 0..<chars.count {
            let ch = chars[i]
            if i > 0 && ch.isUppercase {
                let prevIsLower = chars[i - 1].isLowercase
                let nextIsLower = (i + 1 < chars.count) && chars[i + 1].isLowercase
                let prevIsUpper = chars[i - 1].isUppercase
                // Split on lowercase→uppercase boundary ("Kitten|TTS")
                // or on UPPER+upper→Upper boundary ("HTML|Parser")
                if prevIsLower || (prevIsUpper && nextIsLower && current.count > 1) {
                    if !current.isEmpty { parts.append(current) }
                    current = String(ch)
                    continue
                }
            }
            current.append(ch)
        }
        if !current.isEmpty { parts.append(current) }
        return parts.count > 1 ? parts : [word]
    }

    // MARK: - Word phonemization

    private static func phonemizeWord(_ word: String) -> String {
        let punctSet: Set<Character> = [";", ":", ",", ".", "!", "?", "—", "…"]
        if word.count == 1, let ch = word.first, punctSet.contains(ch) {
            return String(ch)
        }

        let lower = word.lowercased()

        if let ipa = lexicon[lower] { return ipa }

        // Possessives and contractions
        if lower.hasSuffix("'s") {
            let base = String(lower.dropLast(2))
            if let ipa = lexicon[base] { return ipa + "z" }
        }
        if lower.hasSuffix("n't") {
            let base = String(lower.dropLast(3))
            return (lexicon[base] ?? ruleG2P(base)) + "nt"
        }
        if lower.hasSuffix("'re") {
            let base = String(lower.dropLast(3))
            return (lexicon[base] ?? ruleG2P(base)) + "ɹ"
        }
        if lower.hasSuffix("'ll") {
            let base = String(lower.dropLast(3))
            return (lexicon[base] ?? ruleG2P(base)) + "l"
        }
        if lower.hasSuffix("'ve") {
            let base = String(lower.dropLast(3))
            return (lexicon[base] ?? ruleG2P(base)) + "v"
        }

        // Common suffixes — derive from dictionary base when possible
        if lower.hasSuffix("ing") {
            let base = String(lower.dropLast(3))
            if let ipa = lexicon[base]       { return ipa + "ɪŋ" }
            if let ipa = lexicon[base + "e"] { return ipa.droppingLastVowel() + "ɪŋ" }
        }
        if lower.hasSuffix("ed") {
            let base = String(lower.dropLast(2))
            if let ipa = lexicon[base]       { return ipa + endedSuffix(ipa) }
            if let ipa = lexicon[base + "e"] { return ipa + "d" }
        }
        if lower.hasSuffix("er") {
            let base = String(lower.dropLast(2))
            if let ipa = lexicon[base] { return ipa + "ɚ" }
        }
        if lower.hasSuffix("ers") {
            let base = String(lower.dropLast(3))
            if let ipa = lexicon[base] { return ipa + "ɚz" }
        }
        if lower.hasSuffix("est") {
            let base = String(lower.dropLast(3))
            if let ipa = lexicon[base] { return ipa + "ɪst" }
        }
        if lower.hasSuffix("tion") {
            let base = String(lower.dropLast(4))
            return (lexicon[base] ?? ruleG2P(base)) + "ʃən"
        }
        if lower.hasSuffix("sion") {
            let base = String(lower.dropLast(4))
            return (lexicon[base] ?? ruleG2P(base)) + "ʒən"
        }
        if lower.hasSuffix("ness") {
            let base = String(lower.dropLast(4))
            return (lexicon[base] ?? ruleG2P(base)) + "nɪs"
        }
        if lower.hasSuffix("ly") {
            let base = String(lower.dropLast(2))
            return (lexicon[base] ?? ruleG2P(base)) + "li"
        }
        if lower.hasSuffix("ment") {
            let base = String(lower.dropLast(4))
            return (lexicon[base] ?? ruleG2P(base)) + "mənt"
        }
        if lower.hasSuffix("ful") {
            let base = String(lower.dropLast(3))
            return (lexicon[base] ?? ruleG2P(base)) + "fəl"
        }
        if lower.hasSuffix("less") {
            let base = String(lower.dropLast(4))
            return (lexicon[base] ?? ruleG2P(base)) + "lɪs"
        }
        if lower.hasSuffix("able") || lower.hasSuffix("ible") {
            let base = String(lower.dropLast(4))
            return (lexicon[base] ?? ruleG2P(base)) + "əbəl"
        }
        if lower.hasSuffix("s") && lower.count > 2 {
            let base = String(lower.dropLast(1))
            if let ipa = lexicon[base] { return ipa + pluralSuffix(ipa) }
        }

        return ruleG2P(lower)
    }

    // MARK: - Suffix helpers

    private static func endedSuffix(_ ipa: String) -> String {
        guard let last = ipa.last else { return "d" }
        switch last {
        case "t", "d":                          return "ɪd"
        case "p", "k", "f", "s", "ʃ", "ʧ":    return "t"
        default:                                return "d"
        }
    }

    private static func pluralSuffix(_ ipa: String) -> String {
        guard let last = ipa.last else { return "z" }
        switch last {
        case "s", "z", "ʃ", "ʒ", "ʧ", "ʤ":   return "ɪz"
        case "p", "t", "k", "f", "θ":          return "s"
        default:                                return "z"
        }
    }

    // MARK: - Rule-based G2P

    /// Simplified NRL-style letter-to-sound rules for American English.
    private static func ruleG2P(_ word: String) -> String {
        let chars = Array(word.lowercased())
        var result = ""
        var i = 0

        while i < chars.count {
            let remaining = String(chars[i...])
            let prev: Character = i > 0 ? chars[i - 1] : " "
            let next: Character = i + 1 < chars.count ? chars[i + 1] : " "
            let next2: Character = i + 2 < chars.count ? chars[i + 2] : " "

            // Trigraphs
            if remaining.hasPrefix("tch") { result += "ʧ";  i += 3; continue }
            if remaining.hasPrefix("dge") { result += "ʤ";  i += 3; continue }
            if remaining.hasPrefix("nge") && i > 0 { result += "ʤ"; i += 2; continue }
            if remaining.hasPrefix("sch") { result += "sk"; i += 3; continue }
            if remaining.hasPrefix("igh") { result += "aɪ"; i += 3; continue }
            if remaining.hasPrefix("augh") { result += "ɔː"; i += 4; continue }
            if remaining.hasPrefix("ough") { result += "oʊ"; i += 4; continue }

            // Digraphs
            if remaining.hasPrefix("sh") { result += "ʃ";  i += 2; continue }
            if remaining.hasPrefix("ch") { result += "ʧ";  i += 2; continue }
            if remaining.hasPrefix("ph") { result += "f";  i += 2; continue }
            if remaining.hasPrefix("wh") { result += "w";  i += 2; continue }
            if remaining.hasPrefix("th") { result += "θ";  i += 2; continue }
            if remaining.hasPrefix("ck") { result += "k";  i += 2; continue }
            if remaining.hasPrefix("ng") &&
               (i + 2 >= chars.count || !"aeiou".contains(chars[i + 2])) {
                result += "ŋ"; i += 2; continue
            }
            if remaining.hasPrefix("nk") { result += "ŋk"; i += 2; continue }
            if remaining.hasPrefix("qu") { result += "kw"; i += 2; continue }

            // Vowel digraphs
            if remaining.hasPrefix("ai") || remaining.hasPrefix("ay") { result += "eɪ"; i += 2; continue }
            if remaining.hasPrefix("au") || remaining.hasPrefix("aw") { result += "ɔː"; i += 2; continue }
            if remaining.hasPrefix("oa") { result += "oʊ"; i += 2; continue }
            if remaining.hasPrefix("ow") {
                let atEnd   = i + 2 >= chars.count
                let beforeN = !atEnd && chars[i + 2] == "n"
                result += (atEnd || beforeN) ? "oʊ" : "aʊ"
                i += 2; continue
            }
            if remaining.hasPrefix("ou") { result += "aʊ"; i += 2; continue }
            if remaining.hasPrefix("oi") || remaining.hasPrefix("oy") { result += "ɔɪ"; i += 2; continue }
            if remaining.hasPrefix("ee") || remaining.hasPrefix("ea") { result += "i";  i += 2; continue }
            if remaining.hasPrefix("oo") {
                let beforeDK = i + 2 < chars.count && (chars[i + 2] == "d" || chars[i + 2] == "k")
                result += beforeDK ? "ʊ" : "u"
                i += 2; continue
            }
            if remaining.hasPrefix("ie") { result += "i";  i += 2; continue }
            if remaining.hasPrefix("ei") { result += "i";  i += 2; continue }
            if remaining.hasPrefix("eu") || remaining.hasPrefix("ew") { result += "ju"; i += 2; continue }
            if remaining.hasPrefix("ue") { result += "u";  i += 2; continue }
            if remaining.hasPrefix("ui") { result += "u";  i += 2; continue }

            if remaining.hasPrefix("tion") { result += "ʃən"; i += 4; continue }
            if remaining.hasPrefix("sion") { result += "ʒən"; i += 4; continue }
            if remaining.hasPrefix("ture") { result += "ʧɚ"; i += 4; continue }

            // Single letters
            let ch = chars[i]
            let isVowel = { (c: Character) in "aeiou".contains(c) }

            switch ch {
            case "a":
                if magicE(chars: chars, vowelAt: i)          { result += "eɪ" }
                else if next == "r" && !isVowel(next2)        { result += "ɑːɹ"; i += 2; continue }
                else if next == "l" && !isVowel(next2)        { result += "ɔːl"; i += 2; continue }
                else                                           { result += "æ" }
            case "e":
                if i == chars.count - 1 && i > 0              { /* silent e — skip */ }
                else if magicE(chars: chars, vowelAt: i)      { result += "i" }
                else if next == "r" && !isVowel(next2)        { result += "ɝ"; i += 2; continue }
                else                                           { result += "ɛ" }
            case "i":
                if magicE(chars: chars, vowelAt: i)           { result += "aɪ" }
                else if next == "r" && !isVowel(next2)        { result += "ɝ"; i += 2; continue }
                else                                           { result += "ɪ" }
            case "o":
                if magicE(chars: chars, vowelAt: i)           { result += "oʊ" }
                else if remaining.hasPrefix("or") && !isVowel(next2) { result += "ɔːɹ"; i += 2; continue }
                else if next == "n" || next == "m"            { result += "ʌ" }
                else                                           { result += "ɑ" }
            case "u":
                if magicE(chars: chars, vowelAt: i) {
                    result += (prev == "r" || prev == "l" || prev == "j") ? "u" : "ju"
                } else if next == "r" && !isVowel(next2)     { result += "ɝ"; i += 2; continue }
                else                                           { result += "ʌ" }
            case "b":
                if i == chars.count - 1 && prev == "m"        { /* silent: comb, dumb */ }
                else                                           { result += "b" }
            case "c":
                if "eiy".contains(next)                        { result += "s" }
                else                                           { result += "k" }
            case "d": result += "d"
            case "f": result += "f"
            case "g":
                if "eiy".contains(next)                        { result += "ʤ" }
                else if next == "n" && i == 0                  { i += 1; result += "n"; i += 1; continue }
                else if next == "h"                            { i += 2; continue }
                else                                           { result += "ɡ" }
            case "h": result += "h"
            case "j": result += "ʤ"
            case "k":
                if next == "n" && i == 0                       { /* silent: know, knife */ }
                else                                           { result += "k" }
            case "l": result += "l"
            case "m": result += "m"
            case "n": result += "n"
            case "p":
                if i == 0 && (next == "n" || next == "s")     { /* silent: pneumonia, psyche */ }
                else                                           { result += "p" }
            case "q": result += "k"
            case "r": result += "ɹ"
            case "s":
                let prevVowel = i > 0 && "aeiou".contains(prev)
                let nextVowel = isVowel(next)
                if prevVowel && nextVowel                      { result += "z" }
                else if prevVowel && next == " "               { result += "z" }
                else                                           { result += "s" }
            case "t":
                if remaining.hasPrefix("ts")                   { result += "ts"; i += 2; continue }
                else                                           { result += "t" }
            case "v": result += "v"
            case "w":
                if next == "r"                                 { /* silent: write */ }
                else                                           { result += "w" }
            case "x":
                if i == 0                                      { result += "z" }
                else                                           { result += "ks" }
            case "y":
                if i == 0                                      { result += "j" }
                else if isVowel(prev)                          { result += "i" }
                else                                           { result += "ɪ" }
            case "z": result += "z"
            default:  result += String(ch)
            }

            i += 1
        }

        return result
    }

    /// Returns `true` if the vowel at `idx` is in a magic-E pattern
    /// (vowel + one or more consonants + silent 'e' at end of word).
    private static func magicE(chars: [Character], vowelAt idx: Int) -> Bool {
        guard idx + 2 < chars.count else { return false }
        var j = idx + 1
        while j < chars.count - 1 && !"aeiou".contains(chars[j]) { j += 1 }
        return j == chars.count - 1 && chars[j] == "e"
    }

    // MARK: - Lexicon

    /// Hand-curated IPA pronunciation dictionary for common English words.
    ///
    /// All characters are from the KittenTTS symbol table.
    static let lexicon: [String: String] = [
        // Articles & determiners
        "the": "ðə",     "a": "ə",       "an": "æn",

        // Personal pronouns
        "i": "aɪ",       "me": "mi",     "my": "maɪ",    "myself": "maɪˈsɛlf",
        "you": "ju",     "your": "jʊɹ",  "yourself": "jʊɹˈsɛlf",
        "he": "hi",      "him": "hɪm",   "his": "hɪz",
        "she": "ʃi",     "her": "hɝ",
        "it": "ɪt",      "its": "ɪts",
        "we": "wi",      "us": "ʌs",     "our": "aʊɹ",
        "they": "ðeɪ",   "them": "ðɛm",  "their": "ðɛɹ",  "theirs": "ðɛɹz",

        // Demonstratives
        "this": "ðɪs",   "that": "ðæt",  "these": "ðiz",  "those": "ðoʊz",

        // Question words
        "what": "wʌt",   "which": "wɪʧ", "who": "hu",     "whom": "hum",
        "whose": "huz",  "when": "wɛn",  "where": "wɛɹ",  "why": "waɪ",
        "how": "haʊ",

        // Prepositions & conjunctions
        "and": "ænd",    "or": "ɔːɹ",    "but": "bʌt",    "nor": "nɔːɹ",
        "so": "soʊ",     "yet": "jɛt",   "for": "fɔːɹ",
        "in": "ɪn",      "on": "ɑn",     "at": "æt",      "to": "tə",
        "of": "əv",      "with": "wɪð",  "by": "baɪ",     "from": "fɹʌm",
        "up": "ʌp",      "out": "aʊt",   "off": "ɔːf",    "down": "daʊn",
        "over": "oʊvɚ",  "under": "ʌndɚ","about": "əbaʊt","above": "əbʌv",
        "across": "əkɹɑs","after": "æftɚ","against": "əɡɛnst",
        "along": "əlɔːŋ","among": "əmʌŋ","around": "əɹaʊnd",
        "before": "bɪfɔːɹ","behind": "bɪhaɪnd","below": "bɪloʊ",
        "between": "bɪtwin","beyond": "biɑnd","during": "dʊɹɪŋ",
        "except": "ɪksɛpt","inside": "ɪnsaɪd","into": "ɪntu",
        "near": "nɪɹ",   "onto": "ɑntu",  "outside": "aʊtsaɪd",
        "since": "sɪns",  "than": "ðæn",  "through": "θɹu","till": "tɪl",
        "toward": "tɔːɹd","until": "ʌntɪl","upon": "əpɑn",
        "within": "wɪðɪn","without": "wɪðaʊt",

        // Auxiliary verbs
        "is": "ɪz",      "are": "ɑːɹ",   "was": "wɑz",    "were": "wɝ",
        "be": "bi",      "been": "bɪn",   "being": "biɪŋ",
        "have": "hæv",   "has": "hæz",    "had": "hæd",
        "do": "du",      "does": "dʌz",   "did": "dɪd",    "done": "dʌn",
        "will": "wɪl",   "would": "wʊd",  "could": "kʊd",  "should": "ʃʊd",
        "may": "meɪ",    "might": "maɪt", "must": "mʌst",  "can": "kæn",
        "shall": "ʃæl",

        // Common irregular verbs
        "go": "ɡoʊ",     "goes": "ɡoʊz",  "went": "wɛnt",  "gone": "ɡɑn",
        "come": "kʌm",   "came": "keɪm",  "coming": "kʌmɪŋ",
        "get": "ɡɛt",    "got": "ɡɑt",    "getting": "ɡɛtɪŋ",
        "give": "ɡɪv",   "gave": "ɡeɪv",  "given": "ɡɪvən",
        "take": "teɪk",  "took": "tʊk",   "taken": "teɪkən",
        "make": "meɪk",  "made": "meɪd",  "making": "meɪkɪŋ",
        "see": "si",     "saw": "sɔː",    "seen": "sin",
        "know": "noʊ",   "knew": "nu",    "known": "noʊn",
        "say": "seɪ",    "said": "sɛd",   "says": "sɛz",
        "think": "θɪŋk", "thought": "θɔːt",
        "tell": "tɛl",   "told": "toʊld",
        "feel": "fil",   "felt": "fɛlt",
        "leave": "liv",  "left": "lɛft",
        "find": "faɪnd", "found": "faʊnd",
        "keep": "kip",   "kept": "kɛpt",
        "put": "pʊt",
        "bring": "bɹɪŋ", "brought": "bɹɔːt",
        "buy": "baɪ",    "bought": "bɔːt",
        "teach": "tiʧ",  "taught": "tɔːt",
        "catch": "kæʧ",  "caught": "kɔːt",
        "run": "ɹʌn",    "ran": "ɹæn",    "running": "ɹʌnɪŋ",
        "write": "ɹaɪt", "wrote": "ɹoʊt", "written": "ɹɪtən",
        "read": "ɹid",   "reading": "ɹidɪŋ",
        "speak": "spik", "spoke": "spoʊk", "spoken": "spoʊkən",
        "break": "bɹeɪk","broke": "bɹoʊk","broken": "bɹoʊkən",
        "meet": "mit",   "met": "mɛt",
        "send": "sɛnd",  "sent": "sɛnt",
        "build": "bɪld", "built": "bɪlt",
        "hold": "hoʊld", "held": "hɛld",
        "stand": "stænd","stood": "stʊd",
        "lose": "luz",   "lost": "lɔːst",
        "lead": "lid",   "led": "lɛd",
        "grow": "ɡɹoʊ",  "grew": "ɡɹu",   "grown": "ɡɹoʊn",
        "draw": "dɹɔː",  "drew": "dɹu",   "drawn": "dɹɔːn",
        "fall": "fɔːl",  "fell": "fɛl",   "fallen": "fɔːlən",
        "sit": "sɪt",    "sat": "sæt",
        "pay": "peɪ",    "paid": "peɪd",
        "wear": "wɛɹ",   "wore": "wɔːɹ",  "worn": "wɔːɹn",
        "eat": "it",     "ate": "eɪt",    "eaten": "itən",
        "drive": "dɹaɪv","drove": "dɹoʊv","driven": "dɹɪvən",
        "fly": "flaɪ",   "flew": "flu",   "flown": "floʊn",
        "win": "wɪn",    "won": "wʌn",
        "sing": "sɪŋ",   "sang": "sæŋ",   "sung": "sʌŋ",
        "swim": "swɪm",  "swam": "swæm",  "swum": "swʌm",
        "begin": "bɪɡɪn","began": "bɪɡæn","begun": "bɪɡʌn",
        "choose": "ʧuz", "chose": "ʧoʊz", "chosen": "ʧoʊzən",
        "bite": "baɪt",  "bit": "bɪt",    "bitten": "bɪtən",
        "hide": "haɪd",  "hid": "hɪd",    "hidden": "hɪdən",
        "hit": "hɪt",    "let": "lɛt",    "set": "sɛt",    "cut": "kʌt",
        "shut": "ʃʌt",   "spread": "spɹɛd",

        // Common nouns (irregular plurals)
        "man": "mæn",    "men": "mɛn",
        "woman": "wʊmən","women": "wɪmɪn",
        "child": "ʧaɪld","children": "ʧɪldɹən",
        "mouse": "maʊs", "mice": "maɪs",
        "tooth": "tuθ",  "teeth": "tiθ",
        "foot": "fʊt",   "feet": "fit",
        "leaf": "lif",   "leaves": "livz",
        "life": "laɪf",  "lives": "laɪvz",
        "knife": "naɪf", "knives": "naɪvz",
        "half": "hæf",   "halves": "hævz",
        "shelf": "ʃɛlf", "shelves": "ʃɛlvz",
        "wolf": "wʊlf",  "wolves": "wʊlvz",
        "ox": "ɑks",     "oxen": "ɑksən",

        // Numbers
        "zero": "ziɹoʊ",  "one": "wʌn",    "two": "tu",
        "three": "θɹi",   "four": "fɔːɹ",  "five": "faɪv",
        "six": "sɪks",    "seven": "sɛvən", "eight": "eɪt",
        "nine": "naɪn",   "ten": "tɛn",     "eleven": "ɪlɛvən",
        "twelve": "twɛlv","thirteen": "θɝːtin","fourteen": "fɔːɹtin",
        "fifteen": "fɪftin","sixteen": "sɪkstin","seventeen": "sɛvəntin",
        "eighteen": "eɪtin","nineteen": "naɪntin","twenty": "twɛnti",
        "thirty": "θɝːti","forty": "fɔːɹti","fifty": "fɪfti",
        "sixty": "sɪksti","seventy": "sɛvənti","eighty": "eɪti",
        "ninety": "naɪnti","hundred": "hʌndɹəd","thousand": "θaʊzənd",
        "million": "mɪljən","billion": "bɪljən","trillion": "tɹɪljən",
        "first": "fɝːst", "second": "sɛkənd","third": "θɝːd",

        // Irregular spellings
        "enough": "ɪnʌf", "laugh": "læf",   "rough": "ɹʌf",
        "tough": "tʌf",   "cough": "kɔːf",  "though": "ðoʊ",
        "thorough": "θɝːoʊ","fought": "fɔːt",
        "once": "wʌns",   "twice": "twaɪs",
        "walk": "wɔːk",   "talk": "tɔːk",   "chalk": "ʧɔːk",
        "again": "əɡɛn",
        "people": "pipəl","there": "ðɛɹ",   "here": "hɪɹ",
        "every": "ɛvɹi",  "never": "nɛvɚ",
        "always": "ɔːlweɪz","often": "ɑfən","already": "ɔːlɹɛdi",
        "also": "ɔːlsoʊ", "only": "oʊnli",  "even": "ivən",
        "both": "boʊθ",   "either": "iðɚ",  "neither": "niðɚ",
        "other": "ʌðɚ",   "some": "sʌm",    "any": "ɛni",
        "many": "mɛni",   "much": "mʌʧ",    "more": "mɔːɹ",
        "most": "moʊst",  "such": "sʌʧ",    "each": "iʧ",
        "all": "ɔːl",     "few": "fju",     "little": "lɪtəl",
        "own": "oʊn",     "same": "seɪm",   "not": "nɑt",
        "no": "noʊ",      "yes": "jɛs",
        "very": "vɛɹi",   "just": "ʤʌst",   "still": "stɪl",
        "well": "wɛl",    "then": "ðɛn",    "now": "naʊ",
        "way": "weɪ",     "new": "nu",      "old": "oʊld",
        "good": "ɡʊd",    "great": "ɡɹeɪt", "big": "bɪɡ",
        "small": "smɔːl", "high": "haɪ",    "low": "loʊ",
        "long": "lɔːŋ",   "short": "ʃɔːɹt", "large": "lɑːɹʤ",
        "hard": "hɑːɹd",  "early": "ɝːli",  "late": "leɪt",
        "true": "tɹu",    "real": "ɹɪəl",   "right": "ɹaɪt",
        "wrong": "ɹɔːŋ",  "next": "nɛkst",  "last": "læst",
        "young": "jʌŋ",   "full": "fʊl",    "sure": "ʃʊɹ",
        "free": "fɹi",    "open": "oʊpən",  "best": "bɛst",
        "better": "bɛtɚ", "nice": "naɪs",   "fine": "faɪn",
        "able": "eɪbəl",  "possible": "pɑsɪbəl",
        "important": "ɪmpɔːɹtənt","different": "dɪfɚənt",
        "special": "spɛʃəl","social": "soʊʃəl","national": "næʃənəl",
        "because": "bɪkɔːz","while": "waɪl",
        "example": "ɪɡzæmpəl","together": "təɡɛðɚ",
        "world": "wɝːld",  "love": "lʌv",
        "time": "taɪm",   "year": "jɪɹ",    "day": "deɪ",
        "week": "wik",    "month": "mʌnθ",  "home": "hoʊm",
        "school": "skul", "work": "wɝːk",   "book": "bʊk",
        "word": "wɝːd",   "name": "neɪm",   "place": "pleɪs",
        "water": "wɑtɚ",  "room": "ɹum",    "door": "dɔːɹ",
        "hand": "hænd",   "eye": "aɪ",      "eyes": "aɪz",
        "face": "feɪs",   "head": "hɛd",    "heart": "hɑːɹt",
        "body": "bɑdi",   "voice": "vɔɪs",  "mind": "maɪnd",
        "town": "taʊn",   "city": "sɪti",   "country": "kʌntɹi",
        "friend": "fɹɛnd","family": "fæməli","mother": "mʌðɚ",
        "father": "fɑːðɚ","brother": "bɹʌðɚ","sister": "sɪstɚ",
        "question": "kwɛsʧən","answer": "ænsɚ",
        "problem": "pɹɑbləm","idea": "aɪdiə",
        "money": "mʌni",  "company": "kʌmpəni",
        "system": "sɪstəm","number": "nʌmbɚ",
        "power": "paʊɚ",  "story": "stɔːɹi",
        "program": "pɹoʊɡɹæm","information": "ɪnfɚmeɪʃən",
        "computer": "kəmpjutɚ","internet": "ɪntɚnɛt",
        "language": "læŋɡwɪʤ","model": "mɑdəl",
        "data": "deɪtə",  "audio": "ɔːdioʊ",
        "speech": "spiʧ", "machine": "məʃin","neural": "nʊɹəl",
        "artificial": "ɑːɹtɪfɪʃəl","intelligence": "ɪntɛlɪʤəns",
        "technology": "tɛknɑlədʒi","software": "sɔːftwɛɹ",
        "hello": "həˈloʊ",

        // Silent letters / tricky spellings
        "knight": "naɪt", "night": "naɪt",  "light": "laɪt",
        "fight": "faɪt",  "sight": "saɪt",  "tight": "taɪt",
        "bright": "bɹaɪt","flight": "flaɪt","weight": "weɪt",
        "height": "haɪt",
        "daughter": "dɔːtɚ","laughter": "læftɚ","slaughter": "slɔːtɚ",
        "colonel": "kɝːnəl","island": "aɪlənd","listen": "lɪsən",
        "soften": "sɔːfən","fasten": "fæsən",
        "castle": "kæsəl","whistle": "wɪsəl","thistle": "θɪsəl",
        "muscle": "mʌsəl","vehicle": "viɪkəl",
        "beauty": "bjuti","beautiful": "bjutɪfəl",
        "pretty": "pɹɪti",   "busy": "bɪzi",
        "business": "bɪznɪs","issue": "ɪʃu",
        "sugar": "ʃʊɡɚ",  "ocean": "oʊʃən",
        "ancient": "eɪnʃənt","patience": "peɪʃəns",
        "facial": "feɪʃəl","nation": "neɪʃən","station": "steɪʃən",
        "action": "ækʃən","attention": "ətɛnʃən","position": "pəzɪʃən",
        "television": "tɛlɪvɪʒən","vision": "vɪʒən",
        "decision": "dɪsɪʒən","version": "vɝːʒən",

        // KittenTTS demo words
        "kitten": "kɪtən",   "cat": "kæt",    "dog": "dɑɡ",
        "text": "tɛkst",
        "synthesize": "sɪnθəsaɪz","synthesis": "sɪnθɪsɪs",
        "generate": "ʤɛnɚeɪt","generation": "ʤɛnɚeɪʃən",

        // Common words missing from original lexicon (demo-sentence coverage + tech vocab)
        "welcome": "wˈɛlkəm",
        "fast": "fˈæst",
        "device": "dɪvˈaɪs",
        "engine": "ˈɛnʤɪn",
        "engines": "ˈɛnʤɪnz",
        "simple": "sˈɪmpəl",
        "easy": "ˈizi",
        "please": "plˈiz",
        "thank": "θˈæŋk",
        "thanks": "θˈæŋks",
        "help": "hˈɛlp",
        "create": "kɹiˈeɪt",
        "support": "səpˈɔːɹt",
        "service": "sˈɝːvɪs",
        "memory": "mˈɛməɹi",
        "message": "mˈɛsɪʤ",
        "today": "tədˈeɪ",
        "sorry": "sˈɑːɹi",
        "platform": "ˈplætfɔːɹm",
        "network": "nˈɛtwɝːk",
        "output": "ˈaʊtpʊt",
        "input": "ˈɪnpʊt",
        "developer": "dɪvˈɛləpɚ",
        "developers": "dɪvˈɛləpɚz",
        "framework": "ˈfɹeɪmwɝːk",
        "process": "ˈpɹɑsɛs",
        "access": "ˈæksɛs",
        "server": "sˈɝːvɚ",
        "client": "klˈaɪənt",
        "interface": "ˈɪntɚfeɪs",
        "swift": "swˈɪft",
        "apple": "ˈæpəl",
        "user": "jˈuzɚ",
        "users": "jˈuzɚz",

        // Acronyms / abbreviations (spelled out letter by letter)
        "tts": "tiːtiːˈɛs",
        "api": "ˌeɪpiˈaɪ",
        "sdk": "ˌɛsdiˈkeɪ",
        "ios": "ˌaɪoʊˈɛs",
        "ai": "ˌeɪˈaɪ",
        "ml": "ˌɛmˈɛl",
        "url": "ˌjuɑːɹˈɛl",
        "ui": "ˌjuˈaɪ",
        "cpu": "ˌsipiˈju",
        "gpu": "ˌʤipiˈju",
    ]
}
