import FluidAudio
import Foundation
import MuesliCore

/// Native Swift transcription backend using FluidAudio's Parakeet TDT model
/// running on Apple's Neural Engine (ANE) via CoreML.
actor FluidAudioTranscriber {
    private var asrManager: AsrManager?
    private var loadedVersion: AsrModelVersion?
    private var loadedOrukeet = false
    private var loadGeneration = UUID()
    private var requestedSelection: ModelSelection?

    enum ModelSelection: Equatable {
        case parakeet(AsrModelVersion)
        case orukeet
    }
    typealias ManagerLoader = (ModelSelection, ((Double, String?) -> Void)?, ModelDownloadProgressHandler?) async throws -> AsrManager
    private let managerLoader: ManagerLoader?

    init(managerLoader: ManagerLoader? = nil) {
        self.managerLoader = managerLoader
    }

    private func beginLoad(_ selection: ModelSelection) -> UUID {
        // Overlapping requests for the same model belong to one selection epoch.
        // Keep that identity after one finishes while another is still loading.
        if requestedSelection != selection {
            loadGeneration = UUID()
            requestedSelection = selection
        }
        return loadGeneration
    }

    private func invalidateLoad(_ selection: ModelSelection) {
        if requestedSelection == selection {
            loadGeneration = UUID()
            requestedSelection = nil
        }
    }

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
        let generation = beginLoad(.parakeet(version))
        if loadedVersion == version, asrManager != nil { return }

        fputs("[fluidaudio] downloading/loading models (version: \(version))...\n", stderr)
        let plan = version == .v2 ? ManagedASRModelPlans.parakeetV2() : ManagedASRModelPlans.parakeetV3()
        let manager: AsrManager
        if let managerLoader {
            manager = try await managerLoader(.parakeet(version), progress, progressSnapshot)
        } else {
            manager = try await ManagedASRModelDownloader.loadValidated(
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
        }
        try Task.checkCancellation()
        guard loadGeneration == generation else { throw CancellationError() }
        self.asrManager = manager
        self.loadedVersion = version
        self.loadedOrukeet = false
        let preparing = ModelDownloadProgress.preparing(
            modelID: plan.modelID,
            message: "Loading Parakeet into Core ML..."
        )
        progress?(1, nil)
        progressSnapshot?(preparing.replacing(phase: .ready, message: "Model ready"))
        fputs("[fluidaudio] models ready\n", stderr)
    }

    func loadOrukeet(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        let generation = beginLoad(.orukeet)
        if loadedOrukeet, asrManager != nil { return }
        let manager: AsrManager
        if let managerLoader {
            manager = try await managerLoader(.orukeet, progress, progressSnapshot)
        } else {
            let models = try await OrukeetModelStore.prepare(progress: progress, progressSnapshot: progressSnapshot)
            manager = AsrManager(config: .default)
            try await manager.loadModels(models)
        }
        try Task.checkCancellation()
        guard loadGeneration == generation else { throw CancellationError() }
        asrManager = manager
        loadedVersion = nil // Orukeet must never share Parakeet v3's loaded identity.
        loadedOrukeet = true
        progress?(1, nil)
        progressSnapshot?(ModelDownloadProgress.preparing(modelID: OrukeetModelStore.modelID, message: "Model ready")
            .replacing(phase: .ready, message: "Model ready"))
    }

    func shutdownOrukeet() {
        invalidateLoad(.orukeet)
        guard loadedOrukeet else { return }
        clearLoadedModels()
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
        loadGeneration = UUID()
        requestedSelection = nil
        clearLoadedModels()
    }

    private func clearLoadedModels() {
        asrManager = nil
        loadedVersion = nil
        loadedOrukeet = false
    }

    func shutdown(ifLoadedVersion version: AsrModelVersion) {
        invalidateLoad(.parakeet(version))
        guard FluidAudioUnloadPolicy.shouldUnload(
            loadedVersion: loadedVersion,
            deletingVersion: version
        ) else { return }
        clearLoadedModels()
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
