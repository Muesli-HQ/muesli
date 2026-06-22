import Foundation

/// Builds a readable transcript string with inline `[HH:MM:SS]` markers from
/// single-speaker ASR segments. Lines break at sentence boundaries (., ?, !)
/// or when a line grows past `maxLineWords`, so the transcript view renders
/// readable bubbles rather than one wall of text.
enum InlineTranscriptFormatter {
    private static let maxLineWords = 40

    /// - `startOffsetSeconds`: added to every label so the markers read as
    ///   wall-clock time-of-day. Live recordings pass the meeting's start
    ///   time-of-day (matching `TranscriptFormatter.merge`); imports pass 0 so
    ///   their markers stay elapsed media time. Subtitle export keys its rebase
    ///   off the meeting source, so the two conventions must stay aligned.
    static func timestampedTranscript(from segments: [SpeechSegment],
                                      startOffsetSeconds: Double = 0) -> String {
        let usable = segments
            .map { SpeechSegment(start: $0.start, end: $0.end,
                                 text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
        guard !usable.isEmpty else { return "" }

        var lines: [String] = []
        var lineStart: Double = usable[0].start
        var lineWords: [String] = []

        func flush() {
            guard !lineWords.isEmpty else { return }
            let label = SubtitleTimecode.inlineLabel(seconds: lineStart + startOffsetSeconds)
            lines.append("[\(label)] \(lineWords.joined(separator: " "))")
            lineWords.removeAll(keepingCapacity: true)
        }

        for segment in usable {
            if lineWords.isEmpty { lineStart = segment.start }
            let words = segment.text.split(whereSeparator: { $0 == " " }).map(String.init)
            lineWords.append(contentsOf: words)

            let endsSentence = segment.text.last.map { ".?!".contains($0) } ?? false
            if endsSentence || lineWords.count >= maxLineWords {
                flush()
            }
        }
        flush()
        return lines.joined(separator: "\n")
    }

    /// Decides what text to persist as `rawTranscript`.
    /// - `multiSpeakerText`: non-nil when diarization produced multi-speaker,
    ///   already-timestamped text — use it verbatim.
    /// - else build timestamped lines from VAD-timed `segments`.
    /// - else fall back to `fallbackText` (e.g. joined region text).
    /// NOTE: in production both call sites pass `multiSpeakerText: nil`; the
    /// multi-speaker result is applied downstream by reassigning
    /// `diarizedTranscript` after diarization runs. The parameter exists so this
    /// selection policy stays unit-testable in one place.
    static func transcriptForStorage(
        segments: [SpeechSegment],
        multiSpeakerText: String?,
        fallbackText: String,
        startOffsetSeconds: Double = 0
    ) -> String {
        if let multiSpeakerText, !multiSpeakerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return multiSpeakerText
        }
        let timestamped = timestampedTranscript(from: segments, startOffsetSeconds: startOffsetSeconds)
        return timestamped.isEmpty ? fallbackText : timestamped
    }
}
