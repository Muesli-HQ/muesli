import FluidAudio
import Foundation
import MuesliCore

/// Native Swift transcription backend using FluidAudio's Parakeet TDT model
/// running on Apple's Neural Engine (ANE) via CoreML.
actor FluidAudioTranscriber {
    private var asrManager: AsrManager?
    private var loadedVersion: AsrModelVersion?

    enum TranscriberError: Error, LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "FluidAudio models not loaded. Call loadModels() first."
            }
        }
    }

    /// Downloads models (if needed) and initializes the ASR manager.
    /// - Parameter version: .v3 for multilingual (25 langs), .v2 for English-only
    func loadModels(version: AsrModelVersion = .v3, progress: ((Double, String?) -> Void)? = nil) async throws {
        if loadedVersion == version, asrManager != nil { return }

        fputs("[fluidaudio] downloading/loading models (version: \(version))...\n", stderr)
        let estimatedTotalBytes: Int64 = 450 * 1_000_000
        let rateEstimator = DownloadRateEstimator()
        let totalText = Self.formatMegabytes(estimatedTotalBytes)
        let models = try await AsrModels.downloadAndLoad(version: version) { downloadProgress in
            let fraction = downloadProgress.fractionCompleted
            let estimatedDownloadFraction = min(max(fraction / 0.5, 0), 1)
            let estimatedBytes = Int64(Double(estimatedTotalBytes) * estimatedDownloadFraction)
            let bytesPerSecond = rateEstimator.bytesPerSecond(for: estimatedBytes)
            let status: String
            switch downloadProgress.phase {
            case .listing:
                status = "0 MB of \(totalText)"
            case .downloading(_, _):
                let completedText = Self.formatMegabytes(estimatedBytes)
                if bytesPerSecond > 0 {
                    let rateText = Self.formatMegabytes(Int64(bytesPerSecond))
                    status = "\(completedText) of \(totalText) • \(rateText)/s"
                } else {
                    status = "\(completedText) of \(totalText)"
                }
            case .compiling(_):
                status = "Compiling model..."
            }
            DispatchQueue.main.async {
                progress?(fraction, status)
            }
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        self.loadedVersion = version
        fputs("[fluidaudio] models ready\n", stderr)
    }

    private static func formatMegabytes(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_000_000
        if megabytes >= 100 {
            return "\(Int(megabytes.rounded())) MB"
        }
        return String(format: "%.1f MB", megabytes)
    }

    /// Transcribe a WAV file URL directly.
    func transcribe(wavURL: URL) async throws -> ASRResult {
        guard let asrManager else { throw TranscriberError.notLoaded }
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        return try await asrManager.transcribe(wavURL, decoderState: &decoderState)
    }

    func shutdown() {
        asrManager = nil
        loadedVersion = nil
    }
}

private final class DownloadRateEstimator {
    private var downloadStartedAt: Date?

    func bytesPerSecond(for estimatedBytes: Int64) -> Double {
        guard estimatedBytes > 0 else { return 0 }
        let now = Date()
        if downloadStartedAt == nil {
            downloadStartedAt = now
            return 0
        }
        let elapsed = max(now.timeIntervalSince(downloadStartedAt ?? now), 1.0)
        return Double(estimatedBytes) / elapsed
    }
}
