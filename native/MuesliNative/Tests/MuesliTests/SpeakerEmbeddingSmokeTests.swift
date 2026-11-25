import FluidAudio
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

/// Opt-in real-audio check that FluidAudio's diarizer yields speaker embeddings of one
/// consistent dimension, and that they become usable centroids. Local only: set
/// MUESLI_SPEAKER_SMOKE_AUDIO to an audio file path. Prints counts and dimensions only.
@Suite("Speaker embedding smoke")
struct SpeakerEmbeddingSmokeTests {
    static let audioPath = ProcessInfo.processInfo.environment["MUESLI_SPEAKER_SMOKE_AUDIO"]

    @Test(
        "diarizer embeddings share one dimension and form centroids",
        .enabled(if: audioPath.map { FileManager.default.fileExists(atPath: $0) } ?? false)
    )
    func realAudioEmbeddings() async throws {
        let url = URL(fileURLWithPath: try #require(Self.audioPath))
        let models = try await DiarizerModels.download()
        let manager = DiarizerManager()
        manager.initialize(models: models)

        let allSamples = try AudioConverter().resampleAudioFile(url)
        let samples = Array(allSamples.prefix(16_000 * 120))
        let result = try manager.performCompleteDiarization(samples, sampleRate: 16_000)

        let dimensions = Set(result.segments.map(\.embedding.count))
        let observations = SpeakerCentroidBuilder.observations(from: result.segments, minimumSeconds: 5)
        let centroidDimensions = Set(observations.compactMap(\.centroid?.count))
        print("[smoke] seconds=\(samples.count / 16_000) segments=\(result.segments.count) speakers=\(observations.count) segmentDims=\(dimensions.sorted()) centroids=\(observations.filter { $0.centroid != nil }.count) centroidDims=\(centroidDimensions.sorted())")

        #expect(!result.segments.isEmpty)
        #expect(dimensions == [SpeakerManager.embeddingSize])
        #expect(centroidDimensions == [SpeakerManager.embeddingSize])
        for centroid in observations.compactMap(\.centroid) {
            #expect(SpeakerVoiceprintMatcher.isUsable(centroid))
            #expect(abs(SpeakerVoiceprintMatcher.cosineSimilarity(centroid, centroid)! - 1) < 0.001)
        }
    }
}
