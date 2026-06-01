import FluidAudio
import Foundation
import MuesliCore

/// The recognition decision for a single diarized cluster: which profile (if any)
/// it matched, the resolved/candidate name, the cosine distance, and the tier.
struct SpeakerRecognition: Equatable {
    let label: String
    let profileID: String?
    let displayName: String?
    let distance: Double?
    let state: SpeakerMatchState
}

/// Pure, post-diarization recognizer. Matches each captured cluster embedding
/// against the saved profile library by cosine distance, assigns a confidence
/// tier, then enforces within-meeting uniqueness (at most one cluster per profile)
/// so a single meeting never shows the same name twice.
enum SpeakerRecognizer {
    /// Distance ≤ this → confident auto-match. Cosine distance, 0 (identical)…2.
    static let defaultStrongThreshold: Float = 0.5
    /// strong < distance ≤ this → borderline suggestion. Anchored on FluidAudio's
    /// `SpeakerManager.speakerThreshold` (≈ 0.65).
    static let defaultSuggestThreshold: Float = 0.65

    struct Cluster {
        let label: String
        let embedding: [Float]
    }

    static func recognize(
        clusters: [Cluster],
        profiles: [SpeakerProfile],
        strongThreshold: Float = defaultStrongThreshold,
        suggestThreshold: Float = defaultSuggestThreshold
    ) -> [SpeakerRecognition] {
        // Step 1: best profile match per cluster.
        struct Match {
            var profileID: String?
            var name: String?
            var distance: Float
            var tier: SpeakerMatchState
        }

        var matches: [Match] = clusters.map { cluster in
            guard !profiles.isEmpty else {
                return Match(profileID: nil, name: nil, distance: .infinity, tier: .unmatched)
            }
            var best: (profile: SpeakerProfile, distance: Float)?
            for profile in profiles {
                let distance = SpeakerUtilities.cosineDistance(cluster.embedding, profile.embedding)
                guard distance.isFinite else { continue }
                if best == nil || distance < best!.distance {
                    best = (profile, distance)
                }
            }
            guard let best else {
                return Match(profileID: nil, name: nil, distance: .infinity, tier: .unmatched)
            }
            let tier: SpeakerMatchState
            if best.distance <= strongThreshold {
                tier = .auto
            } else if best.distance <= suggestThreshold {
                tier = .suggested
            } else {
                tier = .unmatched
            }
            return Match(
                profileID: tier == .unmatched ? nil : best.profile.id,
                name: tier == .unmatched ? nil : best.profile.name,
                distance: best.distance,
                tier: tier
            )
        }

        // Step 2: within-meeting uniqueness — for each profile claimed by 2+
        // clusters, keep only the closest; demote the rest to unmatched so the
        // same person's name never appears on two speakers in one meeting.
        var claimants: [String: [Int]] = [:]
        for (index, match) in matches.enumerated() where match.tier != .unmatched {
            if let profileID = match.profileID {
                claimants[profileID, default: []].append(index)
            }
        }
        for (_, indices) in claimants where indices.count > 1 {
            let winner = indices.min { matches[$0].distance < matches[$1].distance }!
            for index in indices where index != winner {
                matches[index] = Match(profileID: nil, name: nil, distance: .infinity, tier: .unmatched)
            }
        }

        // Step 3: project to recognition decisions.
        return zip(clusters, matches).map { cluster, match in
            SpeakerRecognition(
                label: cluster.label,
                profileID: match.profileID,
                displayName: match.name,
                distance: match.distance.isFinite ? Double(match.distance) : nil,
                state: match.tier
            )
        }
    }
}
