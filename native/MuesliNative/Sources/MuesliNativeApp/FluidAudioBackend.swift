import FluidAudio
import Foundation
import MuesliCore

/// Native Swift transcription backend using FluidAudio's Parakeet TDT model
/// running via Core ML with a model-specific encoder compute policy.
actor FluidAudioTranscriber {
    typealias ModelLoader = @Sendable (
        String, ((Double, String?) -> Void)?, ModelDownloadProgressHandler?
    ) async throws -> AsrManager

    private var asrManager: AsrManager?
    private(set) var loadedModelID: String?
    private var loadGeneration = UUID()
    private var pendingLoad: (generation: UUID, modelID: String, task: Task<AsrManager, Error>)?
    private let modelLoader: ModelLoader

    init(modelLoader: @escaping ModelLoader = { modelID, progress, progressSnapshot in
        try await FluidAudioTranscriber.prepareModel(
            modelID: modelID, progress: progress, progressSnapshot: progressSnapshot
        )
    }) {
        self.modelLoader = modelLoader
    }

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
        try Task.checkCancellation()
        // Invalidate before the cache hit: selecting loaded A must supersede pending B.
        cancelPendingLoad()
        if loadedModelID == modelID, asrManager != nil { return }
        let generation = loadGeneration
        let task = Task { try await modelLoader(modelID, progress, progressSnapshot) }
        pendingLoad = (generation, modelID, task)
        defer {
            if pendingLoad?.generation == generation { pendingLoad = nil }
        }
        let manager = try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
        // Core ML may finish an uncancellable operation after cancellation.
        try Task.checkCancellation()
        guard loadGeneration == generation, !task.isCancelled else { throw CancellationError() }
        self.asrManager = manager
        self.loadedModelID = modelID
        let preparing = ModelDownloadProgress.preparing(
            modelID: modelID,
            message: ParakeetRuntimePolicy.preparingMessage(for: modelID)
        )
        progress?(1, nil)
        progressSnapshot?(preparing.replacing(phase: .ready, message: "Model ready"))
        fputs("[fluidaudio] models ready\n", stderr)
    }

    private static func prepareModel(
        modelID: String,
        progress: ((Double, String?) -> Void)?,
        progressSnapshot: ModelDownloadProgressHandler?
    ) async throws -> AsrManager {
        let version = FluidAudioModel.version(for: modelID)

        if ParakeetRuntimePolicy.requiresMacOS15(for: modelID), #unavailable(macOS 15) {
            throw TranscriberError.requiresMacOS15(modelID == BackendOption.phonon25.model ? "Phonon-2.5" : "Parakeet Redux")
        }
        fputs("[fluidaudio] downloading/loading models (version: \(version))...\n", stderr)
        let plan = FluidAudioModel.plan(for: modelID)
        let preparingMessage = ParakeetRuntimePolicy.preparingMessage(for: plan.modelID)
        return try await ManagedASRModelDownloader.loadValidated(
            plan,
            progress: progress,
            progressSnapshot: progressSnapshot
        ) { modelDirectory in
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return try await ParakeetRuntimePolicy.prepareLoadedModel(manager, for: plan.modelID) { candidate, samples in
                var state = TdtDecoderState.make(decoderLayers: await candidate.decoderLayerCount)
                _ = try await candidate.transcribe(samples, decoderState: &state)
            }
        }
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

    private func cancelPendingLoad() {
        loadGeneration = UUID()
        pendingLoad?.task.cancel()
        pendingLoad = nil
    }

    func shutdown() {
        cancelPendingLoad()
        asrManager = nil
        loadedModelID = nil
    }

    func shutdown(ifLoadedModelID modelID: String) {
        if pendingLoad?.modelID == modelID { cancelPendingLoad() }
        if FluidAudioUnloadPolicy.shouldUnload(
            loadedModelID: loadedModelID,
            deletingModelID: modelID
        ) {
            // Deleting loaded A must not cancel an unrelated pending B.
            asrManager = nil
            loadedModelID = nil
        }
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
