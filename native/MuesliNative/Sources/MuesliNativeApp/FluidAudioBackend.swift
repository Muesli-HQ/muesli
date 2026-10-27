import FluidAudio
import Foundation
import MuesliCore

/// Native Swift transcription backend using FluidAudio's Parakeet TDT model
/// running via Core ML with a model-specific encoder compute policy.
actor FluidAudioTranscriber {
    private var asrManager: AsrManager?
    private var loadedModelID: String?

    enum TranscriberError: Error, LocalizedError {
        case notLoaded
        case requiresMacOS15(String)

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "FluidAudio models not loaded. Call loadModels() first."
            case .requiresMacOS15(let name):
                return "\(name) requires macOS 15 or later."
            }
        }
    }

    /// Downloads models (if needed) and initializes the ASR manager.
    /// Identify weights independently of their shared FluidAudio decoder contract.
    func loadModels(
        modelID: String = BackendOption.parakeetMultilingual.model,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        if loadedModelID == modelID, asrManager != nil { return }
        let version = FluidAudioModel.version(for: modelID)

        if ParakeetRuntimePolicy.requiresMacOS15(for: modelID), #unavailable(macOS 15) {
            throw TranscriberError.requiresMacOS15(modelID == BackendOption.phonon25.model ? "Phonon-2.5" : "Parakeet Redux")
        }
        fputs("[fluidaudio] downloading/loading models (version: \(version))...\n", stderr)
        let plan = FluidAudioModel.plan(for: modelID)
        let preparingMessage = ParakeetRuntimePolicy.preparingMessage(for: plan.modelID)
        let manager = try await ManagedASRModelDownloader.loadValidated(
            plan,
            progress: progress,
            progressSnapshot: progressSnapshot
        ) { modelDirectory in
            let preparing = ModelDownloadProgress.preparing(
                modelID: plan.modelID,
                message: preparingMessage
            )
            progress?(0.95, preparing.message)
            progressSnapshot?(preparing)
            let models: AsrModels
            if ParakeetRuntimePolicy.usesLocalComponents(for: plan.modelID) {
                models = try AsrModels.loadLocal(
                    from: modelDirectory, version: version,
                    encoderComputeUnits: ParakeetRuntimePolicy.encoderComputeUnits(for: plan.modelID)
                )
            } else {
                models = try await AsrModels.load(
                    from: modelDirectory, version: version,
                    encoderComputeUnits: ParakeetRuntimePolicy.encoderComputeUnits(for: plan.modelID)
                )
            }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return try await ParakeetRuntimePolicy.prepareLoadedModel(manager, for: plan.modelID) { candidate, samples in
                var state = TdtDecoderState.make(decoderLayers: await candidate.decoderLayerCount)
                _ = try await candidate.transcribe(samples, decoderState: &state)
            }
        }
        self.asrManager = manager
        self.loadedModelID = modelID
        let preparing = ModelDownloadProgress.preparing(
            modelID: plan.modelID,
            message: preparingMessage
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
        loadedModelID = nil
    }

    func shutdown(ifLoadedModelID modelID: String) {
        guard FluidAudioUnloadPolicy.shouldUnload(
            loadedModelID: loadedModelID,
            deletingModelID: modelID
        ) else { return }
        shutdown()
    }
}

enum FluidAudioUnloadPolicy {
    static func shouldUnload(
        loadedModelID: String?,
        deletingModelID: String
    ) -> Bool {
        loadedModelID == deletingModelID
    }
}

/// One routing policy for loading, installed-state checks and deleting model files.
enum FluidAudioModel {
    static func version(for modelID: String) -> AsrModelVersion {
        if modelID == BackendOption.parakeetRedux.model { return .redux }
        return modelID.contains("v2") ? .v2 : .v3
    }

    static func plan(for modelID: String) -> ManagedASRModelPlan {
        switch modelID {
        case BackendOption.parakeetEnglish.model: return ManagedASRModelPlans.parakeetV2()
        case BackendOption.parakeetRedux.model: return ManagedASRModelPlans.parakeetRedux()
        case BackendOption.phonon25.model: return ManagedASRModelPlans.phonon25()
        default: return ManagedASRModelPlans.parakeetV3()
        }
    }
}
