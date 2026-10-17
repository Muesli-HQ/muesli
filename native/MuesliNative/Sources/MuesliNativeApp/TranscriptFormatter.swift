import FluidAudio
import Foundation
import MuesliCore

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
        meetingStart: Date,
        conservativeSpeakerAttribution: Bool = false
    ) -> String {
        structured(micSegments: micSegments, systemSegments: systemSegments,
                   diarizationSegments: diarizationSegments, meetingStart: meetingStart,
                   conservativeSpeakerAttribution: conservativeSpeakerAttribution).render()
    }

    static func structured(
        micSegments: [SpeechSegment], systemSegments: [SpeechSegment],
        diarizationSegments: [TimedSpeakerSegment]?, meetingStart: Date,
        conservativeSpeakerAttribution: Bool = false, epoch: UUID = UUID(),
        systemChannel: MeetingSpeakerKey.Channel = .system,
        preserveSegmentBoundaries: Bool = false,
        accessibilitySpeakerNamingEnabled: Bool = false
    ) -> MeetingSpeakerState {
        let useConservativeAttribution = conservativeSpeakerAttribution || accessibilitySpeakerNamingEnabled
        var identities: [String: MeetingSpeaker] = [:]
        let micKey = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "source")
        if !micSegments.isEmpty {
            identities["You"] = MeetingSpeaker(key: micKey, rank: 1, fallbackLabel: "You", isSelf: true)
        }
        // The formatter is intentionally source-agnostic: upstream capture decides
        // which mic/system segments are valid, then this layer only labels/merges.
        let displayMicSegments = micSegments
        let taggedMic = displayMicSegments.map { TaggedSegment(segment: $0, speaker: "You") }

        let taggedSystem: [TaggedSegment]
        if let diarizationSegments, !diarizationSegments.isEmpty {
            // Build speaker label map: raw ID → "Speaker 1", "Speaker 2", etc. in first-appearance order
            var speakerLabelMap: [String: String] = [:]
            var nextSpeakerNumber = 1
            for seg in diarizationSegments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
                if speakerLabelMap[seg.speakerId] == nil {
                    let label = "Speaker \(nextSpeakerNumber)"
                    speakerLabelMap[seg.speakerId] = label
                    identities[label] = MeetingSpeaker(
                        key: .init(epoch: epoch, channel: systemChannel, clusterID: seg.speakerId),
                        rank: nextSpeakerNumber + 1, fallbackLabel: label)
                    nextSpeakerNumber += 1
                }
            }

            taggedSystem = systemSegments.map { segment in
                let speaker = useConservativeAttribution
                    ? recordedSpeaker(for: segment, in: diarizationSegments, labelMap: speakerLabelMap)
                    : findSpeaker(for: segment, in: diarizationSegments, labelMap: speakerLabelMap)
                let overlappingSpeakers = Set(diarizationSegments.filter {
                    min(Double($0.endTimeSeconds), segment.end) > max(Double($0.startTimeSeconds), segment.start)
                }.map(\.speakerId))
                return TaggedSegment(segment: segment, speaker: speaker, sampleEligible: overlappingSpeakers.count <= 1)
            }
        } else {
            taggedSystem = systemSegments.map { TaggedSegment(segment: $0, speaker: "Others") }
        }

        let tagged = (taggedMic + taggedSystem).sorted { $0.segment.start < $1.segment.start }

        // Consolidate consecutive segments from the same speaker into single lines
        let consolidated = consolidate(tagged, preserveSegmentBoundaries: preserveSegmentBoundaries)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"

        // Aggregate/source placeholders retain provenance without inventing a person.
        for label in Set(consolidated.map(\.speaker)).sorted() where identities[label] == nil {
            identities[label] = MeetingSpeaker(
                key: .init(epoch: epoch, channel: systemChannel, clusterID: "aggregate:\(label)"),
                rank: identities.count + 2, fallbackLabel: label, isAssignable: false)
        }
        let sampleValidated = consolidated.map { taggedSegment -> TaggedSegment in
            guard let identity = identities[taggedSegment.speaker],
                  diarizationSegments?.contains(where: { diarization in
                      let overlaps = min(Double(diarization.endTimeSeconds), taggedSegment.segment.end)
                          > max(Double(diarization.startTimeSeconds), taggedSegment.segment.start)
                      guard overlaps else { return false }
                      if identity.key.channel == .microphone { return true }
                      return identity.key.channel == systemChannel && diarization.speakerId != identity.key.clusterID
                  }) == true else { return taggedSegment }
            return TaggedSegment(segment: taggedSegment.segment, speaker: taggedSegment.speaker, sampleEligible: false)
        }
        let turns = sampleValidated.compactMap { taggedSegment -> MeetingSpeakerTurn? in
            guard let identity = identities[taggedSegment.speaker] else { return nil }
            var turn = MeetingSpeakerTurn(speaker: identity.key,
                timestamp: formatter.string(from: meetingStart.addingTimeInterval(taggedSegment.segment.start)),
                start: taggedSegment.segment.start, end: taggedSegment.segment.end,
                text: taggedSegment.segment.text.trimmingCharacters(in: .whitespaces))
            if !taggedSegment.sampleEligible { turn.sampleEligible = false }
            return turn
        }
        return MeetingSpeakerState(epoch: epoch,
            speakers: identities.values.sorted { $0.rank < $1.rank }, turns: turns)
    }

    /// Merge consecutive segments from the same speaker into single entries,
    /// but only when they're temporally close (within 2s). This prevents
    /// token-level fragmentation while preserving chronological ordering —
    /// segments from the same speaker that are far apart in time stay separate
    /// so they interleave correctly with other speakers.
    private static let consolidationGapThreshold: TimeInterval = 2.0

    private static func consolidate(
        _ segments: [TaggedSegment],
        preserveSegmentBoundaries: Bool = false
    ) -> [TaggedSegment] {
        guard !segments.isEmpty else { return [] }

        var result: [TaggedSegment] = []
        var currentSpeaker = segments[0].speaker
        var currentStart = segments[0].segment.start
        var currentEnd = segments[0].segment.end
        var currentText = segments[0].segment.text
        var currentSampleEligible = segments[0].sampleEligible

        for seg in segments.dropFirst() {
            let gap = max(0, seg.segment.start - currentEnd)
            if seg.speaker == currentSpeaker && gap <= consolidationGapThreshold {
                // Same speaker, temporally close — accumulate text
                currentText = preserveSegmentBoundaries
                    ? joinText(currentText, seg.segment.text)
                    : appendText(currentText, seg.segment.text, gap: gap)
                currentEnd = max(currentEnd, seg.segment.end)
                currentSampleEligible = currentSampleEligible && seg.sampleEligible
            } else {
                // Different speaker or too far apart — emit and start new segment
                result.append(TaggedSegment(
                    segment: SpeechSegment(start: currentStart, end: currentEnd, text: currentText),
                    speaker: currentSpeaker,
                    sampleEligible: currentSampleEligible
                ))
                currentSpeaker = seg.speaker
                currentStart = seg.segment.start
                currentEnd = seg.segment.end
                currentText = seg.segment.text
                currentSampleEligible = seg.sampleEligible
            }
        }
        // Emit last segment
        result.append(TaggedSegment(
            segment: SpeechSegment(start: currentStart, end: currentEnd, text: currentText),
            speaker: currentSpeaker,
            sampleEligible: currentSampleEligible
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
    let sampleEligible: Bool

    init(segment: SpeechSegment, speaker: String, sampleEligible: Bool = true) {
        self.segment = segment
        self.speaker = speaker
        self.sampleEligible = sampleEligible
    }
}
