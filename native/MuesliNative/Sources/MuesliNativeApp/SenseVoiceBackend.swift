import FluidAudio
import Foundation
import MuesliCore

/// Native Swift transcription backend for FunASR's SenseVoiceSmall via FluidAudio.
actor SenseVoiceTranscriber {
    private var manager: SenseVoiceManager?
    private var isLoading = false
    private var hasCompletedWarmup = false
    private static let precision: SenseVoiceEncoderPrecision = .int8

    enum TranscriberError: Error, LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "SenseVoice models not loaded. Call loadModels() first."
            }
        }
    }

    /// Downloads models if needed and initializes the SenseVoice manager.
    func loadModels(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        // Actor isolation makes this check-and-set race-free. Waiters retry after
        // a failed load so a transient download error does not poison the actor.
        while isLoading {
            try await Task.sleep(nanoseconds: 50_000_000)
            if manager != nil { return }
        }
        if manager != nil { return }

        isLoading = true
        defer { isLoading = false }

        fputs("[sensevoice] downloading/loading models...\n", stderr)
        let plan = ManagedASRModelPlans.senseVoice()
        let loadedManager = try await ManagedASRModelDownloader.loadValidated(
            plan,
            progress: progress,
            progressSnapshot: progressSnapshot
        ) { modelDirectory in
            let preparing = ModelDownloadProgress.preparing(
                modelID: plan.modelID,
                message: "Loading SenseVoice into Core ML..."
            )
            progressSnapshot?(preparing)
            progress?(0.95, "Loading SenseVoice...")
            let models = try SenseVoiceModels.load(from: modelDirectory, precision: Self.precision)
            return SenseVoiceManager(models: models)
        }
        let preparing = ModelDownloadProgress.preparing(
            modelID: plan.modelID,
            message: "Loading SenseVoice into Core ML..."
        )
        self.manager = loadedManager
        await warmupIfNeeded(progress: progress)
        progress?(1.0, nil)
        progressSnapshot?(preparing.replacing(phase: .ready, message: "Model ready"))
        fputs("[sensevoice] models ready\n", stderr)
    }

    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard let manager else { throw TranscriberError.notLoaded }
        let start = CFAbsoluteTimeGetCurrent()
        let text = try await manager.transcribe(audioURL: wavURL)
        let processingTime = CFAbsoluteTimeGetCurrent() - start
        return (text, processingTime)
    }

    func shutdown() {
        manager = nil
        hasCompletedWarmup = false
    }

    static let cacheRelativePath = "Library/Application Support/FluidAudio/Models/sensevoice-small-coreml"
    static let downloadedModelSizeLabel = "~240 MB"

    static func cacheDirectory(fileManager: FileManager = .default) -> URL {
        ManagedASRModelPlans.senseVoice(
            modelsRoot: ManagedASRModelPlans.fluidAudioModelsRoot(fileManager: fileManager)
        ).cacheDirectory
    }

    static func isModelDownloaded(fileManager: FileManager = .default) -> Bool {
        ManagedASRModelPlans.senseVoice(
            modelsRoot: ManagedASRModelPlans.fluidAudioModelsRoot(fileManager: fileManager)
        ).isAvailableLocally(fileManager: fileManager)
    }

    static func deleteModelFiles(fileManager: FileManager = .default) {
        try? ManagedASRModelPlans.senseVoice(
            modelsRoot: ManagedASRModelPlans.fluidAudioModelsRoot(fileManager: fileManager)
        ).delete(fileManager: fileManager)
    }

    private func warmupIfNeeded(progress: ((Double, String?) -> Void)?) async {
        guard !hasCompletedWarmup, let manager else { return }

        progress?(0.98, "Warming up SenseVoice...")
        fputs("[sensevoice] warmup: running silent audio for CoreML compilation...\n", stderr)
        do {
            let silence = [Float](repeating: 0, count: 16_000)
            _ = try await manager.transcribe(audio: silence)
            hasCompletedWarmup = true
            fputs("[sensevoice] warmup complete\n", stderr)
        } catch {
            fputs("[sensevoice] warmup failed: \(error)\n", stderr)
        }
    }
}
