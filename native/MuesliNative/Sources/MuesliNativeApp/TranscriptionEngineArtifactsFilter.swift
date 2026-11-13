import Foundation

/// Removes known model hallucination artifacts emitted on silence or blank input.
/// Applied as post-processing after ASR, before filler word filtering.
public struct TranscriptionEngineArtifactsFilter {

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
        normalizeSpacing(stableRecognitionPrefix(stripCues(text, holdUnfinished: true)))
    }

    static func applyToPartialText(_ text: String) -> String {
        apply(stripCues(text, holdUnfinished: true, removeComplete: false))
    }

    private static let artifactPatterns: [String] = [
        #"(?i)\[\s*(?:blank[_\s-]*audio|no[_\s-]*speech|silence|inaudible|music|applause|laughter|screaming|cheering)\s*\]"#,
        #"(?i)[\[(<]\s*(?:speaking\s+in\s+)?(?:a\s+)?foreign\s+language\s*[\])>]"#,
        #"(?i)<\s*(?:eou|eob|unk|blank|pad)\s*>"#,
    ]

    // Named controls from the Cohere and Whisper decoders, including Whisper's
    // 20 ms timestamps (0.00 through 30.00). Preserve arbitrary pipe-delimited tags.
    private static let controlTokens: NSRegularExpression = {
        let controls = ["nospeech", "nocaptions", "startofcontext", "startoftranscript",
                        "startofprev", "endoftext", "notimestamp", "notimestamps", "nodiarize",
                        "pnc", "noitn", "emo:undefined", "transcribe", "translate"]
        let languages = WhisperKitLanguage.allCases.filter { $0 != .auto }.map(\.rawValue)
        let names = (controls + languages).map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = #"<\|(?:"# + names + #"|(?:[0-9]|[12][0-9])\.[0-9][02468]|30\.00)\|>"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    // Issue #754 reports an ordinary subword sequence, not a reserved token ID.
    // Only the uppercase standalone spelling is evidence of the placeholder.
    private static let redacted = try! NSRegularExpression(pattern: #"(?<![\w<>\[\]|/-])REDACTED(?![\w<>\[\]|/-])"#)
    private static let repeatedWords = try! NSRegularExpression(
        pattern: #"(?<!\S)([\p{L}\p{M}\p{N}]+(?:[ \t]+[\p{L}\p{M}\p{N}]+){0,2}?)(?:[ \t]+\1){8,}(?=[\s.,!?;:]|$)"#
    )

    // The first word(s) of a ninth phrase may arrive in a separate streaming
    // update. Hold them until they complete the loop or diverge from it.
    static func stableRecognitionPrefix(_ text: String) -> String {
        let clean = cleanRecognitionArtifacts(text)
        let words = clean.split(whereSeparator: \.isWhitespace).suffix(26)
        let tail = Array(words)
        // The cap is eight phrases of up to three words, plus an unfinished pair.
        for width in 2...3 {
            for pending in 1..<width where tail.count >= width * 8 + pending {
                let start = tail.count - width * 8 - pending
                let phrase = tail[start..<(start + width)]
                if tail[start...].enumerated().allSatisfy({ index, word in word == phrase[start + index % width] }) {
                    return String(clean[..<tail[tail.count - pending].startIndex])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return clean
    }

    /// Only run on recognized speech, before user dictionaries or formatting.
    public static func cleanRecognitionArtifacts(_ text: String) -> String {
        let withoutControls = removeMatchesPreservingLayout(controlTokens, from: text)
        let result = removeMatchesPreservingLayout(redacted, from: withoutControls)
        if result != text && result.allSatisfy({ $0.isWhitespace || $0.isPunctuation }) { return "" }
        let source = result as NSString
        let matches = repeatedWords.matches(in: result, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return result }
        let bounded = NSMutableString(string: result)
        for match in matches.reversed() {
            let phrase = source.substring(with: match.range(at: 1))
            let kept = Array(repeating: phrase, count: 8).joined(separator: " ")
            bounded.replaceCharacters(in: match.range, with: kept)
        }
        return bounded as String
    }

    private static let promptLeakPatterns: [String] = [
        #"(?i)\btranscribe the spoken audio accurately\.?"#,
        #"(?i)\bif a word is unclear,?\s*use the most likely word that fits well within the context of the overall sentence(?:\s+transcription)?\.?"#,
    ]

    /// Removes known engine control tokens and non-speech annotations, then strips
    /// prompt leakage while preserving ordinary transcript text.
    static func apply(_ text: String) -> String {
        var stripped = cleanRecognitionArtifacts(stripCues(text, holdUnfinished: false))
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
        result = removeMatchesPreservingLayout(controlTokens, from: result)
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
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        let result = NSMutableString(string: text)
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
