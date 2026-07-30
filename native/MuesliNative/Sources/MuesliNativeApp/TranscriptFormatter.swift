import FluidAudio
import Foundation
import MuesliCore

extension MeetingRecord {
    /// Transcript with the user's speaker renames applied. Use this everywhere
    /// the transcript is shown, exported, or summarized; `rawTranscript` keeps
    /// the canonical diarization labels the parser and Insights rely on.
    ///
    /// Lives here rather than on `MeetingRecord` in MuesliCore because the
    /// substitution belongs to `TranscriptFormatter`, which is app-layer.
    var displayTranscript: String {
        TranscriptFormatter.applying(names: speakerNames, to: rawTranscript)
    }
}

enum TranscriptFormatter {
    /// Backward-compatible merge without diarization.
    static func merge(micSegments: [SpeechSegment], systemSegments: [SpeechSegment], meetingStart: Date) -> String {
        merge(micSegments: micSegments, systemSegments: systemSegments, diarizationSegments: nil, meetingStart: meetingStart)
    }

    /// Merge with optional speaker diarization for system audio.
    static func merge(
        micSegments: [SpeechSegment],
        systemSegments: [SpeechSegment],
        diarizationSegments: [TimedSpeakerSegment]?,
        meetingStart: Date
    ) -> String {
        // The formatter is intentionally source-agnostic: upstream capture decides
        // which mic/system segments are valid, then this layer only labels/merges.
        let displayMicSegments = micSegments
        let taggedMic = displayMicSegments.map { TaggedSegment(segment: $0, speaker: "You") }

        let taggedSystem: [TaggedSegment]
        if let diarizationSegments, !diarizationSegments.isEmpty {
            let speakerLabelMap = speakerLabels(for: diarizationSegments)

            taggedSystem = systemSegments.map { segment in
                let speaker = findSpeaker(for: segment, in: diarizationSegments, labelMap: speakerLabelMap)
                return TaggedSegment(segment: segment, speaker: speaker)
            }
        } else {
            taggedSystem = systemSegments.map { TaggedSegment(segment: $0, speaker: "Others") }
        }

        let tagged = (taggedMic + taggedSystem).sorted { $0.segment.start < $1.segment.start }

        // Consolidate consecutive segments from the same speaker into single lines
        let consolidated = consolidate(tagged)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"

        return consolidated.map { taggedSegment in
            let timestamp = meetingStart.addingTimeInterval(taggedSegment.segment.start)
            let text = taggedSegment.segment.text.trimmingCharacters(in: .whitespaces)
            return "[\(formatter.string(from: timestamp))] \(taggedSegment.speaker): \(text)"
        }.joined(separator: "\n")
    }

