import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Owner voice matching")
struct OwnerVoiceMatcherTests {
    private func vector(_ index: Int) -> [Float] {
        var result = [Float](repeating: 0, count: 256)
        result[index] = 1
        return result
    }

    @Test("repeated clean owner evidence matches, orthogonal and mixed speech abstain")
    func agreement() throws {
        let profile = try OwnerVoiceProfile(modelIdentity: "fixture", references: [vector(0), vector(0)], acceptedSpeechSeconds: 20)
        let matcher = OwnerVoiceMatcher(profile: profile)
        #expect(matcher.match(windows: [window(0), window(0)]) == .owner)
        #expect(matcher.match(windows: [window(1), window(1)]) == .nonOwner)
        #expect(matcher.match(windows: [window(0), window(1)]) == .unknown)
        #expect(matcher.match(windows: [window(0)]) == .unknown)
        #expect(matcher.match(windows: [window(0, overlap: true), window(0)]) == .unknown)
    }

    @Test("short and malformed evidence cannot identify owner")
    func unusableWindows() throws {
        let profile = try OwnerVoiceProfile(modelIdentity: "fixture", references: [vector(0), vector(0)], acceptedSpeechSeconds: 20)
        let matcher = OwnerVoiceMatcher(profile: profile)
        #expect(matcher.match(windows: [OwnerVoiceWindow(embedding: [], speechSeconds: 5, hasOverlap: false)]) == .unknown)
        #expect(matcher.match(windows: [window(0, seconds: 0.5), window(0, seconds: 0.5)]) == .unknown)
    }

    private func window(_ index: Int, overlap: Bool = false, seconds: Double = 5) -> OwnerVoiceWindow {
        OwnerVoiceWindow(embedding: vector(index), speechSeconds: seconds, hasOverlap: overlap)
    }
    @Test("disagreeing reference similarities cannot establish non-owner evidence")
    func conflictingReferences() throws {
        var second = vector(0)
        second[0] = 0.805
        second[1] = sqrt(1 - 0.805 * 0.805)
        var candidate = vector(0)
        candidate[0] = 0.89
        candidate[1] = -sqrt(1 - 0.89 * 0.89)
        let profile = try OwnerVoiceProfile(modelIdentity: "fixture", references: [vector(0), second], acceptedSpeechSeconds: 20)
        let window = OwnerVoiceWindow(embedding: candidate, speechSeconds: 5, hasOverlap: false)
        #expect(OwnerVoiceMatcher(profile: profile).match(windows: [window, window]) == .unknown)
    }

}
