import Foundation
import WhisperKit
import MuesliCore

/// Native Swift transcription backend using WhisperKit (CoreML on ANE/GPU).
actor WhisperKitTranscriber {
    private var whisperKit: WhisperKit?
    private var loadedModel: String?
    typealias ModelLoader = (String, ((Double, String?) -> Void)?, ModelDownloadProgressHandler?) async throws -> WhisperKit
    private let modelLoader: ModelLoader

    init(modelLoader: ModelLoader? = nil) {
        self.modelLoader = modelLoader ?? Self.makeWhisperKit
    }
    private var decodeBusy = false
    private var decodeWaiters: [CheckedContinuation<Void, Never>] = []

    enum TranscriberError: Error, LocalizedError {
        case notLoaded
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notLoaded: return "WhisperKit model not loaded."
            case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
            }
        }
    }

    /// Load a WhisperKit CoreML model. Downloads from HuggingFace if not cached.
    func loadModel(
        modelName: String,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        await acquireDecode()
        defer { releaseDecode() }
        try await loadModelForDecode(modelName: modelName, progress: progress, progressSnapshot: progressSnapshot)
    }

    /// The caller holds the decode permit across model selection and inference.
    private func loadModelForDecode(
        modelName: String,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        try Task.checkCancellation()
        if loadedModel == modelName, whisperKit != nil { return }
        let loadedWhisperKit = try await modelLoader(modelName, progress, progressSnapshot)
        try Task.checkCancellation()
        whisperKit = loadedWhisperKit
        loadedModel = modelName
    }

    private static func makeWhisperKit(
        modelName: String,
        progress: ((Double, String?) -> Void)?,
        progressSnapshot: ModelDownloadProgressHandler?
    ) async throws -> WhisperKit {

        fputs("[whisperkit] loading model: \(modelName)...\n", stderr)
        let plan = ManagedASRModelPlans.whisperKit(modelName: modelName)
        let loadedWhisperKit = try await ManagedASRModelDownloader.loadValidated(
            plan,
            progress: progress,
            progressSnapshot: progressSnapshot
        ) { modelFolder in
            let preparing = ModelDownloadProgress.preparing(
                modelID: plan.modelID,
                message: "Loading WhisperKit into Core ML..."
            )
            progress?(0.95, preparing.message)
            progressSnapshot?(preparing)

            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                )
            )
            return try await WhisperKit(config)
        }

        fputs("[whisperkit] model loaded: \(modelName)\n", stderr)
        return loadedWhisperKit
    }

    /// Transcribe a 16kHz mono WAV file.
    /// - Parameter language: `.auto` enables WhisperKit language detection; otherwise pins that ISO code.
    ///   Ignored for English-only `.en` models, which keep default English decoding.
    func transcribe(
        wavURL: URL,
        language: WhisperKitLanguage = .defaultLanguage,
        expectedModel: String? = nil
    ) async throws -> (text: String, processingTime: Double) {
        await acquireDecode()
        defer { releaseDecode() }
        try Task.checkCancellation()
        if let expectedModel { try await loadModelForDecode(modelName: expectedModel) }
        guard let whisperKit else { throw TranscriberError.notLoaded }
        guard let loadedModel else { throw TranscriberError.notLoaded }

        let start = CFAbsoluteTimeGetCurrent()
        let decodeOptions = Self.makeDecodeOptions(language: language, modelName: loadedModel)
        let results = try await whisperKit.transcribe(audioPath: wavURL.path, decodeOptions: decodeOptions)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text: text, processingTime: elapsed)
    }

    func transcribePreview(
        samples: [Float], language: WhisperKitLanguage = .defaultLanguage, expectedModel: String
    ) async throws -> BufferedTranscriptionWindow {
        await acquireDecode()
        defer { releaseDecode() }
        try Task.checkCancellation()
        try await loadModelForDecode(modelName: expectedModel)
        guard let whisperKit else { throw TranscriberError.notLoaded }
        let options = Self.makePreviewDecodeOptions(language: language, modelName: expectedModel)
        let originalSeeker = whisperKit.segmentSeeker
        whisperKit.segmentSeeker = WhisperPreviewSegmentSeeker()
        defer { whisperKit.segmentSeeker = originalSeeker }
        let results: [TranscriptionResult] = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        try Task.checkCancellation()
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Self.previewWords(from: results.flatMap(\.segments).flatMap { $0.words ?? [] })
        return try Self.previewWindow(text: text, words: words, sampleCount: samples.count)
    }

    static func previewWords(from words: [WordTiming]) -> [BufferedTranscriptionWord] {
        words.map {
            BufferedTranscriptionWord(text: $0.word, start: Double($0.start), end: Double($0.end),
                                      confidence: $0.probability)
        }
    }

    static func makePreviewDecodeOptions(language: WhisperKitLanguage, modelName: String) -> DecodingOptions {
        var options = makeDecodeOptions(language: language, modelName: modelName)
        options.wordTimestamps = true
        // A preview gets another hypothesis as new audio arrives. Re-sampling
        // the same uncertain window up to six times stalls that feedback loop.
        // Final transcription retains its normal quality-oriented fallbacks.
        options.temperatureFallbackCount = 0
        return options
    }

    /// Never publish words aligned to Whisper's padded encoder input. A short
    /// undecodable window is temporary; the session can retry with more context.
    static func previewWindow(text: String, words: [BufferedTranscriptionWord],
                              sampleCount: Int) throws -> BufferedTranscriptionWindow {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, words.isEmpty {
            throw BufferedTranscriptionPreviewDeferral.missingWordTimings
        }
        let duration = Double(sampleCount) / 16_000
        var previousStart = -Double.infinity
        for word in words {
            guard word.start.isFinite, word.end.isFinite, word.start >= 0,
                  word.start >= previousStart, word.end >= word.start,
                  word.end <= duration + 0.25 else {
                throw BufferedTranscriptionPreviewDeferral.invalidWordTimings
            }
            previousStart = word.start
        }
        let aligned: BufferedTranscriptionWindow
        do {
            aligned = try BufferedTranscriptionWindow.aligned(text: text, words: words)
        } catch {
            throw BufferedTranscriptionPreviewDeferral.textAlignmentMismatch
        }
        // A public pause/resume fixture produced three or more lexical words
        // aligned to the same zero-duration point, poisoning an otherwise stable
        // prefix. This narrow preview-quality check is not a speech detector or
        // a general hallucination rule: isolated/pairs of quantized zero words
        // remain valid, as does arbitrarily short positive-duration speech.
        var collapsedTime: Double?
        var collapsedLexicalCount = 0
        for word in aligned.words {
            // Separate punctuation has no independent lexical duration. It must
            // neither trigger this guard nor conceal a collapsed lexical run.
            guard word.text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { continue }
            guard word.start == word.end else {
                collapsedTime = nil
                collapsedLexicalCount = 0
                continue
            }
            collapsedLexicalCount = collapsedTime == word.start ? collapsedLexicalCount + 1 : 1
            collapsedTime = word.start
            if collapsedLexicalCount >= 3 {
                // Keep every token and the PCM pending for a later hypothesis;
                // never filter words or fabricate replacement timestamps.
                throw BufferedTranscriptionPreviewDeferral.collapsedWordTimings
            }
        }
        return aligned
    }

    /// Build WhisperKit decode options for the loaded model.
    /// English-only checkpoints ignore language preference and keep default English decoding.
    static func makeDecodeOptions(
        language: WhisperKitLanguage,
        modelName: String
    ) -> DecodingOptions {
        guard let effective = WhisperKitLanguage.preferenceForLoadedModel(language, modelName: modelName) else {
            return DecodingOptions(skipSpecialTokens: true)
        }
        switch effective {
        case .auto:
            // Default DecodingOptions leaves detectLanguage false when usePrefillPrompt is true,
            // which silently forces English. Request detection explicitly for multilingual models.
            return DecodingOptions(detectLanguage: true, skipSpecialTokens: true)
        default:
            return DecodingOptions(language: effective.rawValue, skipSpecialTokens: true)
        }
    }

    /// Run a short silent transcription to trigger CoreML compilation.
    /// First-run compilation takes 10-30s; subsequent loads are instant.
    func warmup() async throws {
        await acquireDecode()
        defer { releaseDecode() }
        try Task.checkCancellation()
        guard let whisperKit else { return }
        let silence = [Float](repeating: 0, count: 16000) // 1 second of silence at 16kHz
        let start = CFAbsoluteTimeGetCurrent()
        let _: [TranscriptionResult] = try await whisperKit.transcribe(audioArray: silence)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        fputs("[whisperkit] warmup transcription took \(String(format: "%.1f", elapsed))s\n", stderr)
    }

    func shutdown() async {
        await acquireDecode()
        defer { releaseDecode() }
        whisperKit = nil
        loadedModel = nil
    }

    private func acquireDecode() async {
        if !decodeBusy { decodeBusy = true; return }
        await withCheckedContinuation { decodeWaiters.append($0) }
    }

    private func releaseDecode() {
        if decodeWaiters.isEmpty { decodeBusy = false }
        else { decodeWaiters.removeFirst().resume() }
    }

    // MARK: - Model Storage

    /// WhisperKit stores models under ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/.
    /// Each model variant is a direct subdirectory (e.g. openai_whisper-small/).
    static func isModelDownloaded(_ modelName: String) -> Bool {
        ManagedASRModelPlans.whisperKit(modelName: modelName).isAvailableLocally()
    }

    /// Delete cached model files for a WhisperKit model variant.
    static func deleteModel(_ modelName: String) {
        try? ManagedASRModelPlans.whisperKit(modelName: modelName).delete()
    }
}
