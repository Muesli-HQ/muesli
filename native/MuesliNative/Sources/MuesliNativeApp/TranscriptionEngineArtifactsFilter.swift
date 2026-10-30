import Foundation

/// Removes known model hallucination artifacts emitted on silence or blank input.
/// Applied as post-processing after ASR, before filler word filtering.
struct TranscriptionEngineArtifactsFilter {

    // Only decorated, known non-speech labels are cues. Bare words ("cheers",
    // "music", "crickets") and arbitrary parenthetical/Markdown prose survive.
    private static let cueLabels: Set<String> = [
        "blank audio", "no speech", "silence", "inaudible", "unintelligible",
        "crickets", "crickets chirping", "chirping", "cheers", "cheering",
        "crowd cheering", "audience cheering", "applause", "clapping",
        "laughter", "laughing", "audience laughing", "chuckles", "chuckling",
        "screaming", "sighs", "sighing", "coughs", "coughing",
        "music", "music playing", "background music", "instrumental music",
        "background noise", "noise", "crowd noise", "audience noise",
        "cheers and applause", "cheering and applause", "applause and cheering",
        "laughter and applause",
    ]
    private static let decoratedCue = try! NSRegularExpression(
        pattern: #"\[[^\[\]]*\]|\([^()]*\)|<[^<>]*>|(?<!\*)\*\*(?!\*)[^*]+\*\*(?!\*)|(?<!\*)\*(?!\*)[^*]+\*(?!\*)"#
    )
    private static let unfinishedCue = try! NSRegularExpression(
        pattern: #"[\[(<][^\[\]()<>*]*$|\*{1,2}[^*\[\]()<>]*\*?$"#
    )

