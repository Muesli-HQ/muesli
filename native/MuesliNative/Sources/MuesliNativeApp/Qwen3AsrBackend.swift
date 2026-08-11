import FluidAudio
import Foundation
import MuesliCore

/// Resolves Qwen3 ASR cache paths used by FluidAudio.
///
/// FluidAudio's `Repo.folderName` strips the `-coreml` suffix for Qwen, so the
/// on-disk cache is `qwen3-asr-0.6b/{int8,f32}` rather than
/// `qwen3-asr-0.6b-coreml/...` (see GitHub issue #380). Prefer FluidAudio's own
/// cache helpers when available so this stays aligned with upstream.
enum Qwen3AsrModelStore {
    /// Current FluidAudio cache directory name, plus the older `-coreml` name in
    /// case a manual install or older tooling used the HuggingFace repo slug.
    static let cacheDirectoryNames = [
        "qwen3-asr-0.6b",
        "qwen3-asr-0.6b-coreml",
    ]

    static func modelsRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
    }

    static func isModelDownloaded(fileManager: FileManager = .default) -> Bool {
        if ManagedASRModelPlans.qwen3ASRInt8(
            modelsRoot: modelsRoot(fileManager: fileManager)
        ).isComplete(fileManager: fileManager) {
            return true
        }
        if #available(macOS 15, *) {
            if Qwen3AsrModels.modelsExist(at: Qwen3AsrModels.defaultCacheDirectory(variant: .int8))
                || Qwen3AsrModels.modelsExist(at: Qwen3AsrModels.defaultCacheDirectory(variant: .f32)) {
                return true
            }
        }

        return hasVocabMarker(in: modelsRoot(fileManager: fileManager), fileManager: fileManager)
    }

    /// Marker used by Models-tab recognition when FluidAudio's macOS 15 helpers
    /// are unavailable or point at a different layout.
    static func hasVocabMarker(in modelsRoot: URL, fileManager: FileManager = .default) -> Bool {
        for name in cacheDirectoryNames {
            let directory = modelsRoot.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: directory.appendingPathComponent("int8/vocab.json").path)
                || fileManager.fileExists(atPath: directory.appendingPathComponent("f32/vocab.json").path) {
                return true
            }
        }
        return false
    }

    static func deleteModelFiles(fileManager: FileManager = .default) throws {
        try deleteModelFiles(from: modelsRoot(fileManager: fileManager), fileManager: fileManager)
    }

    static func deleteModelFiles(from modelsRoot: URL, fileManager: FileManager = .default) throws {
        for name in cacheDirectoryNames {
            let directory = modelsRoot.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            try fileManager.removeItem(at: directory)
        }
    }
}

/// Native Swift transcription backend using FluidAudio's Qwen3 ASR model
/// running on Apple's Neural Engine (ANE) via CoreML.
/// Requires macOS 15+ due to CoreML stateful decoder support.
@available(macOS 15, *)
actor Qwen3AsrTranscriber {
    private var manager: Qwen3AsrManager?

    enum TranscriberError: Error, LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "Qwen3 ASR models not loaded. Call loadModels() first."
            }
        }
    }

    /// Downloads models (if needed) and initializes the Qwen3 ASR manager.
    func loadModels(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        if manager != nil { return }

        fputs("[qwen3-asr] downloading/loading models...\n", stderr)
        let plan = ManagedASRModelPlans.qwen3ASRInt8()
        let modelDir = try await ManagedASRModelDownloader.downloadIfNeeded(
            plan,
            progress: progress,
            progressSnapshot: progressSnapshot
        )
        let preparing = ModelDownloadProgress.preparing(
            modelID: plan.modelID,
            message: "Loading Qwen3 ASR into Core ML..."
        )
        progress?(0.95, preparing.message)
        progressSnapshot?(preparing)
        let mgr = Qwen3AsrManager()
        try await mgr.loadModels(from: modelDir)
        self.manager = mgr
        fputs("[qwen3-asr] models loaded, running warmup inference...\n", stderr)

        // Warmup: run a tiny dummy audio through the pipeline to trigger CoreML compilation.
        // This moves the ~30s compilation cost from first dictation to preload time.
        let warmupSamples = [Float](repeating: 0, count: 16000) // 1 second of silence
        _ = try? await mgr.transcribe(audioSamples: warmupSamples)
        progress?(1, nil)
        progressSnapshot?(preparing.replacing(phase: .ready, message: "Model ready"))
        fputs("[qwen3-asr] warmup complete, ready\n", stderr)
    }

    /// Transcribe a WAV file URL.
    /// Returns the transcribed text (no token-level timings available).
    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard let manager else { throw TranscriberError.notLoaded }
        let start = CFAbsoluteTimeGetCurrent()
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(wavURL)
        let text = try await manager.transcribe(audioSamples: samples)
        let processingTime = CFAbsoluteTimeGetCurrent() - start
        return (text, processingTime)
    }

    func shutdown() {
        manager = nil
    }
}
