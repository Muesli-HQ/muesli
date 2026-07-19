import Foundation
import WhisperKit
import MuesliCore

/// Native Swift transcription backend using WhisperKit (CoreML on ANE/GPU).
actor WhisperKitTranscriber {
    private var whisperKit: WhisperKit?
    private var loadedModel: String?
    private var loadedLanguage: String?

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
    /// `repo` selects the Hugging Face repo (nil = WhisperKit's default
    /// argmaxinc/whisperkit-coreml); community fine-tunes such as the ivrit.ai
    /// Hebrew model live in their own repos. `language` is remembered so
    /// transcription can pin it (fine-tunes often require an explicit language).
    func loadModel(
        modelName: String,
        repo: String? = nil,
        language: String? = nil,
        progress: ((Double, String?) -> Void)? = nil
    ) async throws {
        if loadedModel == modelName, whisperKit != nil {
            loadedLanguage = language
            return
        }

        fputs("[whisperkit] loading model: \(modelName)...\n", stderr)
        let modelFolder: URL?

        if Self.isModelDownloaded(modelName, repo: repo) {
            modelFolder = nil
        } else {
            let estimatedTotalBytes = Self.estimatedDownloadBytes(for: modelName)
            let totalText = Self.formatMegabytes(estimatedTotalBytes)
            progress?(0.02, "0 MB of \(totalText)")
            modelFolder = try await WhisperKit.download(
                variant: modelName,
                from: repo ?? "argmaxinc/whisperkit-coreml"
            ) { downloadProgress in
                let fraction = min(max(downloadProgress.fractionCompleted, 0), 1)
                let estimatedBytes = Int64(Double(estimatedTotalBytes) * fraction)
                let completedText = Self.formatMegabytes(estimatedBytes)
                let throughput = downloadProgress.userInfo[.throughputKey] as? Double ?? 0
                let status: String
                if throughput > 0 {
                    status = "\(completedText) of \(totalText) • \(Self.formatMegabytes(Int64(throughput)))/s"
                } else {
                    status = "\(completedText) of \(totalText)"
                }
                progress?(max(fraction, 0.02), status)
            }
        }

        let config = WhisperKitConfig(
            model: modelFolder == nil ? modelName : nil,
            modelRepo: repo,
            modelFolder: modelFolder?.path ?? Self.cachedModelFolder(modelName, repo: repo),
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        )

        whisperKit = try await WhisperKit(config)
        loadedModel = modelName
        loadedLanguage = language
        fputs("[whisperkit] model ready: \(modelName)\n", stderr)
    }

    private static func estimatedDownloadBytes(for modelName: String) -> Int64 {
        switch modelName {
        case "tiny.en":
            return 153 * 1_000_000
        case "small.en":
            return 250 * 1_000_000
        case "medium.en":
            return 1_500 * 1_000_000
        case "large-v3-v20240930_626MB":
            return 626 * 1_000_000
        case "ivrit-ai_whisper-large-v3-turbo":
            return 1_620 * 1_000_000
        default:
            return 250 * 1_000_000
        }
    }

    private static func formatMegabytes(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_000_000
        if megabytes >= 1_000 {
            return String(format: "%.1f GB", megabytes / 1_000)
        }
        if megabytes >= 100 {
            return "\(Int(megabytes.rounded())) MB"
        }
        return String(format: "%.1f MB", megabytes)
    }

    /// Transcribe a 16kHz mono WAV file.
    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard let whisperKit else { throw TranscriberError.notLoaded }

        let start = CFAbsoluteTimeGetCurrent()
        let results: [TranscriptionResult]
        if let language = loadedLanguage {
            let options = DecodingOptions(task: .transcribe, language: language)
            results = try await whisperKit.transcribe(audioPath: wavURL.path, decodeOptions: options)
        } else {
            results = try await whisperKit.transcribe(audioPath: wavURL.path)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text: text, processingTime: elapsed)
    }

    /// Run a short silent transcription to trigger CoreML compilation.
    /// First-run compilation takes 10-30s; subsequent loads are instant.
    func warmup() async throws {
        guard let whisperKit else { return }
        let silence = [Float](repeating: 0, count: 16000) // 1 second of silence at 16kHz
        let start = CFAbsoluteTimeGetCurrent()
        let _: [TranscriptionResult] = try await whisperKit.transcribe(audioArray: silence)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        fputs("[whisperkit] warmup transcription took \(String(format: "%.1f", elapsed))s\n", stderr)
    }

    func shutdown() {
        whisperKit = nil
        loadedModel = nil
        loadedLanguage = nil
    }

    // MARK: - Model Storage

    /// WhisperKit stores models under ~/Documents/huggingface/models/<repo>/.
    /// For the default argmax repo, each variant is prefixed with
    /// "openai_whisper-" (e.g. openai_whisper-small.en/); custom repos use the
    /// variant name as the directory as-is.
    static func modelDirectory(_ modelName: String, repo: String? = nil) -> URL {
        let repoPath = repo ?? "argmaxinc/whisperkit-coreml"
        let fullName: String
        if repo == nil {
            fullName = modelName.hasPrefix("openai_whisper-") ? modelName : "openai_whisper-\(modelName)"
        } else {
            fullName = modelName
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/\(repoPath)/\(fullName)")
    }

    private static func cachedModelFolder(_ modelName: String, repo: String?) -> String? {
        guard repo != nil else { return nil }
        return modelDirectory(modelName, repo: repo).path
    }

    /// Check if this model's files exist on disk.
    static func isModelDownloaded(_ modelName: String, repo: String? = nil) -> Bool {
        FileManager.default.fileExists(atPath: modelDirectory(modelName, repo: repo).path)
    }

    /// Delete cached model files for a WhisperKit model variant.
    static func deleteModel(_ modelName: String, repo: String? = nil) {
        try? FileManager.default.removeItem(at: modelDirectory(modelName, repo: repo))
    }
}
