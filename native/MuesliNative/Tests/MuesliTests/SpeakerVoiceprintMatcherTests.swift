import Foundation
import MuesliCore
import Testing

@Suite("Speaker voiceprint matcher")
struct SpeakerVoiceprintMatcherTests {
    /// Unit vector along `axis` blended toward `other` by `mix`, normalized.
    private func vector(_ axis: Int, toward other: Int? = nil, mix: Float = 0, dimension: Int = 8) -> [Float] {
        var values = [Float](repeating: 0, count: dimension)
        values[axis] = 1 - mix
        if let other { values[other] += mix }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return values.map { $0 / norm }
    }

    private func candidate(_ label: String, _ centroid: [Float]?) -> SpeakerVoiceprintMatcher.Candidate {
        SpeakerVoiceprintMatcher.Candidate(label: label, centroid: centroid)
    }

    private func profile(_ id: Int64, _ voiceprints: [[Float]]) -> SpeakerVoiceprintMatcher.Profile {
        SpeakerVoiceprintMatcher.Profile(id: id, voiceprints: voiceprints)
    }

    @Test("no profiles produces no matches")
    func noProfiles() {
        let result = SpeakerVoiceprintMatcher.match(candidates: [candidate("Speaker 1", vector(0))], profiles: [])
        #expect(result.isEmpty)
    }

    @Test("a centroid above the threshold matches its profile")
    func matchAboveThreshold() {
        let result = SpeakerVoiceprintMatcher.match(
            candidates: [candidate("Speaker 1", vector(0, toward: 1, mix: 0.1))],
            profiles: [profile(7, [vector(0)]), profile(8, [vector(2)])]
        )
        #expect(result == ["Speaker 1": 7])
    }

    @Test("a centroid below the threshold stays unnamed")
    func belowThreshold() {
        // cos(axis0, 50/50 blend of axis0/axis1) ~= 0.707 > threshold, so push further away.
        let far = vector(0, toward: 1, mix: 0.7)
        let similarity = SpeakerVoiceprintMatcher.cosineSimilarity(far, vector(0))!
        #expect(similarity < SpeakerVoiceprintMatcher.similarityThreshold)
        let result = SpeakerVoiceprintMatcher.match(
            candidates: [candidate("Speaker 1", far)],
            profiles: [profile(7, [vector(0)])]
        )
        #expect(result.isEmpty)
    }

    @Test("an ambiguous centroid inside the margin stays unnamed")
    func ambiguousMargin() {
        // Equidistant from two profiles: both above threshold, margin zero.
        let between = vector(0, toward: 1, mix: 0.5)
        let result = SpeakerVoiceprintMatcher.match(
            candidates: [candidate("Speaker 1", between)],
            profiles: [profile(7, [vector(0, toward: 1, mix: 0.2)]), profile(8, [vector(1, toward: 0, mix: 0.2)])]
        )
        #expect(result.isEmpty)
    }

    @Test("two speakers competing for one profile: only the best score wins")
    func conflictResolvedByBestScore() {
        let result = SpeakerVoiceprintMatcher.match(
            candidates: [
                candidate("Speaker 1", vector(0, toward: 1, mix: 0.15)),
                candidate("Speaker 2", vector(0, toward: 2, mix: 0.05)),
            ],
            profiles: [profile(7, [vector(0)])]
        )
        #expect(result == ["Speaker 2": 7])
    }

    @Test("dimension mismatch is a non-match, not a crash")
    func dimensionMismatch() {
        let result = SpeakerVoiceprintMatcher.match(
            candidates: [candidate("Speaker 1", vector(0, dimension: 8))],
            profiles: [profile(7, [vector(0, dimension: 16)])]
        )
        #expect(result.isEmpty)
        #expect(SpeakerVoiceprintMatcher.cosineSimilarity(vector(0, dimension: 8), vector(0, dimension: 16)) == nil)
    }

    @Test("NaN, infinite, zero and empty vectors are rejected")
    func invalidVectorsRejected() {
        var nan = vector(0)
        nan[3] = .nan
        var infinite = vector(0)
        infinite[1] = .infinity
        let zero = [Float](repeating: 0, count: 8)
        for bad in [nan, infinite, zero, []] {
            #expect(!SpeakerVoiceprintMatcher.isUsable(bad))
            let asCandidate = SpeakerVoiceprintMatcher.match(
                candidates: [candidate("Speaker 1", bad)],
                profiles: [profile(7, [vector(0)])]
            )
            #expect(asCandidate.isEmpty)
            // A corrupt stored voiceprint must not poison a valid profile print.
            let asVoiceprint = SpeakerVoiceprintMatcher.match(
                candidates: [candidate("Speaker 1", vector(0))],
                profiles: [profile(7, [bad, vector(0)])]
            )
            #expect(asVoiceprint == ["Speaker 1": 7])
        }
    }

    @Test("the mic channel (You) is never matched")
    func youIsNeverMatched() {
        let result = SpeakerVoiceprintMatcher.match(
            candidates: [candidate("You", vector(0)), candidate("Speaker 1", vector(2))],
            profiles: [profile(7, [vector(0)]), profile(8, [vector(2)])]
        )
        #expect(result == ["Speaker 1": 8])
    }

    @Test("a missing centroid (too little audio) is never matched")
    func missingCentroid() {
        let result = SpeakerVoiceprintMatcher.match(
            candidates: [candidate("Speaker 1", nil)],
            profiles: [profile(7, [vector(0)])]
        )
        #expect(result.isEmpty)
    }

    @Test("profile score is the mean of its top two voiceprints")
    func meanOfTopTwo() {
        let centroid = vector(0)
        let score = SpeakerVoiceprintMatcher.profileScore(
            centroid: centroid,
            voiceprints: [vector(0), vector(0, toward: 1, mix: 0.3), vector(1)]
        )
        let expected = (1 + SpeakerVoiceprintMatcher.cosineSimilarity(centroid, vector(0, toward: 1, mix: 0.3))!) / 2
        #expect(score != nil)
        #expect(abs(score! - expected) < 0.0001)
        // A single voiceprint scores by itself.
        #expect(abs(SpeakerVoiceprintMatcher.profileScore(centroid: centroid, voiceprints: [vector(0)])! - 1) < 0.0001)
    }
}
