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
    func loadModels(
        version: AsrModelVersion = .v3,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        if loadedVersion == version, asrManager != nil { return }

        fputs("[fluidaudio] downloading/loading models (version: \(version))...\n", stderr)
        let plan = version == .v2 ? ManagedASRModelPlans.parakeetV2() : ManagedASRModelPlans.parakeetV3()
        let manager = try await ManagedASRModelDownloader.loadValidated(
            plan,
            progress: progress,
            progressSnapshot: progressSnapshot
        ) { modelDirectory in
            let preparing = ModelDownloadProgress.preparing(
                modelID: plan.modelID,
                message: "Loading Parakeet into Core ML..."
            )
            progress?(0.95, preparing.message)
            progressSnapshot?(preparing)
            let models = try await AsrModels.load(from: modelDirectory, version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        self.asrManager = manager
        self.loadedVersion = version
        let preparing = ModelDownloadProgress.preparing(
            modelID: plan.modelID,
            message: "Loading Parakeet into Core ML..."
        )
        progress?(1, nil)
        progressSnapshot?(preparing.replacing(phase: .ready, message: "Model ready"))
        fputs("[fluidaudio] models ready\n", stderr)
    }

    /// Transcribe a WAV file URL directly.
    /// `language` is an optional ISO code enabling FluidAudio's script-level
    /// token filter on the v3 joint decoder (v2 ignores the hint; nil = auto).
    func transcribe(wavURL: URL, language: String? = nil) async throws -> ASRResult {
        guard let asrManager else { throw TranscriberError.notLoaded }
        let languageHint = language.flatMap(Language.init(rawValue:))
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        return try await asrManager.transcribe(wavURL, decoderState: &decoderState, language: languageHint)
    }

    func shutdown() {
        asrManager = nil
        loadedVersion = nil
    }

    func shutdown(ifLoadedVersion version: AsrModelVersion) {
        guard FluidAudioUnloadPolicy.shouldUnload(
            loadedVersion: loadedVersion,
            deletingVersion: version
        ) else { return }
        shutdown()
    }
}

enum FluidAudioUnloadPolicy {
    static func shouldUnload(
        loadedVersion: AsrModelVersion?,
        deletingVersion: AsrModelVersion
    ) -> Bool {
        loadedVersion == deletingVersion
    }
}
