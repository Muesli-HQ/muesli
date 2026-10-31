import AVFoundation
import CoreML
import FluidAudio
import Foundation
import MuesliCore

/// Native Swift transcription backend for Parakeet Unified 0.6B
/// (FastConformer-RNNT) using FluidAudio's offline batch `UnifiedAsrManager`.
/// English-focused, lower-WER successor to Parakeet TDT v3.
actor ParakeetUnifiedTranscriber {
    private let cpuOnly: Bool
    init(cpuOnly: Bool = false) { self.cpuOnly = cpuOnly }

    private var asrManager: UnifiedAsrManager?
    private var loadedPlan: ManagedASRModelPlan?
    private var loadGeneration: UInt64 = 0
    // Actors can reenter at model awaits. Keep previews, final transcription,
    // loading and unloading on one permit, as in FluidAudioTranscriber.
    private var decodeBusy = false
    private var decodeWaiters: [CheckedContinuation<Void, Never>] = []

    enum TranscriberError: Error, LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "Parakeet Unified models not loaded. Call loadModels() first."
            }
        }
    }

    /// Initializes the ASR manager; localOnly disables downloads and cache repair.
    func loadModels(
        localOnly: Bool = false,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        await acquireDecode()
        defer { releaseDecode() }
        try Task.checkCancellation()
        if asrManager != nil { return }
        let generation = loadGeneration

        fputs("[parakeet-unified] loading models local_only=\(localOnly)...\n", stderr)
        let plan = ManagedASRModelPlans.parakeetUnified()
        let cpuOnly = self.cpuOnly
        let manager = try await ManagedASRModelDownloader.loadValidated(
            plan,
            allowDownload: !localOnly,
            progress: progress,
            progressSnapshot: progressSnapshot
        ) { modelDirectory in
            let preparing = ModelDownloadProgress.preparing(
                modelID: plan.modelID,
                message: "Loading Parakeet Unified into Core ML..."
            )
            progress?(0.95, preparing.message)
            progressSnapshot?(preparing)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            let manager = UnifiedAsrManager(configuration: cpuOnly ? configuration : nil)
            try await manager.loadModels(from: modelDirectory)
            return manager
        }
        // A shutdown() during the load must invalidate the result: discard the
        // freshly loaded manager instead of resurrecting a stale one.
        guard generation == loadGeneration else {
            throw CancellationError()
        }
        self.asrManager = manager
        self.loadedPlan = plan
        let preparing = ModelDownloadProgress.preparing(
            modelID: plan.modelID,
            message: "Loading Parakeet Unified into Core ML..."
        )
        progress?(1, nil)
        progressSnapshot?(preparing.replacing(phase: .ready, message: "Model ready"))
        fputs("[parakeet-unified] models ready\n", stderr)
    }

    /// Transcribe a WAV file URL (16 kHz mono).
    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        await acquireDecode()
        defer { releaseDecode() }
        try Task.checkCancellation()
        guard let asrManager else { throw TranscriberError.notLoaded }
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(wavURL)
        let start = CFAbsoluteTimeGetCurrent()
        let text = try await asrManager.transcribe(samples)
        let processingTime = CFAbsoluteTimeGetCurrent() - start
        return (text, processingTime)
    }

    func transcribePreview(samples: [Float], requiresWordTimings: Bool = true) async throws -> BufferedTranscriptionWindow {
        await acquireDecode()
        defer { releaseDecode() }
        try Task.checkCancellation()
        guard let asrManager else { throw TranscriberError.notLoaded }
        if !requiresWordTimings {
            let text = try await asrManager.transcribe(samples)
            try Task.checkCancellation()
            return .init(text: text, words: [])
        }
        let result = try await asrManager.transcribeWithTimings(samples)
        try Task.checkCancellation()
        let words = FluidAudioBufferedWordTimings.build(from: result.tokenTimings)
        return try Self.previewWindow(text: result.text, words: words)
    }

    static func previewWindow(text: String, words: [BufferedTranscriptionWord]) throws -> BufferedTranscriptionWindow {
        do {
            return try BufferedTranscriptionWindow.aligned(text: text, words: words)
        } catch BufferedTranscriptionSession.Failure.invalidTimings {
            throw BufferedTranscriptionPreviewDeferral.textAlignmentMismatch
        }
    }

    func shutdown() async {
        // Invalidate any in-flight load before waiting for its permit.
        loadGeneration &+= 1
        await acquireDecode()
        defer { releaseDecode() }
        asrManager = nil
        loadedPlan = nil
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
