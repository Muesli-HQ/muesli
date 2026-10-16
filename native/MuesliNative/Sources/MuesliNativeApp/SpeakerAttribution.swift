import FluidAudio
import Foundation

/// Matches ASR segments to diarizer speakers by time. Shared by the reconciler
/// (which must not merge turns across a speaker change) and the formatter (which
/// labels them), so both always agree on who spoke a segment.
enum SpeakerAttribution {
    static let nearestSpeakerMaxGapSeconds: Float = 2.0
    /// A room-mic diarizer regularly emits short extra IDs for coughs, doors or
    /// AEC residue of the remote party; those must not split a one-voice call.
    static let minimumLocalSpeakerSeconds: Float = 5
    static let minimumLocalSpeakerShare: Float = 0.05

    /// Diarizer IDs that spoke long enough to count as a distinct in-room voice.
    static func significantSpeakerIDs(in diarizationSegments: [TimedSpeakerSegment]) -> Set<String> {
        var total: Float = 0
        var durationBySpeaker: [String: Float] = [:]
        for segment in diarizationSegments {
            let duration = max(0, segment.endTimeSeconds - segment.startTimeSeconds)
            durationBySpeaker[segment.speakerId, default: 0] += duration
            total += duration
        }
        guard total > 0 else { return [] }
        return Set(durationBySpeaker.filter { _, duration in
            duration >= minimumLocalSpeakerSeconds && duration / total >= minimumLocalSpeakerShare
        }.keys)
    }

    /// The single "is the room really multi-speaker" decision for the mic channel.
    /// nil when the room effectively had one voice (the mic stays "You");
    /// otherwise only the significant speakers' segments.
    static func localDiarization(from micDiarizationSegments: [TimedSpeakerSegment]?) -> [TimedSpeakerSegment]? {
        guard let micDiarizationSegments else { return nil }
        let speakerIDs = significantSpeakerIDs(in: micDiarizationSegments)
        guard speakerIDs.count > 1 else { return nil }
        return micDiarizationSegments.filter { speakerIDs.contains($0.speakerId) }
    }

    /// Raw diarizer speaker ID with the largest total time overlap, falling back
    /// to the nearest diarized speech within `nearestSpeakerMaxGapSeconds`.
    static func speakerID(
        for segment: SpeechSegment,
        in diarizationSegments: [TimedSpeakerSegment]
    ) -> String? {
        let segStart = Float(segment.start)
        let segEnd = Float(max(segment.end, segment.start + 0.1)) // ensure non-zero duration

        // Sum per speaker: a turn spanning A–B–A belongs to A even when B has the
        // single longest diarized stretch.
        var overlapBySpeaker: [String: Float] = [:]
        for diarSeg in diarizationSegments {
            let overlapStart = max(segStart, diarSeg.startTimeSeconds)
            let overlapEnd = min(segEnd, diarSeg.endTimeSeconds)
            let overlap = overlapEnd - overlapStart
            if overlap > 0 {
                overlapBySpeaker[diarSeg.speakerId, default: 0] += overlap
            }
        }

        // Ties break by speaker ID so attribution is deterministic.
        if let best = overlapBySpeaker.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) {
            return best.key
        }
        return nearestSpeakerID(segmentStart: segStart, segmentEnd: segEnd, in: diarizationSegments)
    }

    private static func nearestSpeakerID(
        segmentStart: Float,
        segmentEnd: Float,
        in diarizationSegments: [TimedSpeakerSegment]
    ) -> String? {
        let segMidpoint = (segmentStart + segmentEnd) / 2

        let nearest = diarizationSegments.min { lhs, rhs in
            temporalGap(between: segMidpoint, and: lhs) < temporalGap(between: segMidpoint, and: rhs)
        }

        guard let nearest else { return nil }
        return temporalGap(between: segMidpoint, and: nearest) <= nearestSpeakerMaxGapSeconds ? nearest.speakerId : nil
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
}
