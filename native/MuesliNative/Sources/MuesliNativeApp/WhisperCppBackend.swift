import Foundation
import WhisperKit
import MuesliCore

/// Native Swift transcription backend using WhisperKit (CoreML on ANE/GPU).
actor WhisperKitTranscriber {
    private var whisperKit: WhisperKit?
    private var loadedModel: String?

    static var transcriptionDecodingOptions: DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: nil,
            detectLanguage: true
        )
    }

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
    func loadModel(modelName: String, progress: ((Double, String?) -> Void)? = nil) async throws {
        if loadedModel == modelName, whisperKit != nil { return }

        fputs("[whisperkit] loading model: \(modelName)...\n", stderr)
        let modelFolder: URL?

        if Self.isModelDownloaded(modelName) {
            modelFolder = nil
        } else {
            let estimatedTotalBytes = Self.estimatedDownloadBytes(for: modelName)
            let totalText = Self.formatMegabytes(estimatedTotalBytes)
            progress?(0.02, "0 MB of \(totalText)")
            modelFolder = try await WhisperKit.download(variant: modelName) { downloadProgress in
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
            modelFolder: modelFolder?.path,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        )

        whisperKit = try await WhisperKit(config)
        loadedModel = modelName
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
        let results = try await whisperKit.transcribe(
            audioPath: wavURL.path,
            decodeOptions: Self.transcriptionDecodingOptions
        )
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
    }

    // MARK: - Model Storage

    /// WhisperKit stores models under ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/.
    /// Each model variant is a direct subdirectory (e.g. openai_whisper-small.en/).
    static func isModelDownloaded(_ modelName: String) -> Bool {
        let fm = FileManager.default
        let fullName = modelName.hasPrefix("openai_whisper-") ? modelName : "openai_whisper-\(modelName)"
        let modelDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml/\(fullName)")
        return fm.fileExists(atPath: modelDir.path)
    }

    /// Delete cached model files for a WhisperKit model variant.
    static func deleteModel(_ modelName: String) {
        let fm = FileManager.default
        let fullName = modelName.hasPrefix("openai_whisper-") ? modelName : "openai_whisper-\(modelName)"
        let modelDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml/\(fullName)")
        try? fm.removeItem(at: modelDir)
    }
}
