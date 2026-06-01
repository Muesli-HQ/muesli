import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Speaker recognizer")
struct SpeakerRecognizerTests {
    /// A 2-D unit vector at the given cosine similarity to `[1, 0]`.
    /// cosineDistance to [1,0] is then `1 - similarity`.
    private func vectorAtSimilarity(_ sim: Float) -> [Float] {
        [sim, (1 - sim * sim).squareRoot()]
    }

    private func profile(_ id: String, _ name: String, embedding: [Float] = [1, 0]) -> SpeakerProfile {
        SpeakerProfile(id: id, name: name, embedding: embedding)
    }

    // Covers R5.
    @Test("a strongly matching cluster is auto-named")
    func autoMatch() {
        let bob = profile("bob-1", "Bob")
        let cluster = SpeakerRecognizer.Cluster(label: "Speaker 1", embedding: vectorAtSimilarity(0.97)) // dist 0.03
        let results = SpeakerRecognizer.recognize(clusters: [cluster], profiles: [bob])
        #expect(results.count == 1)
        #expect(results[0].state == .auto)
        #expect(results[0].displayName == "Bob")
        #expect(results[0].profileID == "bob-1")
    }

    @Test("a borderline cluster is a suggestion")
    func borderlineSuggested() {
        let bob = profile("bob-1", "Bob")
        // similarity 0.4 → distance 0.6 (between strong 0.5 and suggest 0.65)
        let cluster = SpeakerRecognizer.Cluster(label: "Speaker 1", embedding: vectorAtSimilarity(0.4))
        let results = SpeakerRecognizer.recognize(clusters: [cluster], profiles: [bob])
        #expect(results[0].state == .suggested)
        #expect(results[0].displayName == "Bob") // candidate name carried for the chip
        #expect(results[0].profileID == "bob-1")
    }

    @Test("a far cluster stays unmatched")
    func farUnmatched() {
        let bob = profile("bob-1", "Bob")
        // similarity 0.2 → distance 0.8 (> suggest 0.65)
        let cluster = SpeakerRecognizer.Cluster(label: "Speaker 1", embedding: vectorAtSimilarity(0.2))
        let results = SpeakerRecognizer.recognize(clusters: [cluster], profiles: [bob])
        #expect(results[0].state == .unmatched)
        #expect(results[0].profileID == nil)
        #expect(results[0].displayName == nil)
    }

    @Test("empty library leaves every cluster unmatched")
    func emptyLibrary() {
        let clusters = [
            SpeakerRecognizer.Cluster(label: "Speaker 1", embedding: vectorAtSimilarity(0.99)),
            SpeakerRecognizer.Cluster(label: "Speaker 2", embedding: vectorAtSimilarity(0.5)),
        ]
        let results = SpeakerRecognizer.recognize(clusters: clusters, profiles: [])
        #expect(results.allSatisfy { $0.state == .unmatched })
    }

    @Test("closest profile wins when several are within threshold")
    func tieBreakClosest() {
        let bob = profile("bob-1", "Bob", embedding: [1, 0])
        let carol = profile("carol-1", "Carol", embedding: vectorAtSimilarity(0.9)) // a bit off-axis
        // Cluster aligned with Bob exactly.
        let cluster = SpeakerRecognizer.Cluster(label: "Speaker 1", embedding: [1, 0])
        let results = SpeakerRecognizer.recognize(clusters: [cluster], profiles: [bob, carol])
        #expect(results[0].profileID == "bob-1")
        #expect(results[0].displayName == "Bob")
    }

    @Test("two clusters matching one profile: only the closest is named")
    func withinMeetingUniqueness() {
        let bob = profile("bob-1", "Bob")
        let near = SpeakerRecognizer.Cluster(label: "Speaker 1", embedding: vectorAtSimilarity(0.99)) // dist .01
        let alsoNear = SpeakerRecognizer.Cluster(label: "Speaker 2", embedding: vectorAtSimilarity(0.95)) // dist .05
        let results = SpeakerRecognizer.recognize(clusters: [near, alsoNear], profiles: [bob])

        let speaker1 = results.first { $0.label == "Speaker 1" }!
        let speaker2 = results.first { $0.label == "Speaker 2" }!
        #expect(speaker1.state == .auto)            // closest keeps the name
        #expect(speaker1.profileID == "bob-1")
        #expect(speaker2.state == .unmatched)       // demoted — no duplicate "Bob"
        #expect(speaker2.profileID == nil)
    }

    @Test("two clusters matching two distinct profiles both keep their names")
    func distinctProfilesBothNamed() {
        let bob = profile("bob-1", "Bob", embedding: [1, 0])
        let carol = profile("carol-1", "Carol", embedding: [0, 1])
        let c1 = SpeakerRecognizer.Cluster(label: "Speaker 1", embedding: [1, 0])
        let c2 = SpeakerRecognizer.Cluster(label: "Speaker 2", embedding: [0, 1])
        let results = SpeakerRecognizer.recognize(clusters: [c1, c2], profiles: [bob, carol])
        #expect(results[0].displayName == "Bob")
        #expect(results[1].displayName == "Carol")
        #expect(results.allSatisfy { $0.state == .auto })
    }

    @Test("a wrong-dimension or empty cluster embedding stays unmatched")
    func malformedEmbeddingUnmatched() {
        let bob = profile("bob-1", "Bob", embedding: Array(repeating: Float(0), count: 256).enumerated().map { $0.offset == 0 ? 1 : 0 })
        let empty = SpeakerRecognizer.Cluster(label: "Speaker 1", embedding: [])
        let wrongSize = SpeakerRecognizer.Cluster(label: "Speaker 2", embedding: [1, 0, 0])
        let results = SpeakerRecognizer.recognize(clusters: [empty, wrongSize], profiles: [bob])
        #expect(results.allSatisfy { $0.state == .unmatched })
    }

    @Test("results preserve input cluster order")
    func preservesOrder() {
        let bob = profile("bob-1", "Bob")
        let clusters = (1...3).map { SpeakerRecognizer.Cluster(label: "Speaker \($0)", embedding: vectorAtSimilarity(0.1)) }
        let results = SpeakerRecognizer.recognize(clusters: clusters, profiles: [bob])
        #expect(results.map(\.label) == ["Speaker 1", "Speaker 2", "Speaker 3"])
    }
}
