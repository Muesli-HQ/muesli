import Foundation
import WhisperKit
import MuesliCore

/// Native Swift transcription backend using WhisperKit (CoreML on ANE/GPU).
actor WhisperKitTranscriber {
    private var whisperKit: WhisperKit?
    private var loadedModel: String?

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
        if loadedModel == modelName, whisperKit != nil { return }

        fputs("[whisperkit] loading model: \(modelName)...\n", stderr)
        let plan = ManagedASRModelPlans.whisperKit(modelName: modelName)
        let modelFolder = try await ManagedASRModelDownloader.downloadIfNeeded(
            plan,
            progress: progress,
            progressSnapshot: progressSnapshot
        )
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

        whisperKit = try await WhisperKit(config)
        loadedModel = modelName
        fputs("[whisperkit] model loaded: \(modelName)\n", stderr)
    }

    /// Transcribe a 16kHz mono WAV file.
    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard let whisperKit else { throw TranscriberError.notLoaded }

        let start = CFAbsoluteTimeGetCurrent()
        let results = try await whisperKit.transcribe(audioPath: wavURL.path)
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
        ManagedASRModelPlans.whisperKit(modelName: modelName).isComplete()
    }

    /// Delete cached model files for a WhisperKit model variant.
    static func deleteModel(_ modelName: String) {
        try? ManagedASRModelPlans.whisperKit(modelName: modelName).delete()
    }
}
