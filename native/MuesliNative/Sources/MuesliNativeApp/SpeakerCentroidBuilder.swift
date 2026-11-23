import FluidAudio
import Foundation
import MuesliCore

/// Turns FluidAudio diarization output into one centroid per meeting speaker.
///
/// FluidAudio's `DiarizerManager.performCompleteDiarization` attaches the 256-dim
/// WeSpeaker embedding of each chunk's speaker slot to every `TimedSpeakerSegment`.
/// Its `speakerManager` also keeps running embeddings, but that state is shared across
/// meetings on one `DiarizerManager`, so centroids are rebuilt here from this meeting's
/// segments only.
enum SpeakerCentroidBuilder {
    /// Speakers with less diarized speech than this keep a row but no centroid: a short
    /// clip gives a noisy embedding that would make a poor voiceprint.
    static let minimumVoiceprintSeconds: Double = 10

    static func observations(
        from segments: [TimedSpeakerSegment],
        minimumSeconds: Double = minimumVoiceprintSeconds,
        startingNumber: Int = 1
    ) -> [MeetingSpeakerObservation] {
        observations(from: segments, speakerEmbeddings: [:], minimumSeconds: minimumSeconds, startingNumber: startingNumber)
    }

    /// Builds per-speaker observations, using `speakerEmbeddings[speakerID]` when per-segment
    /// embeddings have been stripped (e.g. bounded recorded-audio diarization).
    static func observations(
        from segments: [TimedSpeakerSegment],
        speakerEmbeddings: [String: [Float]],
        minimumSeconds: Double = minimumVoiceprintSeconds,
        startingNumber: Int = 1
    ) -> [MeetingSpeakerObservation] {
        let labels = TranscriptFormatter.speakerLabels(for: segments, startingNumber: startingNumber)
        let bySpeaker = Dictionary(grouping: segments, by: \.speakerId)
        return labels
            .sorted { speakerNumber($0.value) < speakerNumber($1.value) }
            .map { speakerID, label in
                let speakerSegments = bySpeaker[speakerID] ?? []
                let seconds = speakerSegments.reduce(0) { $0 + Double(max(0, $1.durationSeconds)) }
                let centroid: [Float]?
                if seconds >= minimumSeconds {
                    centroid = weightedCentroid(of: speakerSegments)
                        ?? speakerEmbeddings[speakerID].flatMap(normalizedCentroid)
                } else {
                    centroid = nil
                }
                return MeetingSpeakerObservation(label: label, centroid: centroid, speechSeconds: seconds)
            }
    }

    static func normalizedCentroid(_ vector: [Float]) -> [Float]? {
        guard SpeakerVoiceprintMatcher.isUsable(vector) else { return nil }
        let normSquared = vector.reduce(Float(0)) { $0 + $1 * $1 }
        guard normSquared.isFinite, normSquared > 0 else { return nil }
        let norm = normSquared.squareRoot()
        guard norm.isFinite, norm > 0 else { return nil }
        let unit = vector.map { $0 / norm }
        return SpeakerVoiceprintMatcher.isUsable(unit) ? unit : nil
    }

    /// Duration-weighted mean of the L2-normalized usable embeddings, renormalized.
    /// Only the dimension carrying the most speech is used, so a stray vector of another
    /// size cannot crash or skew the mean.
    private static func weightedCentroid(of segments: [TimedSpeakerSegment]) -> [Float]? {
        let usable = segments.compactMap { segment -> (vector: [Float], weight: Float)? in
            guard segment.durationSeconds > 0,
                  let unit = normalizedCentroid(segment.embedding) else { return nil }
            return (unit, segment.durationSeconds)
        }
        let byDimension = Dictionary(grouping: usable, by: \.vector.count)
        guard let dominant = byDimension.max(by: { totalWeight($0.value) < totalWeight($1.value) })?.value,
              let dimension = dominant.first?.vector.count else { return nil }
        var sum = [Float](repeating: 0, count: dimension)
        for item in dominant {
            for index in 0..<dimension { sum[index] += item.vector[index] * item.weight }
        }
        return normalizedCentroid(sum)
    }

    private static func totalWeight(_ items: [(vector: [Float], weight: Float)]) -> Float {
        items.reduce(0) { $0 + $1.weight }
    }

    private static func speakerNumber(_ label: String) -> Int {
        Int(label.dropFirst("Speaker ".count)) ?? .max
    }
}
