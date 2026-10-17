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
        conservativeSpeakerAttribution: Bool = false
    ) -> String {
        structured(micSegments: micSegments, systemSegments: systemSegments,
                   diarizationSegments: diarizationSegments, micDiarizationSegments: micDiarizationSegments,
                   meetingStart: meetingStart,
                   conservativeSpeakerAttribution: conservativeSpeakerAttribution).render()
    }

    static func structured(
        micSegments: [SpeechSegment], systemSegments: [SpeechSegment],
        diarizationSegments: [TimedSpeakerSegment]?, micDiarizationSegments: [TimedSpeakerSegment]? = nil,
        meetingStart: Date,
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
        let taggedMic: [TaggedSegment]
        if let localDiarization = SpeakerAttribution.localDiarization(from: micDiarizationSegments) {
            identities.removeValue(forKey: "You")
            let micSpeakerLabelMap = speakerLabelMap(for: localDiarization, prefix: "Local speaker")
            for (id, label) in micSpeakerLabelMap {
                let rank = Int(label.split(separator: " ").last ?? "1") ?? 1
                identities[label] = MeetingSpeaker(
                    key: .init(epoch: epoch, channel: .microphone, clusterID: id),
                    rank: rank, fallbackLabel: label)
            }
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
            for seg in diarizationSegments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
                if let label = speakerLabelMap[seg.speakerId], identities[label] == nil {
                    let rank = Int(label.split(separator: " ").last ?? "1") ?? 1
                    identities[label] = MeetingSpeaker(
                        key: .init(epoch: epoch, channel: systemChannel, clusterID: seg.speakerId),
                        rank: rank + 1, fallbackLabel: label)
                }
            }

            taggedSystem = systemSegments.map { segment in
                let speaker = useConservativeAttribution
                    ? recordedSpeaker(for: segment, in: diarizationSegments, labelMap: speakerLabelMap)
                    : findSpeaker(for: segment, in: diarizationSegments, labelMap: speakerLabelMap, fallback: "Others")
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
