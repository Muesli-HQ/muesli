import FluidAudio
import Foundation
import MuesliCore

enum TranscriptFormatter {
    /// Backward-compatible merge without diarization.
    static func merge(micSegments: [SpeechSegment], systemSegments: [SpeechSegment], meetingStart: Date) -> String {
        merge(micSegments: micSegments, systemSegments: systemSegments, diarizationSegments: nil, meetingStart: meetingStart)
    }

    /// Merge with optional speaker diarization for system audio and, for
    /// in-person meetings, for the microphone channel.
    static func merge(
        micSegments: [SpeechSegment],
        systemSegments: [SpeechSegment],
        diarizationSegments: [TimedSpeakerSegment]?,
        micDiarizationSegments: [TimedSpeakerSegment]? = nil,
        meetingStart: Date,
        conservativeSpeakerAttribution: Bool = false,
        systemSegmentsAreTokenTimed: Bool = false
    ) -> String {
        // The formatter is intentionally source-agnostic: upstream capture decides
        // which mic/system segments are valid, then this layer only labels/merges.
        let displayMicSegments = micSegments
        let taggedMic: [TaggedSegment]
        // A single mic voice is almost always the device owner on a call; only
        // split the mic channel when the room had several significant voices.
        // Same rule as the reconciler, so turns it kept apart get distinct labels.
        if let localDiarization = SpeakerAttribution.localDiarization(from: micDiarizationSegments) {
            let micSpeakerLabelMap = speakerLabelMap(for: localDiarization, prefix: "Local speaker")
            taggedMic = displayMicSegments.map { segment in
                let speaker = findSpeaker(
                    for: segment,
                    in: localDiarization,
                    labelMap: micSpeakerLabelMap,
                    fallback: "Local speaker"
                )
                return TaggedSegment(segment: segment, speaker: speaker)
            }
        } else {
            taggedMic = displayMicSegments.map { TaggedSegment(segment: $0, speaker: "You") }
        }

        let taggedSystem: [TaggedSegment]
        if let diarizationSegments, !diarizationSegments.isEmpty {
            let speakerLabelMap = speakerLabelMap(for: diarizationSegments, prefix: "Speaker")

            // Only token-timed input holds word fragments. Completed chunks are
            // trimmed, so neighboring replies would look like fragments of one word.
            let lexicalUnits = systemSegmentsAreTokenTimed
                ? normalizeLexicalUnits(systemSegments)
                : systemSegments.map { LexicalUnit(segment: $0, isReconstructedWord: false) }
            taggedSystem = lexicalUnits.map { unit in
                let speaker: String
                if !conservativeSpeakerAttribution {
                    speaker = findSpeaker(for: unit.segment, in: diarizationSegments, labelMap: speakerLabelMap, fallback: "Others")
                } else if unit.isReconstructedWord {
                    // A word rebuilt from token timings is narrow enough for
                    // overlap attribution, unlike a broad ASR window.
                    speaker = findSpeaker(for: unit.segment, in: diarizationSegments, labelMap: speakerLabelMap, fallback: "Unknown speaker")
                } else {
                    speaker = recordedSpeaker(for: unit.segment, in: diarizationSegments, labelMap: speakerLabelMap)
                }
                return TaggedSegment(segment: unit.segment, speaker: speaker)
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

    /// Raw diarizer ID → "<prefix> 1", "<prefix> 2", … in first-appearance order.
    private static func speakerLabelMap(
        for diarizationSegments: [TimedSpeakerSegment],
        prefix: String
    ) -> [String: String] {
        var labelMap: [String: String] = [:]
        var nextSpeakerNumber = 1
        for seg in diarizationSegments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            if labelMap[seg.speakerId] == nil {
                labelMap[seg.speakerId] = "\(prefix) \(nextSpeakerNumber)"
                nextSpeakerNumber += 1
            }
        }
        return labelMap
    }

    /// Merge consecutive segments from the same speaker into single entries,
    /// but only when they're temporally close (within 2s). This prevents
    /// token-level fragmentation while preserving chronological ordering —
    /// segments from the same speaker that are far apart in time stay separate
    /// so they interleave correctly with other speakers.
    private static let consolidationGapThreshold: TimeInterval = 2.0
    private static let lexicalFragmentGapThreshold: TimeInterval = 0.35

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
    private static func recordedSpeaker(
        for segment: SpeechSegment,
        in diarizationSegments: [TimedSpeakerSegment],
        labelMap: [String: String]
    ) -> String {
        // File ASR may only provide window-level timestamps. Do not invent word
        // alignment or assign a mixed-speaker window entirely to its loudest voice.
        let speakers = Set(diarizationSegments.filter {
            min(Double($0.endTimeSeconds), segment.end) > max(Double($0.startTimeSeconds), segment.start)
        }.map(\.speakerId))
        if speakers.count > 1 { return "Multiple speakers" }
        guard let id = speakers.first else { return "Unknown speaker" }
        return labelMap[id] ?? "Unknown speaker"
    }

    private static func findSpeaker(
        for segment: SpeechSegment,
        in diarizationSegments: [TimedSpeakerSegment],
        labelMap: [String: String],
        fallback: String
    ) -> String {
        if labelMap.count == 1 {
            return labelMap.values.first ?? fallback
        }
        guard let speakerID = SpeakerAttribution.speakerID(for: segment, in: diarizationSegments) else {
            return fallback
        }
        return labelMap[speakerID] ?? fallback
    }

    private struct LexicalUnit {
        let segment: SpeechSegment
        let isReconstructedWord: Bool
    }

    /// Reassembles token-timed ASR fragments before speaker attribution so a
    /// diarization boundary cannot split one lexical word across speaker turns.
    private static func normalizeLexicalUnits(_ segments: [SpeechSegment]) -> [LexicalUnit] {
        let chronologicalSegments = segments.sorted { $0.start < $1.start }
        guard let first = chronologicalSegments.first else { return [] }

        var result: [LexicalUnit] = []
        var current = first
        var combined = false

        func finishCurrent() {
            let isSingleWord = !current.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .contains(where: \.isWhitespace)
            result.append(LexicalUnit(segment: current, isReconstructedWord: combined && isSingleWord))
        }

        for segment in chronologicalSegments.dropFirst() {
            let gap = max(0, segment.start - current.end)
            if shouldCombineIntoLexicalUnit(current.text, segment.text, gap: gap) {
                // Attached punctuation says nothing about the word's timing, so
                // only joined word fragments earn overlap attribution.
                let isWordFragmentJoin = !isPunctuationOnly(current.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    && !isPunctuationOnly(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                current = SpeechSegment(
                    start: current.start,
                    end: max(current.end, segment.end),
                    text: current.text + segment.text
                )
                combined = combined || isWordFragmentJoin
            } else {
                finishCurrent()
                current = segment
                combined = false
            }
        }

        finishCurrent()
        return result
    }

    private static func shouldCombineIntoLexicalUnit(
        _ lhs: String,
        _ rhs: String,
        gap: TimeInterval
    ) -> Bool {
        let trimmedLHS = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRHS = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLHS.isEmpty, !trimmedRHS.isEmpty else { return false }

        guard gap <= lexicalFragmentGapThreshold else { return false }

        // A sign that opens a word stays with that word, not the one before it.
        if isPunctuationOnly(trimmedRHS), rhs.first?.isWhitespace == true {
            return false
        }

        if isPunctuationOnly(trimmedLHS) || isPunctuationOnly(trimmedRHS) {
            return true
        }

        guard let lhsLast = lhs.last, let rhsFirst = rhs.first else { return false }
        guard !lhsLast.isWhitespace, !rhsFirst.isWhitespace, !lhsLast.isPunctuation else {
            return false
        }

        return !trimmedLHS.contains(where: \.isWhitespace)
            && !trimmedRHS.contains(where: \.isWhitespace)
    }

    private static func isPunctuationOnly(_ text: String) -> Bool {
        text.allSatisfy { $0.isPunctuation || $0.isSymbol }
    }

    private static func appendText(_ lhs: String, _ rhs: String, gap: TimeInterval) -> String {
        if shouldConcatenateDirectly(lhs, rhs, gap: gap) {
            return lhs + rhs
        }
        return joinText(lhs, rhs)
    }

    private static func shouldConcatenateDirectly(_ lhs: String, _ rhs: String, gap: TimeInterval) -> Bool {
        guard gap <= lexicalFragmentGapThreshold else { return false }
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