    private static func cueBody(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "[]()<>*"))
            .lowercased()
            .replacingOccurrences(of: #"[_\s-]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
    }

    private static func stripCues(_ text: String, holdUnfinished: Bool, removeComplete: Bool = true) -> String {
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let complete = decoratedCue.matches(in: text, range: fullRange)
        var end = source.length
        if holdUnfinished, let candidate = unfinishedCue.firstMatch(in: text, range: fullRange),
           // A closing star from ordinary Markdown is not a new cue opener.
           !complete.contains(where: { NSLocationInRange(candidate.range.location, $0.range) }) {
            let body = cueBody(source.substring(with: candidate.range))
            if body.isEmpty || cueLabels.contains(where: { $0.hasPrefix(body) }) {
                end = candidate.range.location
            }
        }
        guard removeComplete else { return source.substring(to: end) }
        let result = NSMutableString(string: source.substring(to: end))
        for match in complete.reversed() where NSMaxRange(match.range) <= end {
            if cueLabels.contains(cueBody(source.substring(with: match.range))) {
                result.replaceCharacters(in: match.range, with: " ")
            }
        }
        return result as String
    }

    /// Presentation only: keep raw words/timestamps available to the streaming
    /// aligner. Holding an unfinished cue avoids first inserting then deleting it.
    /// Unlike full cleanup, this cannot strip a newly completed prompt suffix.
    static func applyToCommittedText(_ text: String) -> String {
        normalizeSpacing(stripCues(text, holdUnfinished: true))
    }

    static func applyToPartialText(_ text: String) -> String {
        apply(stripCues(text, holdUnfinished: true, removeComplete: false))
    }

    private static let artifactPatterns: [String] = [
        #"(?i)\[\s*(?:blank[_\s-]*audio|no[_\s-]*speech|silence|inaudible|music|applause|laughter|screaming|cheering)\s*\]"#,
        #"(?i)[\[(<]\s*(?:speaking\s+in\s+)?(?:a\s+)?foreign\s+language\s*[\])>]"#,
        #"(?i)<\s*(?:eou|eob|unk|blank|pad)\s*>"#,
        // Any `<|...|>` control token (Whisper/Cohere), e.g. `<|nocaptions|>`, `<|nospeech|>`, `<|no|>`.
        #"<\|[^|<>]*\|>"#,
    ]

    private static let promptLeakPatterns: [String] = [
        #"(?i)\btranscribe the spoken audio accurately\.?"#,
        #"(?i)\bif a word is unclear,?\s*use the most likely word that fits well within the context of the overall sentence(?:\s+transcription)?\.?"#,
    ]

    /// Removes known engine control tokens and non-speech annotations, then strips
    /// prompt leakage while preserving ordinary transcript text.
    static func apply(_ text: String) -> String {
        var stripped = stripCues(text, holdUnfinished: false)
        var removedArtifact = stripped != text
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

    /// The final pass runs after cleanup and custom-word expansion, which may
    /// deliberately introduce Markdown, paragraphs, tabs, or aligned columns.
    /// Remove annotations only; ASR whitespace/prompt normalization belongs to
    /// the initial pass and must not flatten the user's formatted output here.
    static func applyPreservingLayout(_ text: String) -> String {
        var result = removeMatchesPreservingLayout(decoratedCue, from: text) {
            cueLabels.contains(cueBody($0))
        }
        for pattern in artifactPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            result = removeMatchesPreservingLayout(expression, from: result)
        }
        if result != text {
            if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        }
        return result
    }

    /// Repair whitespace at the removed annotation only. Newlines and spacing
    /// elsewhere, including indentation on the affected line, stay byte-for-byte.
    private static func removeMatchesPreservingLayout(
        _ expression: NSRegularExpression,
        from text: String,
        matching predicate: (String) -> Bool = { _ in true }
    ) -> String {
        let source = text as NSString
        let result = NSMutableString(string: text)
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: source.length))
        for match in matches.reversed() where predicate(source.substring(with: match.range)) {
            var start = match.range.location
            var end = NSMaxRange(match.range)
            while start > 0, isHorizontalSpace(result.character(at: start - 1)) { start -= 1 }
            while end < result.length, isHorizontalSpace(result.character(at: end)) { end += 1 }
            let atLineStart = start == 0 || isLineBreak(result.character(at: start - 1))
            let atLineEnd = end == result.length || isLineBreak(result.character(at: end))
            let beforePunctuation = end < result.length && ",.;:!?".utf16.contains(result.character(at: end))
            let replacement: String
            if atLineStart && !atLineEnd {
                replacement = result.substring(with: NSRange(location: start, length: match.range.location - start))
            } else if atLineEnd || beforePunctuation {
                replacement = ""
            } else {
                replacement = " "
            }
            result.replaceCharacters(in: NSRange(location: start, length: end - start), with: replacement)
        }
        return result as String
    }

    private static func isHorizontalSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    private static func isLineBreak(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D
    }

    /// Applies `apply(_:)` to each segment's text and drops segments left empty.
    /// Meeting transcripts are built from segments, so they need the same cleanup as the joined text.
    static func apply(to segments: [SpeechSegment], preservingLayout: Bool = false) -> [SpeechSegment] {
        segments.compactMap { segment in
            let text = preservingLayout ? applyPreservingLayout(segment.text) : apply(segment.text)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text == segment.text ? segment : SpeechSegment(start: segment.start, end: segment.end, text: text)
        }
    }

    private static func stripPromptLeakage(from text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text
        for pattern in promptLeakPatterns {
            result = replaceAnchoredPromptLeak(in: result, pattern: pattern, anchorAtStart: true)
            result = replaceAnchoredPromptLeak(in: result, pattern: pattern, anchorAtStart: false)
        }

        return normalizeSpacing(result)
    }

    private static func normalizeSpacing(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceAnchoredPromptLeak(in text: String, pattern: String, anchorAtStart: Bool) -> String {
        let anchoredPattern = anchorAtStart
            ? #"^\s*(?:"# + pattern + #")(?:\s+|$)"#
            : #"(?:^|\s+)(?:"# + pattern + #")\s*$"#
        return text.replacingOccurrences(of: anchoredPattern, with: " ", options: .regularExpression)
    }
}
