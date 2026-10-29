import AVFoundation
import FluidAudio
import Foundation
import MuesliCore

/// Native Swift transcription backend for Parakeet Unified 0.6B
/// (FastConformer-RNNT) using FluidAudio's offline batch `UnifiedAsrManager`.
/// English-focused, lower-WER successor to Parakeet TDT v3.
actor ParakeetUnifiedTranscriber {
    typealias ModelLoader = @Sendable (
        ManagedASRModelPlan, Bool, ((Double, String?) -> Void)?, ModelDownloadProgressHandler?
    ) async throws -> UnifiedAsrManager

    private let modelLoader: ModelLoader
    private var asrManager: UnifiedAsrManager?
    private var loadedPlan: ManagedASRModelPlan?
    private var loadGeneration: UInt64 = 0

    init(modelLoader: @escaping ModelLoader = { plan, localOnly, progress, progressSnapshot in
        return try await ManagedASRModelDownloader.loadValidated(
            plan,
            allowDownload: !localOnly,
            progress: progress,
            progressSnapshot: progressSnapshot
        ) { modelDirectory in
            let preparing = ModelDownloadProgress.preparing(
                modelID: plan.modelID,
                message: "Loading Parakeet Unified into Core ML..."
            )
            progress?(0.95, preparing.message)
            progressSnapshot?(preparing)
            let manager = UnifiedAsrManager()
            try await manager.loadModels(from: modelDirectory)
            return manager
        }
    }) {
        self.modelLoader = modelLoader
    }

    enum TranscriberError: Error, LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "Parakeet Unified models not loaded. Call loadModels() first."
            }
        }
    }

    /// Initializes the ASR manager; localOnly disables downloads and cache repair.
    func loadModels(
        localOnly: Bool = false,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        if asrManager != nil { return }
        let generation = loadGeneration

        fputs("[parakeet-unified] loading models local_only=\(localOnly)...\n", stderr)
        let plan = ManagedASRModelPlans.parakeetUnified()
        let manager = try await modelLoader(plan, localOnly, progress, progressSnapshot)
        // A shutdown() during the load must invalidate the result: discard the
        // freshly loaded manager instead of resurrecting a stale one.
        guard generation == loadGeneration else {
            throw CancellationError()
        }
        self.asrManager = manager
        self.loadedPlan = plan
        let preparing = ModelDownloadProgress.preparing(
            modelID: plan.modelID,
            message: "Loading Parakeet Unified into Core ML..."
        )
        progress?(1, nil)
        progressSnapshot?(preparing.replacing(phase: .ready, message: "Model ready"))
        fputs("[parakeet-unified] models ready\n", stderr)
    }

    /// Transcribe a WAV file URL (16 kHz mono).
    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard let asrManager else { throw TranscriberError.notLoaded }
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(wavURL)
        let start = CFAbsoluteTimeGetCurrent()
        let text = try await asrManager.transcribe(samples)
        let processingTime = CFAbsoluteTimeGetCurrent() - start
        return (text, processingTime)
    }

    func shutdown() {
        asrManager = nil
        loadedPlan = nil
        loadGeneration &+= 1
    }
}
