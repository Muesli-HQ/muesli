import Foundation
import FluidAudio

/// A speech region with absolute time bounds (seconds), backend-agnostic.
struct VadTimedRegion: Equatable {
    var startTime: Double
    var endTime: Double
}

/// Builds timed `SpeechSegment`s by transcribing each VAD speech region
/// independently, so timing works for every ASR backend (not just Parakeet).
enum VadTimedTranscriber {
    /// PURE SEAM: given regions and a per-region transcribe function, build
    /// timed segments. Blank transcriptions are dropped. Order is preserved.
    static func assemble(
        regions: [VadTimedRegion],
        transcribe: (VadTimedRegion) async throws -> String
    ) async rethrows -> [SpeechSegment] {
        var out: [SpeechSegment] = []
        for region in regions {
            let text = try await transcribe(region).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out.append(SpeechSegment(start: region.startTime, end: region.endTime, text: text))
        }
        return out
    }

    /// IO DRIVER (not unit-tested — exercised manually): run VAD on `samples`,
    /// transcribe each region via `transcribeWAV`, return timed segments.
    /// Delegates to `assemble` so production and tests share one drop/tag path.
    /// Mirrors the existing pattern at MeetingSession.swift:904-949.
    static func timedSegments(
        samples: [Float],
        vadManager: VadManager,
        maxSpeechDuration: Double = 10.0,
        transcribeWAV: (URL) async throws -> SpeechTranscriptionResult
    ) async throws -> [SpeechSegment] {
        let speechSegments = try await vadManager.segmentSpeech(
            samples,
            config: VadSegmentationConfig(maxSpeechDuration: maxSpeechDuration, speechPadding: 0.15)
        )
        // `VadSegment.startTime`/`.endTime` are `TimeInterval` (Double) already.
        let regions = speechSegments.map {
            VadTimedRegion(startTime: $0.startTime, endTime: $0.endTime)
        }
        let sampleRate = VadManager.sampleRate
        return try await assemble(regions: regions) { region in
            // Stay cancellable mid-run on long files (many regions, slow cloud ASR).
            try Task.checkCancellation()
            // Sample bounds mirror VadSegment.startSample/endSample: Int(time * rate).
            let startSample = max(0, Int(region.startTime * Double(sampleRate)))
            let endSample = min(samples.count, Int(region.endTime * Double(sampleRate)))
            // Degenerate slice → empty text; `assemble` drops it (single drop path).
            guard endSample > startSample else { return "" }
            let sliceURL = try MeetingMicRepairPlanner.writeTemporaryWAV(
                samples: Array(samples[startSample..<endSample])
            )
            defer { try? FileManager.default.removeItem(at: sliceURL) }
            do {
                return try await transcribeWAV(sliceURL).text
            } catch is CancellationError {
                // Real cancellation must abort the whole job — propagate.
                throw CancellationError()
            }
            // A real transcription error PROPAGATES (assemble rethrows), so the
            // caller can fall back to a full-file, untimed transcription rather
            // than silently dropping this region's speech.
        }
    }
}
