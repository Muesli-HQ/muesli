import Foundation

/// Removes known model hallucination artifacts emitted on silence or blank input.
/// Applied as post-processing after ASR, before filler word filtering.
struct TranscriptionEngineArtifactsFilter {

    private static let artifactPatterns: [String] = [
        #"(?i)\[\s*(?:blank[_\s-]*audio|no[_\s-]*speech|silence|inaudible|music|applause|laughter|screaming|cheering)\s*\]"#,
        #"(?i)[\[(<]\s*(?:speaking\s+in\s+)?(?:a\s+)?foreign\s+language\s*[\])>]"#,
        #"(?i)<\s*(?:eou|eob|unk|blank|pad)\s*>"#,
        #"(?i)<\|\s*(?:endoftext|nospeech|notimestamp|nodiarize|noitn|pnc|startofcontext|startoftranscript)\s*\|>"#,
    ]

    private static let promptLeakPatterns: [String] = [
        #"(?i)\btranscribe the spoken audio accurately\.?"#,
        #"(?i)\bif a word is unclear,?\s*use the most likely word that fits well within the context of the overall sentence(?:\s+transcription)?\.?"#,
    ]

    /// Removes known engine control tokens and non-speech annotations, then strips
    /// prompt leakage while preserving ordinary transcript text.
    static func apply(_ text: String) -> String {
        var stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var removedArtifact = false
        for pattern in artifactPatterns {
            let filtered = stripped.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
            removedArtifact = removedArtifact || filtered != stripped
            stripped = filtered
        }
        // Some streaming decoders prefix non-speech annotations with a speaker
        // marker. Do not leave that marker behind when the annotation is removed.
        if removedArtifact {
            stripped = stripped.replacingOccurrences(
                of: #"^\s*(?:>>|>|»)+\s*"#,
                with: "",
                options: .regularExpression
            )
        }

        return stripPromptLeakage(from: stripped)
    }

    private static func stripPromptLeakage(from text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text
        for pattern in promptLeakPatterns {
            result = replaceAnchoredPromptLeak(in: result, pattern: pattern, anchorAtStart: true)
            result = replaceAnchoredPromptLeak(in: result, pattern: pattern, anchorAtStart: false)
        }

        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceAnchoredPromptLeak(in text: String, pattern: String, anchorAtStart: Bool) -> String {
        let anchoredPattern = anchorAtStart
            ? #"^\s*(?:"# + pattern + #")(?:\s+|$)"#
            : #"(?:^|\s+)(?:"# + pattern + #")\s*$"#
        return text.replacingOccurrences(of: anchoredPattern, with: " ", options: .regularExpression)
    }
}
