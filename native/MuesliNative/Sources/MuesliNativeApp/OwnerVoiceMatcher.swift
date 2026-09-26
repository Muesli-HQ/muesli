import Foundation

enum OwnerVoiceMatch: Equatable { case owner, nonOwner, unknown }

/// These operating gates are provisional until held-out native audio calibration.
/// They are similarity gates, never a claimed probability of identity.
struct OwnerVoiceMatcher {
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
}
