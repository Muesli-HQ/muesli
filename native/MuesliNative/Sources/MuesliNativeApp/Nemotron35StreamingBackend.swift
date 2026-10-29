import Accelerate
import MuesliCore
@preconcurrency import CoreML
import Foundation

/// Native RNNT streaming ASR backend for NVIDIA Nemotron 3.5 ASR Streaming (multilingual).
/// Runs entirely on Apple Neural Engine via CoreML.
///
/// Pipeline: audio → preprocessor(mel) → encoder(with cache + prompt_id) → decoder+joint(RNNT greedy) → tokens
/// Model: FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML (multilingual/2240ms variant)
///
/// The per-model `NemotronRNNTConfig` below captures cache geometry, vocab/blank,
/// chunk length, the language `prompt_id`, and `<…>` tag stripping. The shared
/// chunk pipeline lives in `NemotronRNNTEngine`.
@available(macOS 15, iOS 18, *)
actor Nemotron35StreamingTranscriber: NemotronStreamingTranscribing {
    typealias Prediction = @Sendable (NemotronRNNTConfig, [Float], inout RNNTStreamState) async throws -> [Int]
    struct Models: Sendable {
        let revision: String?
        let tokenizer: [Int: String]
        let predict: Prediction
    }
    typealias ModelLoader = @Sendable (((Double, String?) -> Void)?, ModelDownloadProgressHandler?) async throws -> Models
    private var models: Models?
    private let modelLoader: ModelLoader
    private let revision: @Sendable () -> String?
    private let onWait: (@Sendable () -> Void)?
    private var isLoading = false
    private let inferenceGate = InferenceGate()

    init(modelLoader: @escaping ModelLoader = {
        try await Nemotron35StreamingTranscriber.loadModelFiles(progress: $0, progressSnapshot: $1)
    }, revision: @escaping @Sendable () -> String? = { Nemotron35StreamingTranscriber.installedRevision() },
         onWait: (@Sendable () -> Void)? = nil) {
        self.modelLoader = modelLoader
        self.revision = revision
        self.onWait = onWait
    }

    /// Selected language `prompt_id` fed to the encoder (101 = auto-detect).
    /// Set from app config via `setPromptId(_:)` before dictation.
    private var promptId: Int32 = 101

    /// Multilingual config from metadata.json (multilingual/2240ms variant).
    /// Geometry: chunk_mel_frames 224 + pre_encode_cache 9 = total 233; 8× subsampling
    /// → 28 encoder frames/chunk; chunkSamples = 2240ms · 16kHz = 35840.
    private var config: NemotronRNNTConfig {
        NemotronRNNTConfig(
            chunkSamples: 35840,
            cacheChannelFrames: 42,      // att_context left
            totalMelFrames: 233,
            encoderDim: 1024,
            decoderHiddenSize: 640,
            blankTokenId: 13087,         // = vocab_size (last logit index)
            promptId: promptId,          // selected language (auto = 101)
            stripAngleBracketTags: true  // drop <lang>/<unk> tags the model emits
        )
    }

    typealias StreamState = RNNTStreamState
    typealias TranscriberError = NemotronRNNTError

    /// Samples per streaming chunk — read cross-actor by the runtime/controller to
    /// size the audio buffer (must match config.chunkSamples).
    nonisolated let chunkSamples = 35840

    /// Set the language prompt id used for subsequent transcriptions.
    func setPromptId(_ id: Int32) {
        promptId = id
    }

    // MARK: - Model Loading

    private static var cacheDir: URL { Nemotron35ModelStore.cacheDirectory() }

    func loadModels(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        try Task.checkCancellation()
        // A complete, current model can be observed while a prediction owns inference.
        if !isLoading, let models, models.revision == revision() { return }
        try await inferenceGate.withReservation(onWait: onWait) {
            try await self.prepareModels(progress: progress, progressSnapshot: progressSnapshot)
        }
    }

    /// The caller owns inferenceGate; preparation must never reacquire it.
    private func prepareModels(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        if let models, models.revision == revision() { return }
        isLoading = true
        defer { isLoading = false }
        models = nil
        do {
            models = try await modelLoader(progress, progressSnapshot)
            try Task.checkCancellation()
        } catch {
            models = nil
            throw error
        }
    }

    private static func loadModelFiles(
        progress: ((Double, String?) -> Void)?, progressSnapshot: ModelDownloadProgressHandler?
    ) async throws -> Models {
        let modelDir = try await ensureModelsDownloaded(progress: progress, progressSnapshot: progressSnapshot)
        let installedRevision = installedRevision()
        fputs("[nemotron35] loading CoreML models...\n", stderr)
        progressSnapshot?(ModelDownloadProgress.preparing(modelID: Nemotron35ModelStore.repoID, message: "Preparing Nemotron 3.5 Core ML models..."))
        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = .all

        let preprocessor = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("preprocessor.mlmodelc"), configuration: mlConfig)
        let encoder = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("encoder.mlmodelc"), configuration: mlConfig)
        let decoder = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("decoder.mlmodelc"), configuration: mlConfig)
        let joint = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("joint.mlmodelc"), configuration: mlConfig)

        // Load tokenizer: {id_string: token_string}
        let tokenizerURL = modelDir.appendingPathComponent("tokenizer.json")
        let tokenizerData = try Data(contentsOf: tokenizerURL)
        var tokenizer: [Int: String] = [:]
        if let json = try JSONSerialization.jsonObject(with: tokenizerData) as? [String: String] {
            for (key, value) in json {
                if let id = Int(key) {
                    tokenizer[id] = value
                }
            }
        }

        fputs("[nemotron35] models ready (\(tokenizer.count) vocab tokens)\n", stderr)
        return Models(revision: installedRevision, tokenizer: tokenizer) { config, samples, state in
            try await nemotronTranscribeChunk(preprocessor: preprocessor, encoder: encoder,
                decoder: decoder, joint: joint, config: config, samples: samples, state: &state)
        }
    }

    // MARK: - Streaming API

    func makeStreamState() throws -> StreamState {
        try nemotronMakeStreamState(config: config)
    }

    /// Process one 2240ms audio chunk (35840 samples) and return newly decoded text.
    func transcribeChunk(samples: [Float], state: inout StreamState) async throws -> String {
        try await inferenceGate.withReservation(onWait: onWait) {
            guard let models = self.models else { throw TranscriberError.notLoaded }
            return try await self.transcribeChunkReserved(samples: samples, state: &state,
                models: models, config: self.config)
        }
    }

    private func transcribeChunkReserved(samples: [Float], state: inout StreamState,
                                         models: Models, config: NemotronRNNTConfig) async throws -> String {
        try Task.checkCancellation()
        let newTokens = try await models.predict(config, samples, &state)
        return nemotronDecodeTokens(newTokens, tokenizer: models.tokenizer,
            stripAngleBracketTags: config.stripAngleBracketTags, trim: false)
    }

    // MARK: - Convenience (full-file transcription)

    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        let (models, config) = try await inferenceGate.withReservation(onWait: onWait) {
            let config = self.config // Prompt changes apply to subsequent work, not this file.
            try await self.prepareModels()
            guard let models = self.models else { throw TranscriberError.notLoaded }
            return (models, config)
        }
        // The immutable bundle retains every model and tokenizer across reload/shutdown.
        let samples = try nemotronLoadWavAsFloats(url: wavURL)
        let start = CFAbsoluteTimeGetCurrent()
        var state = try nemotronMakeStreamState(config: config)
        var sampleOffset = 0
        while sampleOffset < samples.count {
            let chunkEnd = min(sampleOffset + config.chunkSamples, samples.count)
            let chunk = Array(samples[sampleOffset..<chunkEnd])
            _ = try await inferenceGate.withReservation(onWait: onWait) {
                try await self.transcribeChunkReserved(samples: chunk, state: &state,
                    models: models, config: config)
            }
            sampleOffset += config.chunkSamples
        }
        let text = nemotronDecodeTokens(state.allTokens, tokenizer: models.tokenizer,
            stripAngleBracketTags: config.stripAngleBracketTags, trim: true)
        return (text, CFAbsoluteTimeGetCurrent() - start)
    }

    func shutdown() async {
        _ = try? await inferenceGate.withReservation(onWait: onWait) { self.models = nil }
    }

    // MARK: - Model Download

    static let repoID = Nemotron35ModelStore.repoID

    // MARK: - Update detection

    /// The HuggingFace commit sha recorded when the model was last downloaded, if any.
    nonisolated static func installedRevision() -> String? {
        Nemotron35ModelStore.installedRevision()
    }

    /// The repo's current `main` commit sha (one lightweight HF API call), or nil on failure.
    static func fetchRemoteRevision() async -> String? {
        await Nemotron35ModelStore.fetchRemoteRevision()
    }

    /// True only when a model is installed with a known revision that differs from the
    /// repo's current `main`. Returns false when nothing is installed, the revision is
    /// unknown (downloaded before this was tracked), or the network check fails — so it
    /// never produces a false "update available".
    static func updateAvailable() async -> Bool {
        guard let local = installedRevision(), let remote = await fetchRemoteRevision() else { return false }
        return local != remote
    }

    private static func ensureModelsDownloaded(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws -> URL {
        let modelDir = Self.cacheDir
        if Nemotron35ModelStore.isModelDownloaded() {
            fputs("[nemotron35] models already cached\n", stderr)
            return modelDir
        }

        fputs("[nemotron35] downloading multilingual/2240ms variant from HuggingFace...\n", stderr)
        _ = try await Nemotron35ModelStore.ensureDownloaded(progress: progress, progressSnapshot: progressSnapshot)

        fputs("[nemotron35] download complete\n", stderr)
        return modelDir
    }
}
