import Foundation

enum OwnerVoiceMatch: Equatable { case owner, nonOwner, unknown }

/// These operating gates are provisional until held-out native audio calibration.
/// They are similarity gates, never a claimed probability of identity.
struct OwnerVoiceMatcher {
    static let maximumEvidenceWindowsPerCluster = 6

    static func shouldCollectMoreEvidence(clusterIDs: Set<String>, evidence: [String: [OwnerVoiceWindow]]) -> Bool {
        clusterIDs.contains { (evidence[$0]?.count ?? 0) < maximumEvidenceWindowsPerCluster }
    }

    let profile: OwnerVoiceProfile
    var minimumSimilarity: Float = 0.88
    var maximumNonOwnerSimilarity: Float = 0.45
    var alternativeMargin: Float = 0.08

    func match(windows: [OwnerVoiceWindow]) -> OwnerVoiceMatch {
        guard (try? profile.validate()) != nil, windows.count >= 2,
              windows.allSatisfy({ !$0.hasOverlap && $0.speechSeconds.isFinite && $0.speechSeconds >= 2 && $0.speechSeconds <= 10 }),
              windows.reduce(0, { $0 + $1.speechSeconds }) >= 5 else { return .unknown }
        var scores: [Float] = []
        var strongestReferenceScores: [Float] = []
        for window in windows {
            guard (try? OwnerVoiceProfile.normalized(window.embedding)) != nil else { return .unknown }
            let references = profile.references.map { OwnerVoiceProfile.similarity($0, window.embedding) }
            // Every immutable reference must agree; one lucky window cannot identify a voice.
            scores.append(references.min() ?? -1)
            strongestReferenceScores.append(references.max() ?? 1)
        }
        if scores.allSatisfy({ $0 >= minimumSimilarity }) { return .owner }
        if strongestReferenceScores.allSatisfy({ $0 <= maximumNonOwnerSimilarity }) { return .nonOwner }
        return .unknown
    }

    func score(windows: [OwnerVoiceWindow]) -> Float {
        windows.map { window in profile.references.map { OwnerVoiceProfile.similarity($0, window.embedding) }.min() ?? -1 }.min() ?? -1
    }

    func uniqueOwner(clusterIDs: Set<String>, evidence: [String: [OwnerVoiceWindow]]) -> String? {
        let owners = clusterIDs.filter { match(windows: evidence[$0] ?? []) == .owner }
        guard owners.count == 1, let winner = owners.first else { return nil }
        let winnerScore = score(windows: evidence[winner] ?? [])
        let alternativesAreClear = clusterIDs.filter { $0 != winner }.allSatisfy { id in
            let windows = evidence[id] ?? []
            guard match(windows: windows) == .nonOwner else { return false }
            return winnerScore - score(windows: windows) >= alternativeMargin
        }
        return alternativesAreClear ? winner : nil
    }
}
