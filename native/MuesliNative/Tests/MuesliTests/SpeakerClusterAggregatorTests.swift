import Testing
import Foundation
import FluidAudio
@testable import MuesliNativeApp

@Suite("Speaker cluster aggregator")
struct SpeakerClusterAggregatorTests {
    private let dim = SpeakerClusterAggregator.embeddingDimension

    /// A deterministic 256-D vector seeded by `value`.
    private func vec(_ value: Float, count: Int? = nil) -> [Float] {
        let n = count ?? dim
        return (0..<n).map { Float($0) * 0.001 + value }
    }

    private func seg(_ speakerId: String, start: Float, end: Float, embedding: [Float]) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speakerId,
            embedding: embedding,
            startTimeSeconds: start,
            endTimeSeconds: end,
            qualityScore: 1.0
        )
    }

    private func magnitude(_ v: [Float]) -> Float {
        v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
    }

    // MARK: - Label map characterization (must match TranscriptFormatter.merge)

    @Test("speaker label map numbers clusters in first-appearance order")
    func labelMapOrdering() {
        let segments = [
            seg("spkB", start: 5, end: 6, embedding: vec(0.2)),
            seg("spkA", start: 0, end: 1, embedding: vec(0.1)),
            seg("spkA", start: 2, end: 3, embedding: vec(0.1)),
        ]
        let map = TranscriptFormatter.speakerLabelMap(for: segments)
        #expect(map["spkA"] == "Speaker 1") // earliest start
        #expect(map["spkB"] == "Speaker 2")
    }

    // MARK: - Aggregation

    @Test("groups by speakerId and emits one row per realized cluster")
    func groupsByCluster() {
        let segments = [
            seg("spkA", start: 0, end: 1, embedding: vec(0.1)),
            seg("spkA", start: 2, end: 3, embedding: vec(0.1)),
            seg("spkB", start: 5, end: 6, embedding: vec(0.2)),
        ]
        let transcript = "[10:00:00] Speaker 1: hello there\n[10:00:05] Speaker 2: hi back"

        let clusters = SpeakerClusterAggregator.aggregate(diarizationSegments: segments, transcript: transcript)

        #expect(clusters.count == 2)
        #expect(clusters[0].label == "Speaker 1")
        #expect(clusters[0].speakerId == "spkA")
        #expect(clusters[1].label == "Speaker 2")
        #expect(clusters[1].speakerId == "spkB")
    }

    // Covers R4.
    @Test("two diarized speakers yield two rows with 256-D embeddings")
    func twoSpeakersTwoEmbeddings() {
        let segments = [
            seg("spkA", start: 0, end: 1, embedding: vec(0.1)),
            seg("spkB", start: 5, end: 6, embedding: vec(0.2)),
        ]
        let transcript = "[10:00:00] Speaker 1: a\n[10:00:05] Speaker 2: b"
        let clusters = SpeakerClusterAggregator.aggregate(diarizationSegments: segments, transcript: transcript)
        #expect(clusters.count == 2)
        #expect(clusters.allSatisfy { $0.embedding.count == 256 })
    }

    @Test("a cluster not realized in the blob produces no row")
    func unrealizedClusterDropped() {
        // Both speakers diarized, but only Speaker 1 survives in the transcript
        // (Speaker 2's text was dropped by reconcile or rendered as Others).
        let segments = [
            seg("spkA", start: 0, end: 1, embedding: vec(0.1)),
            seg("spkB", start: 5, end: 6, embedding: vec(0.2)),
        ]
        let transcript = "[10:00:00] Speaker 1: hello\n[10:00:05] Others: muffled"

        let clusters = SpeakerClusterAggregator.aggregate(diarizationSegments: segments, transcript: transcript)
        #expect(clusters.count == 1)
        #expect(clusters.first?.label == "Speaker 1")
    }

    @Test("Speaker 1 label is not confused with Speaker 10")
    func labelBoundaryColon() {
        let segments = [seg("spkA", start: 0, end: 1, embedding: vec(0.1))]
        // Only "Speaker 10:" present — must NOT realize "Speaker 1".
        let transcript = "[10:00:00] Speaker 10: hi"
        let clusters = SpeakerClusterAggregator.aggregate(diarizationSegments: segments, transcript: transcript)
        #expect(clusters.isEmpty)
    }

    @Test("no diarization yields no rows")
    func noDiarization() {
        let clusters = SpeakerClusterAggregator.aggregate(diarizationSegments: [], transcript: "[10:00:00] Others: hi")
        #expect(clusters.isEmpty)
    }

    @Test("transcript with only Others produces no rows")
    func onlyOthers() {
        let segments = [seg("spkA", start: 0, end: 1, embedding: vec(0.1))]
        let transcript = "[10:00:00] Others: ambient"
        let clusters = SpeakerClusterAggregator.aggregate(diarizationSegments: segments, transcript: transcript)
        #expect(clusters.isEmpty)
    }

    // MARK: - Representative embedding math

    @Test("representative embedding is unit-length and 256-D")
    func representativeIsNormalized() {
        let rep = SpeakerClusterAggregator.representativeEmbedding(from: [vec(0.1), vec(0.5)])
        let result = try! #require(rep)
        #expect(result.count == 256)
        #expect(abs(magnitude(result) - 1.0) < 1e-4)
    }

    @Test("representative embedding is deterministic")
    func representativeDeterministic() {
        let a = SpeakerClusterAggregator.representativeEmbedding(from: [vec(0.1), vec(0.5)])
        let b = SpeakerClusterAggregator.representativeEmbedding(from: [vec(0.1), vec(0.5)])
        #expect(a == b)
    }

    @Test("wrong-sized vectors are rejected, not silently averaged")
    func rejectsWrongSized() {
        // One valid 256-D, one 10-D garbage — representative must equal the
        // normalized single valid vector (the garbage is dropped).
        let valid = vec(0.3)
        let rep = SpeakerClusterAggregator.representativeEmbedding(from: [valid, vec(0.9, count: 10)])
        let result = try! #require(rep)
        let expected = SpeakerClusterAggregator.l2Normalize(valid)
        #expect(result.count == 256)
        for (lhs, rhs) in zip(result, expected) {
            #expect(abs(lhs - rhs) < 1e-5)
        }
    }

    @Test("all wrong-sized input yields nil (no representative)")
    func allWrongSizedNil() {
        let rep = SpeakerClusterAggregator.representativeEmbedding(from: [vec(0.1, count: 5), vec(0.2, count: 7)])
        #expect(rep == nil)
    }

    @Test("a cluster with no valid embedding produces no row")
    func clusterWithoutValidEmbeddingDropped() {
        let segments = [seg("spkA", start: 0, end: 1, embedding: vec(0.1, count: 5))]
        let transcript = "[10:00:00] Speaker 1: hi"
        let clusters = SpeakerClusterAggregator.aggregate(diarizationSegments: segments, transcript: transcript)
        #expect(clusters.isEmpty)
    }
}
