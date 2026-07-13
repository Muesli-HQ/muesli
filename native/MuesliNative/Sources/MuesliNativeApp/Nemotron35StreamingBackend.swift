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
    private var preprocessor: MLModel?
    private var encoder: MLModel?
    private var decoder: MLModel?
    private var joint: MLModel?
    private var tokenizer: [Int: String] = [:]
    private var loaded = false
    private var loadedRevision: String?
    private var isLoading = false
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []
    private var loadGeneration = 0
    private let inferenceGate = InferenceGate()

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

    private static let cacheDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models/nemotron35-multilingual-2240ms", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func loadModels(progress: ((Double, String?) -> Void)? = nil) async throws {
        if loaded, loadedRevision == Self.installedRevision() { return }
        if isLoading {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                loadWaiters.append(continuation)
            }
            return
        }

        isLoading = true
        let generation = loadGeneration
        do {
            try await performLoadModels(progress: progress, generation: generation)
            isLoading = false
            completeLoadWaiters()
        } catch {
            isLoading = false
            completeLoadWaiters(throwing: error)
            throw error
        }
    }

    private func performLoadModels(
        progress: ((Double, String?) -> Void)? = nil,
        generation: Int
    ) async throws {
        let modelDir = try await ensureModelsDownloaded(progress: progress)
        let installedRevision = Self.installedRevision()
        if loaded, loadedRevision == installedRevision { return }
        if loaded {
            clearLoadedModels()
        }

        fputs("[nemotron35] loading CoreML models...\n", stderr)
        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = .all

        preprocessor = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("preprocessor.mlmodelc"), configuration: mlConfig)
        encoder = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("encoder.mlmodelc"), configuration: mlConfig)
        decoder = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("decoder.mlmodelc"), configuration: mlConfig)
        joint = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("joint.mlmodelc"), configuration: mlConfig)

        // Load tokenizer: {id_string: token_string}
        let tokenizerURL = modelDir.appendingPathComponent("tokenizer.json")
        let tokenizerData = try Data(contentsOf: tokenizerURL)
        if let json = try JSONSerialization.jsonObject(with: tokenizerData) as? [String: String] {
            for (key, value) in json {
                if let id = Int(key) {
                    tokenizer[id] = value
                }
            }
        }

        guard generation == loadGeneration else {
            preprocessor = nil; encoder = nil; decoder = nil; joint = nil
            tokenizer = [:]
            throw TranscriberError.notLoaded
        }

        loaded = true
        loadedRevision = installedRevision
        fputs("[nemotron35] models ready (\(tokenizer.count) vocab tokens)\n", stderr)
    }

    private func clearLoadedModels() {
        preprocessor = nil
        encoder = nil
        decoder = nil
        joint = nil
        tokenizer = [:]
        loaded = false
        loadedRevision = nil
    }

    private func completeLoadWaiters(throwing error: Error? = nil) {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }

    // MARK: - Streaming API

    func makeStreamState() throws -> StreamState {
        try nemotronMakeStreamState(config: config)
    }

    /// Process one 2240ms audio chunk (35840 samples) and return newly decoded text.
    func transcribeChunk(samples: [Float], state: inout StreamState) async throws -> String {
        guard loaded, let preprocessor, let encoder, let decoder, let joint else {
            throw TranscriberError.notLoaded
        }
        // Actor methods can re-enter while Core ML predictions await. Serialize
        // shared-model inference while each caller retains its own stream state.
        try await inferenceGate.acquire()
        do {
            try Task.checkCancellation()
            let newTokens = try await nemotronTranscribeChunk(
                preprocessor: preprocessor, encoder: encoder, decoder: decoder, joint: joint,
                config: config, samples: samples, state: &state)
            let text = nemotronDecodeTokens(
                newTokens, tokenizer: tokenizer,
                stripAngleBracketTags: config.stripAngleBracketTags, trim: false)
            await inferenceGate.release()
            return text
        } catch {
            await inferenceGate.release()
            throw error
        }
    }

    // MARK: - Convenience (full-file transcription)

    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard loaded else { throw TranscriberError.notLoaded }

        let samples = try nemotronLoadWavAsFloats(url: wavURL)
        let start = CFAbsoluteTimeGetCurrent()

        var state = try makeStreamState()
        var sampleOffset = 0

        while sampleOffset < samples.count {
            let chunkEnd = min(sampleOffset + config.chunkSamples, samples.count)
            let chunk = Array(samples[sampleOffset..<chunkEnd])
            _ = try await transcribeChunk(samples: chunk, state: &state)
            sampleOffset += config.chunkSamples
        }

        let text = nemotronDecodeTokens(
            state.allTokens, tokenizer: tokenizer,
            stripAngleBracketTags: config.stripAngleBracketTags, trim: true)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        return (text: text, processingTime: elapsed)
    }

    func shutdown() {
        loadGeneration += 1
        clearLoadedModels()
        isLoading = false
        completeLoadWaiters(throwing: TranscriberError.notLoaded)
    }

    // MARK: - Model Download

    static let repoID = "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"
    private static let variantPath = "multilingual/2240ms"
    private static var revisionFile: URL { cacheDir.appendingPathComponent(".revision") }

    // MARK: - Update detection

    /// The HuggingFace commit sha recorded when the model was last downloaded, if any.
    nonisolated static func installedRevision() -> String? {
        guard let s = try? String(contentsOf: revisionFile, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The repo's current `main` commit sha (one lightweight HF API call), or nil on failure.
    static func fetchRemoteRevision() async -> String? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = obj["sha"] as? String else { return nil }
        return sha
    }

    /// True only when a model is installed with a known revision that differs from the
    /// repo's current `main`. Returns false when nothing is installed, the revision is
    /// unknown (downloaded before this was tracked), or the network check fails — so it
    /// never produces a false "update available".
    static func updateAvailable() async -> Bool {
        guard let local = installedRevision(), let remote = await fetchRemoteRevision() else { return false }
        return local != remote
    }

    private func ensureModelsDownloaded(progress: ((Double, String?) -> Void)? = nil) async throws -> URL {
        let modelDir = Self.cacheDir
        let requiredFile = modelDir.appendingPathComponent("encoder.mlmodelc/coremldata.bin")
        if FileManager.default.fileExists(atPath: requiredFile.path) {
            fputs("[nemotron35] models already cached\n", stderr)
            return modelDir
        }

        fputs("[nemotron35] downloading multilingual/2240ms variant from HuggingFace...\n", stderr)
        progress?(0.0, "Downloading Nemotron 3.5 model...")

        let hfAPI = "https://huggingface.co/api/models/\(Self.repoID)/tree/main/\(Self.variantPath)"
        var filesDownloaded = 0
        // Skip the fused decoder_joint — we run decoder + joint separately (saves ~49 MB).
        try await nemotronDownloadHuggingFaceTree(
            repoID: Self.repoID, apiURL: hfAPI, remotePath: Self.variantPath,
            localDir: modelDir, skipRelativePrefix: "decoder_joint.mlmodelc", logPrefix: "[nemotron35]"
        ) {
            filesDownloaded += 1
            progress?(min(Double(filesDownloaded) / 30.0, 0.95), "Downloading Nemotron 3.5 model...")
        }

        // Record the repo revision so we can later detect upstream updates.
        if let sha = await Self.fetchRemoteRevision() {
            try? sha.write(to: Self.revisionFile, atomically: true, encoding: .utf8)
        }

        fputs("[nemotron35] download complete\n", stderr)
        return modelDir
    }
}
