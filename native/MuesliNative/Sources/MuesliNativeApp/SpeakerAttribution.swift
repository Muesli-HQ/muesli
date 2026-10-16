import FluidAudio
import Foundation

/// Matches ASR segments to diarizer speakers by time. Shared by the reconciler
/// (which must not merge turns across a speaker change) and the formatter (which
/// labels them), so both always agree on who spoke a segment.
enum SpeakerAttribution {
    static let nearestSpeakerMaxGapSeconds: Float = 2.0

    static func distinctSpeakerCount(in diarizationSegments: [TimedSpeakerSegment]) -> Int {
        Set(diarizationSegments.map(\.speakerId)).count
    }

    /// Raw diarizer speaker ID with the largest time overlap, falling back to the
    /// nearest diarized speech within `nearestSpeakerMaxGapSeconds`.
    static func speakerID(
        for segment: SpeechSegment,
        in diarizationSegments: [TimedSpeakerSegment]
    ) -> String? {
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
            return bestSpeakerId
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