    /// Maps each diarizer speaker id to its canonical label, numbered in
    /// first-appearance order. Callers that need to tie a label back to the
    /// voice behind it (to enroll or recognize a speaker) use the same map.
    static func speakerLabels(for diarizationSegments: [TimedSpeakerSegment]) -> [String: String] {
        var speakerLabelMap: [String: String] = [:]
        var nextSpeakerNumber = 1
        for seg in diarizationSegments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            if speakerLabelMap[seg.speakerId] == nil {
                speakerLabelMap[seg.speakerId] = "Speaker \(nextSpeakerNumber)"
                nextSpeakerNumber += 1
            }
        }
        return speakerLabelMap
    }

    /// Canonical diarization labels the user is allowed to rename.
    static func isRenameableSpeaker(_ speaker: String) -> Bool {
        speaker.range(of: #"^Speaker\s+\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whether a user-supplied speaker name is safe to store. An empty name is
    /// valid and means "reset to the canonical label". Names that would shadow a
    /// canonical label, or contain a colon and so break line-anchored parsing,
    /// are rejected.
    static func isValidSpeakerName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.localizedCaseInsensitiveCompare("You") == .orderedSame { return false }
        if trimmed.localizedCaseInsensitiveCompare("Others") == .orderedSame { return false }
        return !isRenameableSpeaker(trimmed) && !trimmed.contains(":")
    }

    /// Rewrites canonical `Speaker N:` line labels to user-chosen names.
    ///
    /// The stored transcript always keeps canonical labels; names live in a
    /// separate map so a rename never has to rewrite (or fight with hand-edits
    /// to) the transcript itself. The match is anchored to the start of a line
    /// and to the timestamp prefix, so body text can never be rewritten.
    static func applying(names: [String: String], to transcript: String) -> String {
        guard !names.isEmpty else { return transcript }
        return transcript.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let labelRange = line.range(
                of: #"^\[\d{2}:\d{2}:\d{2}\] Speaker\s+\d+: "#,
                options: [.regularExpression, .caseInsensitive]
            ) else { return String(line) }
            let label = line[labelRange]
            guard let separator = label.range(of: "] "),
                  let colon = label.range(of: ": ", options: .backwards) else { return String(line) }
            let speaker = String(label[separator.upperBound..<colon.lowerBound])
            guard let name = names[speaker], !name.isEmpty else { return String(line) }
            return "\(label[..<separator.upperBound])\(name): \(line[labelRange.upperBound...])"
        }.joined(separator: "\n")
    }

    /// Merge consecutive segments from the same speaker into single entries,
    /// but only when they're temporally close (within 2s). This prevents
    /// token-level fragmentation while preserving chronological ordering —
    /// segments from the same speaker that are far apart in time stay separate
    /// so they interleave correctly with other speakers.
    private static let consolidationGapThreshold: TimeInterval = 2.0

    private static func consolidate(_ segments: [TaggedSegment]) -> [TaggedSegment] {
        guard !segments.isEmpty else { return [] }

        var result: [TaggedSegment] = []
        var currentSpeaker = segments[0].speaker
        var currentStart = segments[0].segment.start
        var currentEnd = segments[0].segment.end
        var currentText = segments[0].segment.text

        for seg in segments.dropFirst() {
            let gap = max(0, seg.segment.start - currentEnd)
            if seg.speaker == currentSpeaker && gap <= consolidationGapThreshold {
                // Same speaker, temporally close — accumulate text
                currentText = appendText(currentText, seg.segment.text, gap: gap)
                currentEnd = max(currentEnd, seg.segment.end)
            } else {
                // Different speaker or too far apart — emit and start new segment
                result.append(TaggedSegment(
                    segment: SpeechSegment(start: currentStart, end: currentEnd, text: currentText),
                    speaker: currentSpeaker
                ))
                currentSpeaker = seg.speaker
                currentStart = seg.segment.start
                currentEnd = seg.segment.end
                currentText = seg.segment.text
            }
        }
        // Emit last segment
        result.append(TaggedSegment(
            segment: SpeechSegment(start: currentStart, end: currentEnd, text: currentText),
            speaker: currentSpeaker
        ))

        return result
    }

    /// Find the best-matching speaker for an ASR segment by time overlap with diarization segments.
    private static func findSpeaker(
        for segment: SpeechSegment,
        in diarizationSegments: [TimedSpeakerSegment],
        labelMap: [String: String]
    ) -> String {
        if labelMap.count == 1 {
            return labelMap.values.first ?? "Others"
        }

        let segStart = Float(segment.start)
        let segEnd = Float(max(segment.end, segment.start + 0.1)) // ensure non-zero duration

        var bestOverlap: Float = 0
        var bestSpeakerId: String?

        for diarSeg in diarizationSegments {
            let overlapStart = max(segStart, diarSeg.startTimeSeconds)
            let overlapEnd = min(segEnd, diarSeg.endTimeSeconds)
            let overlap = max(0, overlapEnd - overlapStart)

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeakerId = diarSeg.speakerId
            }
        }

        if let bestSpeakerId, bestOverlap > 0 {
            return labelMap[bestSpeakerId] ?? "Others"
        }

        if let nearestSpeakerId = nearestSpeaker(
            for: segment,
            in: diarizationSegments,
            maxGapSeconds: 2.0
        ) {
            return labelMap[nearestSpeakerId] ?? "Others"
        }
        return "Others"
    }


    private static func nearestSpeaker(
        for segment: SpeechSegment,
        in diarizationSegments: [TimedSpeakerSegment],
        maxGapSeconds: Float
    ) -> String? {
        let segStart = Float(segment.start)
        let segEnd = Float(max(segment.end, segment.start + 0.1))
        let segMidpoint = (segStart + segEnd) / 2

        let nearest = diarizationSegments.min { lhs, rhs in
            temporalGap(between: segMidpoint, and: lhs) < temporalGap(between: segMidpoint, and: rhs)
        }

        guard let nearest else { return nil }
        return temporalGap(between: segMidpoint, and: nearest) <= maxGapSeconds ? nearest.speakerId : nil
    }

    private static func temporalGap(
        between point: Float,
        and diarizationSegment: TimedSpeakerSegment
    ) -> Float {
        if point < diarizationSegment.startTimeSeconds {
            return diarizationSegment.startTimeSeconds - point
        }
        if point > diarizationSegment.endTimeSeconds {
            return point - diarizationSegment.endTimeSeconds
        }
        return 0
    }

    private static func appendText(_ lhs: String, _ rhs: String, gap: TimeInterval) -> String {
        if shouldConcatenateDirectly(lhs, rhs, gap: gap) {
            return lhs + rhs
        }
        return joinText(lhs, rhs)
    }

    private static func shouldConcatenateDirectly(_ lhs: String, _ rhs: String, gap: TimeInterval) -> Bool {
        guard gap <= 0.35 else { return false }
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        guard !rhs.contains(where: \.isWhitespace) else { return false }
        guard let lhsLast = lhs.last, let rhsFirst = rhs.first else { return false }
        guard !lhsLast.isWhitespace, !rhsFirst.isWhitespace, !rhsFirst.isPunctuation else { return false }

        let lhsLastToken = lhs.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? lhs
        guard !lhsLastToken.contains(where: \.isWhitespace) else { return false }

        let lhsVisibleLength = visibleLength(of: lhsLastToken)
        let rhsVisibleLength = visibleLength(of: rhs)
        return lhsVisibleLength + rhsVisibleLength <= 8
    }

    private static func joinText(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        guard let lhsLast = lhs.last, let rhsFirst = rhs.first else {
            return lhs + rhs
        }

        if lhsLast.isWhitespace || rhsFirst.isWhitespace || rhsFirst.isPunctuation {
            return lhs + rhs
        }

        if lhsLast.isPunctuation {
            return lhs + " " + rhs
        }

        return lhs + " " + rhs
    }

    private static func visibleLength(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + (CharacterSet.whitespacesAndNewlines.contains(scalar) ? 0 : 1)
        }
    }

}

private struct TaggedSegment {
    let segment: SpeechSegment
    let speaker: String
}
