import Foundation

/// Matches a meeting's diarized speaker centroids against saved speaker profiles.
///
/// Pure and deterministic: no storage, no logging. Vectors are the 256-dim WeSpeaker
/// embeddings FluidAudio's diarizer attaches to each `TimedSpeakerSegment`, but the
/// matcher only assumes "same dimension, finite, non-zero".
public enum SpeakerVoiceprintMatcher {
    /// Minimum cosine similarity for a match. FluidAudio's own in-meeting clustering is
    /// far looser (it merges at cosine distance < 0.84). Naming someone in a different
    /// meeting is a stronger claim, so this starts conservative: a wrong name is worse
    /// than leaving "Speaker N".
    public static let similarityThreshold: Float = 0.65
    /// Minimum lead of the best profile over the runner-up profile. Prevents naming a
    /// speaker who sounds about equally like two saved people.
    public static let minimumMargin: Float = 0.10
    /// Labels that are never diarized remote speakers. "You" is the mic channel.
    public static let reservedLabels: Set<String> = ["You", "Others", "Multiple speakers", "Unknown speaker"]

    public struct Candidate: Sendable, Equatable {
        public let label: String
        public let centroid: [Float]?

        public init(label: String, centroid: [Float]?) {
            self.label = label
            self.centroid = centroid
        }
    }

    public struct Profile: Sendable, Equatable {
        public let id: Int64
        public let voiceprints: [[Float]]

        public init(id: Int64, voiceprints: [[Float]]) {
            self.id = id
            self.voiceprints = voiceprints
        }
    }

    /// Returns `label -> profile id` for confident matches only. A profile is assigned
    /// to at most one speaker per meeting; on conflict the higher score keeps it and the
    /// others stay unnamed.
    public static func match(candidates: [Candidate], profiles: [Profile]) -> [String: Int64] {
        guard !profiles.isEmpty else { return [:] }
        var bestByProfile: [Int64: (label: String, score: Float)] = [:]
        for candidate in candidates {
            guard let proposal = proposal(for: candidate, profiles: profiles) else { continue }
            if let current = bestByProfile[proposal.profileID], current.score >= proposal.score { continue }
            bestByProfile[proposal.profileID] = (candidate.label, proposal.score)
        }
        return Dictionary(uniqueKeysWithValues: bestByProfile.map { ($0.value.label, $0.key) })
    }

    private static func proposal(for candidate: Candidate, profiles: [Profile]) -> (profileID: Int64, score: Float)? {
        guard !reservedLabels.contains(candidate.label),
              let centroid = candidate.centroid,
              isUsable(centroid) else { return nil }
        let scored = profiles
            .compactMap { profile in profileScore(centroid: centroid, voiceprints: profile.voiceprints).map { (profile.id, $0) } }
            .sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= similarityThreshold else { return nil }
        if scored.count > 1, best.1 - scored[1].1 < minimumMargin { return nil }
        return (best.0, best.1)
    }

    /// Mean of the two highest similarities between `centroid` and the profile's usable,
    /// same-dimension voiceprints. One voiceprint scores alone; none scores `nil`.
    public static func profileScore(centroid: [Float], voiceprints: [[Float]]) -> Float? {
        let top = voiceprints.compactMap { cosineSimilarity(centroid, $0) }.sorted(by: >).prefix(2)
        guard !top.isEmpty else { return nil }
        return top.reduce(0, +) / Float(top.count)
    }

    /// Cosine similarity, or `nil` when either vector is unusable or dimensions differ.
    public static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard lhs.count == rhs.count, isUsable(lhs), isUsable(rhs) else { return nil }
        var dot: Float = 0
        var lhsSquares: Float = 0
        var rhsSquares: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsSquares += lhs[index] * lhs[index]
            rhsSquares += rhs[index] * rhs[index]
        }
        let similarity = dot / (lhsSquares.squareRoot() * rhsSquares.squareRoot())
        return similarity.isFinite ? similarity : nil
    }

    /// Non-empty, all finite, non-zero norm.
    public static func isUsable(_ vector: [Float]) -> Bool {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return false }
        return vector.contains { $0 != 0 }
    }
}
