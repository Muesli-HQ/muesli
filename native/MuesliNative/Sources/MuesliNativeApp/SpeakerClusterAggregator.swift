import FluidAudio
import Foundation

/// One diarized cluster of a single meeting: its raw FluidAudio speaker id, the
/// `Speaker N` label realized in the transcript, and a representative voiceprint.
struct SpeakerCluster: Equatable, Sendable {
    let speakerId: String
    let label: String
    let embedding: [Float]
}

/// Pure helper that turns post-reconcile diarization output into the per-cluster
/// `meeting_speakers` rows we persist at meeting stop.
///
/// Correctness hinge: a `Speaker N` label only appears in the stored blob where a
/// surviving system ASR segment overlaps that cluster (and unmatched text falls
/// back to the literal `Others`). So realized labels are derived from the *actual
/// transcript text*, not from re-running assignment — this keeps the captured
/// rows aligned with what the user sees, across both the live-stop and audio-import
/// paths (which share `TranscriptFormatter.merge`).
enum SpeakerClusterAggregator {
    /// FluidAudio speaker embeddings are 256-D. Wrong-sized vectors are rejected.
    static let embeddingDimension = 256

    static func aggregate(
        diarizationSegments: [TimedSpeakerSegment],
        transcript: String
    ) -> [SpeakerCluster] {
        guard !diarizationSegments.isEmpty else { return [] }

        let labelMap = TranscriptFormatter.speakerLabelMap(for: diarizationSegments)

        // Group raw embeddings per cluster.
        var embeddingsByID: [String: [[Float]]] = [:]
        for seg in diarizationSegments {
            embeddingsByID[seg.speakerId, default: []].append(seg.embedding)
        }

        // Emit clusters in Speaker N order, but only for labels realized in the blob.
        let ordered = labelMap.sorted { speakerNumber($0.value) < speakerNumber($1.value) }
        var clusters: [SpeakerCluster] = []
        for (rawID, label) in ordered {
            guard transcriptRealizes(label: label, in: transcript) else { continue }
            guard let representative = representativeEmbedding(from: embeddingsByID[rawID] ?? []) else { continue }
            clusters.append(SpeakerCluster(speakerId: rawID, label: label, embedding: representative))
        }
        return clusters
    }

    /// A label is realized when a transcript line attributes text to it, i.e. the
    /// line `[HH:mm:ss] Speaker N: ...` exists. The trailing colon makes the match
    /// unambiguous (`Speaker 1:` never matches `Speaker 10:`).
    static func transcriptRealizes(label: String, in transcript: String) -> Bool {
        transcript.contains("] \(label):")
    }

    /// Representative embedding mirroring FluidAudio's centroid math, hardened:
    /// L2-normalize each valid sample → average → L2-normalize. Returns nil when
    /// no sample is the expected dimension (rejected, not silently zero-filled).
    static func representativeEmbedding(from embeddings: [[Float]]) -> [Float]? {
        let valid = embeddings.filter { $0.count == embeddingDimension }
        guard !valid.isEmpty else { return nil }

        var mean = [Float](repeating: 0, count: embeddingDimension)
        for embedding in valid {
            let normalized = l2Normalize(embedding)
            for i in 0..<embeddingDimension {
                mean[i] += normalized[i]
            }
        }
        let count = Float(valid.count)
        for i in 0..<embeddingDimension {
            mean[i] /= count
        }
        let result = l2Normalize(mean)
        guard result.count == embeddingDimension else { return nil }
        return result
    }

    static func l2Normalize(_ vector: [Float]) -> [Float] {
        let magnitude = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    /// Extracts the numeric suffix of a `Speaker N` label for stable ordering.
    private static func speakerNumber(_ label: String) -> Int {
        Int(label.split(separator: " ").last.map(String.init) ?? "") ?? Int.max
    }
}
