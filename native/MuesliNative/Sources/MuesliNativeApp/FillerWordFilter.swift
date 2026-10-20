import Foundation
import MuesliCore

/// Removes filler words and verbal disfluencies from transcribed text.
/// Applied as post-processing after ASR, before custom word matching.
struct FillerWordFilter {

    /// Filler words to remove (matched case-insensitively as whole words).
    /// "er" is deliberately absent: it is the Norwegian/Danish verb "is" and must survive meeting cleanup.
    private static let fillers: Set<String> = [
        "uh", "um", "uh,", "um,", "uhh", "umm",
        "err", "ah", "ahh",
        "hmm", "hm", "mm", "mmm",
        "like,",   // "like" as filler only when followed by comma
        "you know,",
    ]

    /// Multi-word filler phrases to remove.
    private static let fillerPhrases: [(pattern: String, replacement: String)] = [
        ("you know,", ""),
        ("i mean,", ""),
        ("sort of", ""),
        ("kind of", ""),
    ]

    /// Remove filler words from transcribed text.
    static func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text

        // Phase 1: Remove multi-word filler phrases (case-insensitive)
        for phrase in fillerPhrases {
            let range = result.range(of: phrase.pattern, options: [.caseInsensitive])
            while let r = result.range(of: phrase.pattern, options: [.caseInsensitive]) {
                result.replaceSubrange(r, with: phrase.replacement)
            }
            let _ = range // suppress warning
        }

        // Phase 2: Remove single filler words
        let words = result.components(separatedBy: " ")
        let filtered = words.filter { word in
            !fillers.contains(word.lowercased())
        }

        result = filtered.joined(separator: " ")

        // Clean up: collapse multiple spaces, trim
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        result = result.trimmingCharacters(in: .whitespaces)

        // Fix capitalization after removal (re-capitalize sentence starts)
        if let first = result.first, first.isLowercase {
            result = result.prefix(1).uppercased() + result.dropFirst()
        }

        return result
    }
}
