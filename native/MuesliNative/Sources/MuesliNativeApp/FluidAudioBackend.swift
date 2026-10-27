import FluidAudio
import Foundation
import MuesliCore

/// Native Swift transcription backend using FluidAudio's Parakeet TDT model
/// running via Core ML with a model-specific encoder compute policy.
actor FluidAudioTranscriber {
    private var asrManager: AsrManager?
    private var loadedVersion: AsrModelVersion?
    typealias ModelLoader = (AsrModelVersion, ((Double, String?) -> Void)?, ModelDownloadProgressHandler?) async throws -> AsrManager
    private let modelLoader: ModelLoader

    init(modelLoader: ModelLoader? = nil) {
        self.modelLoader = modelLoader ?? Self.makeManager
    }
    // Swift actors are reentrant across Core ML awaits. Share one permit across
    // previews, final decoding, loading and unloading of this model instance.
    private var decodeBusy = false
    private var decodeWaiters: [CheckedContinuation<Void, Never>] = []

    enum TranscriberError: Error, LocalizedError {
        case notLoaded
        case reduxRequiresMacOS15

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "FluidAudio models not loaded. Call loadModels() first."
            case .reduxRequiresMacOS15:
                return "Parakeet Redux requires macOS 15 or later."
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
        await acquireDecode()
        defer { releaseDecode() }
        try await loadModelsForDecode(version: version, progress: progress, progressSnapshot: progressSnapshot)
    }

    /// Called only while holding the decode permit, so another session cannot
    /// replace the selected model between preparation and inference.
    private func loadModelsForDecode(
        version: AsrModelVersion,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        try Task.checkCancellation()
        if loadedVersion == version, asrManager != nil { return }
        let manager = try await modelLoader(version, progress, progressSnapshot)
        try Task.checkCancellation()
        asrManager = manager
        loadedVersion = version
    }

    private static func makeManager(
        version: AsrModelVersion,
        progress: ((Double, String?) -> Void)?,
        progressSnapshot: ModelDownloadProgressHandler?
    ) async throws -> AsrManager {

        if version == .redux, #unavailable(macOS 15) {
            throw TranscriberError.reduxRequiresMacOS15
        }
        fputs("[fluidaudio] downloading/loading models (version: \(version))...\n", stderr)
        let plan = FluidAudioModel.plan(for: version)
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
            let models = try await AsrModels.load(
                from: modelDirectory,
                version: version,
                encoderComputeUnits: ParakeetRuntimePolicy.encoderComputeUnits(for: plan.modelID)
            )
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        let preparing = ModelDownloadProgress.preparing(
            modelID: plan.modelID,
            message: preparingMessage
        )
        progress?(1, nil)
        progressSnapshot?(preparing.replacing(phase: .ready, message: "Model ready"))
        fputs("[fluidaudio] models ready\n", stderr)
        return manager
    }

    /// Transcribe a WAV file URL directly.
    /// `language` is an optional ISO code enabling FluidAudio's script-level
    /// token filter on the v3 joint decoder (v2 ignores the hint; nil = auto).
    func transcribe(
        wavURL: URL, language: String? = nil, expectedVersion: AsrModelVersion? = nil
    ) async throws -> ASRResult {
        await acquireDecode()
        defer { releaseDecode() }
        try Task.checkCancellation()
        if let expectedVersion { try await loadModelsForDecode(version: expectedVersion) }
        guard let asrManager else { throw TranscriberError.notLoaded }
        let languageHint = language.flatMap(Language.init(rawValue:))
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        return try await asrManager.transcribe(wavURL, decoderState: &decoderState, language: languageHint)
    }

    func transcribePreview(
        samples: [Float], language: String? = nil, expectedVersion: AsrModelVersion = .v3
    ) async throws -> BufferedTranscriptionWindow {
        await acquireDecode()
        defer { releaseDecode() }
        try Task.checkCancellation()
        try await loadModelsForDecode(version: expectedVersion)
        guard let asrManager else { throw TranscriberError.notLoaded }
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(samples, decoderState: &decoderState,
                                                    language: language.flatMap(Language.init(rawValue:)))
        try Task.checkCancellation()
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

    func shutdown() async {
        await acquireDecode()
        defer { releaseDecode() }
        asrManager = nil
        loadedVersion = nil
    }

    func shutdown(ifLoadedVersion version: AsrModelVersion) async {
        await acquireDecode()
        defer { releaseDecode() }
        guard FluidAudioUnloadPolicy.shouldUnload(
            loadedVersion: loadedVersion,
            deletingVersion: version
        ) else { return }
        asrManager = nil
        loadedVersion = nil
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
        loadedVersion: AsrModelVersion?,
        deletingVersion: AsrModelVersion
    ) -> Bool {
        loadedVersion == deletingVersion
    }
}

/// One routing policy for loading, installed-state checks and deleting model files.
enum FluidAudioModel {
    static func version(for modelID: String) -> AsrModelVersion {
        if modelID == BackendOption.parakeetRedux.model { return .redux }
        return modelID.contains("v2") ? .v2 : .v3
    }

    static func plan(for version: AsrModelVersion) -> ManagedASRModelPlan {
        switch version {
        case .v2: return ManagedASRModelPlans.parakeetV2()
        case .redux: return ManagedASRModelPlans.parakeetRedux()
        default: return ManagedASRModelPlans.parakeetV3()
        }
    }
}
