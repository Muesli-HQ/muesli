import FluidAudio

import Foundation
import MuesliCore

/// Resolves Qwen3 ASR cache paths (layout matches FluidAudio's original cache).
///
/// FluidAudio's `Repo.folderName` strips the `-coreml` suffix for Qwen, so the
/// on-disk cache is `qwen3-asr-0.6b/{int8,f32}` rather than
/// `qwen3-asr-0.6b-coreml/...` (see GitHub issue #380). Readiness follows the
/// managed runtime plan; the legacy name is retained only for cleanup.
enum Qwen3AsrModelStore {
    /// Current FluidAudio cache directory name, plus the older `-coreml` name
    /// retained so model deletion also cleans up manual or legacy installs.
    static let cacheDirectoryNames = [
        "qwen3-asr-0.6b",
        "qwen3-asr-0.6b-coreml",
    ]

    static func modelsRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
    }

    static func isModelDownloaded(fileManager: FileManager = .default) -> Bool {
        isModelDownloaded(in: modelsRoot(fileManager: fileManager), fileManager: fileManager)
    }

    /// Readiness deliberately uses the same managed directory and completeness
    /// contract as runtime loading so the Models tab cannot hide a required download.
    static func isModelDownloaded(
        in modelsRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        ManagedASRModelPlans.qwen3ASRInt8(modelsRoot: modelsRoot)
            .isAvailableLocally(fileManager: fileManager)
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

enum Qwen3AsrWarmupReadiness {
    static func validate(isCancelled: Bool = Task.isCancelled, isCurrent: Bool) throws {
        guard !isCancelled, isCurrent else { throw CancellationError() }
    }
}

/// Native Swift transcription backend using the vendored Qwen3 ASR manager
/// running on Apple's Neural Engine (ANE) via CoreML.
/// Requires macOS 15+ due to CoreML stateful decoder support.
@available(macOS 15, *)
actor Qwen3AsrTranscriber {
    private var manager: MuesliQwen3AsrManager?

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
        let mgr = try await ManagedASRModelDownloader.loadValidated(
            plan,
            progress: progress,
            progressSnapshot: progressSnapshot
        ) { modelDir in
            let preparing = ModelDownloadProgress.preparing(
                modelID: plan.modelID,
                message: "Loading Qwen3 ASR into Core ML..."
            )
            progress?(0.95, preparing.message)
            progressSnapshot?(preparing)
            let candidate = MuesliQwen3AsrManager()
            try await candidate.loadModels(from: modelDir)
            self.manager = candidate
            fputs("[qwen3-asr] models loaded, running warmup inference...\n", stderr)

            // Warmup: run a tiny dummy audio through the pipeline to trigger CoreML compilation.
            // This moves the ~30s compilation cost from first dictation to preload time.
            let warmupSamples = [Float](repeating: 0, count: 16000) // 1 second of silence
            do {
                _ = try await candidate.transcribe(audioSamples: warmupSamples)
                try Qwen3AsrWarmupReadiness.validate(isCurrent: manager === candidate)
                return candidate
            } catch {
                if manager === candidate { manager = nil }
                throw error
            }
        }
        self.manager = mgr
        let preparing = ModelDownloadProgress.preparing(
            modelID: plan.modelID,
            message: "Loading Qwen3 ASR into Core ML..."
        )
        progress?(1, nil)
        progressSnapshot?(preparing.replacing(phase: .ready, message: "Model ready"))
        fputs("[qwen3-asr] warmup complete, ready\n", stderr)
    }

    /// Transcribe a WAV file URL.
    /// Returns the transcribed text (no token-level timings available).
    /// `language` is an optional ISO code; nil keeps automatic language detection.
    func transcribe(wavURL: URL, language: String? = nil) async throws -> (text: String, processingTime: Double) {
        guard let manager else { throw TranscriberError.notLoaded }
        let start = CFAbsoluteTimeGetCurrent()
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(wavURL)
        let text = try await manager.transcribe(audioSamples: samples, language: language)
        let processingTime = CFAbsoluteTimeGetCurrent() - start
        return (text, processingTime)
    }

    func shutdown() {
        manager = nil
    }
}
