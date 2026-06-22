import Foundation

/// Re-groups timestamped transcript lines into short subtitle cues.
/// Subtitle convention: a cue should be quick to read — we cap each cue at
/// `maxWords` and split longer lines, interpolating time linearly across the
/// line's [start, nextStart) span.
enum SubtitleSegmenter {
    private static let secondsPerDay: Double = 86_400

    static func cues(
        from lines: [ParsedTranscriptLine],
        totalDuration: Double,
        isWallClock: Bool,
        wallClockOrigin: Double? = nil,
        maxWords: Int = 7,
        minCueDuration: Double = 0.4,
        tailSeconds: Double = 2.0
    ) -> [SubtitleCue] {
        guard !lines.isEmpty else { return [] }

        // Live recordings (MeetingSource.meeting / .iOS) store WALL-CLOCK
        // time-of-day markers (e.g. 14:30:05, or 00:01:04 for a meeting started
        // just after midnight) rather than elapsed media time.
        //
        // Imported media (.audioImport) is the opposite: its markers are already
        // elapsed media time (single-speaker uses elapsed-from-zero; multi-speaker
        // diarization anchors at startOfDay, i.e. midnight, which is also elapsed).
        // Its speech may legitimately start at a large offset (a 1h recording
        // silent until 30:00), so it must NEVER be rebased — the offset is real.
        //
        // The two are numerically indistinguishable (a live meeting at 00:30 and
        // an import with first speech at 30:00 both read [00:30:00]). Speaker
        // labels don't separate them either — diarized imports also carry
        // Speaker N: labels. Only the meeting's source reliably tells them apart,
        // so the caller passes it in as `isWallClock`.
        //
        // For live recordings the rebase origin is the meeting's START time-of-day
        // (`wallClockOrigin`), NOT the first spoken marker. Anchoring on first
        // speech would drop any leading silence (meeting starts 14:30, first words
        // 14:35 -> [14:35:00] must map to media 300s, not 0). The markers are
        // formatted through DateFormatter "HH:mm:ss", so a meeting crossing
        // midnight produces a decreasing run ([23:59:58] then [00:00:02]). It can
        // also start before midnight while its FIRST spoken marker is already past
        // midnight (origin 23:55, first speech 00:05 -> 300s) with no earlier line
        // to reveal the wrap. `unwrapMidnight` handles both by lifting any marker
        // more than half a day below a running reference (seeded with the origin)
        // onto the next day, then we subtract the origin. When the origin is
        // unknown (unparseable start), fall back to the smallest marker so cues at
        // least begin near zero.
        var working = lines
        if isWallClock {
            working = unwrapMidnight(lines, origin: wallClockOrigin)
            let origin = wallClockOrigin ?? (working.map(\.startSeconds).min() ?? 0)
            if origin != 0 {
                working = working.map {
                    ParsedTranscriptLine(startSeconds: $0.startSeconds - origin, text: $0.text)
                }
            }
        }
        let lines = working

        var cues: [SubtitleCue] = []
        var index = 1
        // Whole-second rounding can make consecutive lines share a start time.
        // Track the previous cue's end as a cursor so emitted cues never overlap
        // and their starts are non-decreasing, across both whole-line cues and
        // the split sub-cues of a long line.
        var cursor = 0.0

        for (i, line) in lines.enumerated() {
            let lineStart = line.startSeconds
            let nextStart = (i + 1 < lines.count)
                ? lines[i + 1].startSeconds
                : (totalDuration > lineStart ? totalDuration : lineStart + tailSeconds)
            let lineEnd = max(nextStart, lineStart + minCueDuration)

            let words = line.text.split(whereSeparator: { $0 == " " }).map(String.init)
            guard !words.isEmpty else { continue }

            let groups = stride(from: 0, to: words.count, by: maxWords).map { start -> [String] in
                Array(words[start..<min(start + maxWords, words.count)])
            }
            let span = lineEnd - lineStart
            let totalWords = Double(words.count)
            var consumed = 0
            for group in groups {
                let startFraction = Double(consumed) / totalWords
                consumed += group.count
                let endFraction = Double(consumed) / totalWords
                let start = max(lineStart + span * startFraction, cursor)
                let end = max(lineStart + span * endFraction, start + minCueDuration)
                cues.append(SubtitleCue(
                    index: index,
                    start: start,
                    end: end,
                    text: group.joined(separator: " ")
                ))
                cursor = end
                index += 1
            }
        }
        return cues
    }

    /// Live wall-clock markers are formatted HH:mm:ss, so a meeting crossing
    /// midnight wraps to a decreasing run. Restore monotonic time by lifting a
    /// marker onto the next day whenever it sits more than half a day below a
    /// running reference. The reference is seeded with the meeting's start
    /// `origin`, so a first spoken marker already past midnight is caught even
    /// though no earlier line exposes the wrap; thereafter it tracks the running
    /// max so later wrapped lines stay ordered. The half-day tolerance is the key
    /// invariant: a genuine midnight wrap is a ~24h backward step, while clock
    /// skew is at most seconds — only the former crosses the tolerance, so skew is
    /// left to clamp near zero instead of being misread as a 24h jump. When the
    /// origin is unknown the first marker seeds the reference (no lift on it).
    private static func unwrapMidnight(_ lines: [ParsedTranscriptLine],
                                       origin: Double?) -> [ParsedTranscriptLine] {
        let tolerance = secondsPerDay / 2
        var dayOffset: Double = 0
        var reference: Double = origin ?? -.greatestFiniteMagnitude
        return lines.map { line in
            var seconds = line.startSeconds + dayOffset
            if seconds < reference - tolerance {
                dayOffset += secondsPerDay
                seconds += secondsPerDay
            }
            reference = max(reference, seconds)
            return ParsedTranscriptLine(startSeconds: seconds, text: line.text)
        }
    }
}
