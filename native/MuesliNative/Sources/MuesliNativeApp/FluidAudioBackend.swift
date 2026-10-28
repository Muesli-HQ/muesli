import FluidAudio
import Foundation
import MuesliCore

/// Native Swift transcription backend using FluidAudio's Parakeet TDT model
/// running via Core ML with a model-specific encoder compute policy.
actor FluidAudioTranscriber {
    typealias ModelLoader = @Sendable (
        String, Bool, ((Double, String?) -> Void)?, ModelDownloadProgressHandler?
    ) async throws -> AsrManager

    private var asrManager: AsrManager?
    private(set) var loadedModelID: String?
    private var loadGeneration = UUID()
    private struct PendingLoad {
        let generation: UUID
        let modelID: String
        let allowDownload: Bool
        let task: Task<AsrManager, Error>
        var waiters: Set<UUID>
    }
    private var pendingLoad: PendingLoad?
    private let modelLoader: ModelLoader

    init(modelLoader: @escaping ModelLoader = { modelID, allowDownload, progress, progressSnapshot in
        try await FluidAudioTranscriber.prepareModel(
            modelID: modelID, allowDownload: allowDownload, progress: progress, progressSnapshot: progressSnapshot
        )
    }) {
        self.modelLoader = modelLoader
    }

    private var decodeBusy = false
    private var decodeWaiters: [CheckedContinuation<Void, Never>] = []

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
        allowDownload: Bool = true,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        try Task.checkCancellation()
        let callerID = UUID()
        let operation: PendingLoad
        if var pending = pendingLoad, pending.modelID == modelID, pending.allowDownload == allowDownload {
            // Independent dictation/meeting callers can share the same preparation.
            pending.waiters.insert(callerID)
            pendingLoad = pending
            operation = pending
            progressSnapshot?(.preparing(modelID: modelID,
                message: ParakeetRuntimePolicy.preparingMessage(for: modelID)))
        } else {
            // Invalidate before the cache hit: selecting loaded A supersedes pending B.
            cancelPendingLoad()
            if loadedModelID == modelID, asrManager != nil { return }
            let task = Task { try await modelLoader(modelID, allowDownload, progress, progressSnapshot) }
            operation = PendingLoad(generation: loadGeneration, modelID: modelID,
                allowDownload: allowDownload, task: task, waiters: [callerID])
            pendingLoad = operation
        }
        defer { removeWaiter(callerID, generation: operation.generation) }
        let manager = try await withTaskCancellationHandler(operation: {
            try await operation.task.value
        }, onCancel: {
            // Cancellation detaches this caller; another caller may still need the model.
            Task { await self.removeWaiter(callerID, generation: operation.generation) }
        })
        // Core ML may finish an uncancellable operation after cancellation.
        try Task.checkCancellation()
        guard loadGeneration == operation.generation, !operation.task.isCancelled else { throw CancellationError() }
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

    func loadModels(version: AsrModelVersion) async throws {
        try await loadModels(modelID: FluidAudioModel.modelID(for: version))
    }

    private static func prepareModel(
        modelID: String,
        allowDownload: Bool,
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
            allowDownload: allowDownload,
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
    func transcribe(wavURL: URL, language: String? = nil, expectedModelID: String? = nil,
                    expectedVersion: AsrModelVersion? = nil) async throws -> ASRResult {
        await acquireDecode()
        defer { releaseDecode() }
        try Task.checkCancellation()
        if let modelID = expectedModelID ?? expectedVersion.map(FluidAudioModel.modelID) {
            try await loadModels(modelID: modelID)
        }
        guard let asrManager else { throw TranscriberError.notLoaded }
        let languageHint = language.flatMap(Language.init(rawValue:))
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        return try await asrManager.transcribe(wavURL, decoderState: &decoderState, language: languageHint)
    }

    func transcribePreview(
        samples: [Float], language: String? = nil, expectedVersion: AsrModelVersion = .v3,
        expectedModelID: String? = nil, requiresWordTimings: Bool = true
    ) async throws -> BufferedTranscriptionWindow {
        await acquireDecode()
        defer { releaseDecode() }
        try Task.checkCancellation()
        // Preview work may restore another already-installed model, but must
        // never download or repair a cache as a side effect of live captions.
        try await loadModels(modelID: expectedModelID ?? FluidAudioModel.modelID(for: expectedVersion), allowDownload: false)
        guard let asrManager else { throw TranscriberError.notLoaded }
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(samples, decoderState: &decoderState,
                                                    language: language.flatMap(Language.init(rawValue:)))
        try Task.checkCancellation()
        guard requiresWordTimings else { return .init(text: result.text, words: []) }
        let words = FluidAudioBufferedWordTimings.build(from: result.tokenTimings ?? [])
        return try Self.previewWindow(text: result.text, words: words)
    }

    static func previewWindow(text: String, words: [BufferedTranscriptionWord]) throws -> BufferedTranscriptionWindow {
        do {
            return try BufferedTranscriptionWindow.aligned(text: text, words: words)
        } catch BufferedTranscriptionSession.Failure.invalidTimings {
            // Text/token disagreement can recover when the next window supplies
            // more context. Decoder errors remain fatal and never reach here.
            throw BufferedTranscriptionPreviewDeferral.textAlignmentMismatch
        }
    }

    private func removeWaiter(_ callerID: UUID, generation: UUID) {
        guard var pending = pendingLoad, pending.generation == generation,
              pending.waiters.remove(callerID) != nil else { return }
        if pending.waiters.isEmpty {
            pendingLoad = nil
            pending.task.cancel()
        } else {
            pendingLoad = pending
        }
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
    private func acquireDecode() async {
        if !decodeBusy { decodeBusy = true; return }
        await withCheckedContinuation { decodeWaiters.append($0) }
    }

    private func releaseDecode() {
        if decodeWaiters.isEmpty { decodeBusy = false }
        else { decodeWaiters.removeFirst().resume() }
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
    static func modelID(for version: AsrModelVersion) -> String {
        switch version {
        case .v2: return BackendOption.parakeetEnglish.model
        case .redux: return BackendOption.parakeetRedux.model
        default: return BackendOption.parakeetMultilingual.model
        }
    }

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
