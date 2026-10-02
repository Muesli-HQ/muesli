import FluidAudio
import Foundation
import MuesliCore

enum TranscriptFormatter {
    /// Authoritative segments retain source/session keys independently of human labels.
    /// A mixed ASR window stays unknown rather than assigning all its words to one voice.
    static func structured(
        micSegments: [SpeechSegment], systemSegments: [SpeechSegment],
        diarizationSegments: [TimedSpeakerSegment], micDiarizationSegments: [TimedSpeakerSegment],
        meetingStart: Date, session: UUID, enrollmentEnabled: Bool,
        systemSource: MeetingSpeakerSource = .system
    ) -> MeetingSpeakerState {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = .current
        clock.dateFormat = "HH:mm:ss"
        var evidence: [MeetingSpeakerKey: MeetingSpeakerEvidence] = [:]
        let echoLikeSystemSpeakers: Set<String>
        if !enrollmentEnabled && systemSource == .system {
            // Keep both source transcripts, but do not treat a matching, overlapping
            // system utterance as proof of a second voice for one-to-one naming.
            echoLikeSystemSpeakers = Set(systemSegments
                .filter { system in micSegments.contains { Self.isOverlappingTextEcho($0, system) } }
                .flatMap { system in
                    diarizationSegments.filter {
                        min(Double($0.endTimeSeconds), system.end) > max(Double($0.startTimeSeconds), system.start)
                    }.map(\.speakerId)
                })
        } else {
            echoLikeSystemSpeakers = []
        }
        func segments(_ speech: [SpeechSegment], source: MeetingSpeakerSource, diarization: [TimedSpeakerSegment]) -> [MeetingSpeakerSegment] {
            speech.map { segment in
                let overlapping = diarization.filter {
                    min(Double($0.endTimeSeconds), segment.end) > max(Double($0.startTimeSeconds), segment.start)
                }
                let ids = Set(overlapping.map(\.speakerId))
                let cluster: String
                let proof: MeetingSpeakerEvidence
                if source == .microphone && !enrollmentEnabled {
                    cluster = "source:microphone"
                    proof = .sourceFallback
                } else if ids.count == 1, let id = ids.first {
                    cluster = "cluster:" + id
                    proof = !enrollmentEnabled && source == .system
                        && Set(diarization.map(\.speakerId)).count == 1
                        && !echoLikeSystemSpeakers.contains(id)
                        ? .supportedNonOwner : .unknown
                } else {
                    cluster = ids.isEmpty ? "source:unverified" : "source:mixed"
                    proof = .unknown
                }
                let key = MeetingSpeakerKey(session: session, source: source, clusterID: cluster)
                evidence[key] = proof
                return MeetingSpeakerSegment(key: key, start: segment.start, end: segment.end,
                    timestamp: clock.string(from: meetingStart.addingTimeInterval(segment.start)), text: segment.text)
            }
        }
        let all = (segments(micSegments, source: .microphone, diarization: micDiarizationSegments)
            + segments(systemSegments, source: systemSource, diarization: diarizationSegments)).sorted {
                $0.start == $1.start ? $0.key < $1.key : $0.start < $1.start
            }
        var seen = Set<MeetingSpeakerKey>()
        let candidates = all.compactMap { segment -> MeetingSpeakerCandidate? in
            guard seen.insert(segment.key).inserted else { return nil }
            return .init(key: segment.key, evidence: evidence[segment.key] ?? .unknown)
        }
        return MeetingSpeakerState(session: session, segments: all,
            assignments: MeetingSpeakerIdentityPolicy.resolve(speakers: candidates, participants: []), candidates: candidates)
    }

    private static func isOverlappingTextEcho(_ mic: SpeechSegment, _ system: SpeechSegment) -> Bool {
        let micWords = mic.text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let systemWords = system.text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard micWords.count >= 3, micWords == systemWords else { return false }
        return min(mic.end, system.end) > max(mic.start, system.start)
    }

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
                    speakerLabelMap[seg.speakerId] = "Speaker \(nextSpeakerNumber)"
                    nextSpeakerNumber += 1
                }
            }

            taggedSystem = systemSegments.map { segment in
                let speaker = conservativeSpeakerAttribution
                    ? recordedSpeaker(for: segment, in: diarizationSegments, labelMap: speakerLabelMap)
                    : findSpeaker(for: segment, in: diarizationSegments, labelMap: speakerLabelMap)
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
}
