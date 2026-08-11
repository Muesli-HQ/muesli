import Foundation

/// A third-party ASR model whose transport is owned by Muesli.
public struct ManagedASRModelPlan: Sendable {
    public let modelID: String
    public let repository: String
    public let revision: String
    public let cacheDirectory: URL
    public let selections: [HuggingFaceModelSelection]
    /// Every inner group is an either/or requirement; every group must be satisfied.
    public let requiredArtifactAlternatives: [[String]]
    public let maximumConcurrency: Int

    public init(
        modelID: String,
        repository: String,
        revision: String = "main",
        cacheDirectory: URL,
        selections: [HuggingFaceModelSelection],
        requiredArtifactAlternatives: [[String]],
        maximumConcurrency: Int = 2
    ) {
        self.modelID = modelID
        self.repository = repository
        self.revision = revision
        self.cacheDirectory = cacheDirectory
        self.selections = selections
        self.requiredArtifactAlternatives = requiredArtifactAlternatives
        self.maximumConcurrency = maximumConcurrency
    }

    public func isComplete(fileManager: FileManager = .default) -> Bool {
        !requiredArtifactAlternatives.isEmpty && requiredArtifactAlternatives.allSatisfy { alternatives in
            alternatives.contains { relativePath in
                fileManager.fileExists(atPath: cacheDirectory.appendingPathComponent(relativePath).path)
            }
        }
    }

    public func delete(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: cacheDirectory.path) else { return }
        try fileManager.removeItem(at: cacheDirectory)
    }
}

/// Canonical cache layouts and artifact sets shared by the app and CLI.
public enum ManagedASRModelPlans {
    private static let fluidAudioRootRelativePath = "Library/Application Support/FluidAudio/Models"

    public static func fluidAudioModelsRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(fluidAudioRootRelativePath, isDirectory: true)
    }

    public static func parakeetV2(modelsRoot: URL? = nil) -> ManagedASRModelPlan {
        let required = [
            "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
            "JointDecision.mlmodelc", "parakeet_vocab.json",
        ]
        return fluidAudioPlan(
            modelID: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
            repository: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
            directoryName: "parakeet-tdt-0.6b-v2",
            required: required,
            modelsRoot: modelsRoot
        )
    }

    public static func parakeetV3(modelsRoot: URL? = nil) -> ManagedASRModelPlan {
        let required = [
            "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
            "JointDecisionv3.mlmodelc", "parakeet_vocab.json",
        ]
        return fluidAudioPlan(
            modelID: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            directoryName: "parakeet-tdt-0.6b-v3",
            required: required,
            modelsRoot: modelsRoot
        )
    }

    public static func senseVoice(modelsRoot: URL? = nil) -> ManagedASRModelPlan {
        let required = [
            "SenseVoicePreprocessor.mlmodelc", "SenseVoiceSmall_int8.mlmodelc", "vocab.json",
        ]
        return fluidAudioPlan(
            modelID: "FluidInference/sensevoice-small-coreml",
            repository: "FluidInference/sensevoice-small-coreml",
            directoryName: "sensevoice-small-coreml",
            required: required,
            modelsRoot: modelsRoot
        )
    }

    public static func qwen3ASRInt8(modelsRoot: URL? = nil) -> ManagedASRModelPlan {
        let required = [
            "qwen3_asr_audio_encoder_v2.mlmodelc",
            "qwen3_asr_decoder_stateful.mlmodelc",
            "qwen3_asr_embeddings.bin",
            "vocab.json",
        ]
        let directory = (modelsRoot ?? fluidAudioModelsRoot())
            .appendingPathComponent("qwen3-asr-0.6b/int8", isDirectory: true)
        return ManagedASRModelPlan(
            modelID: "FluidInference/qwen3-asr-0.6b-coreml",
            repository: "FluidInference/qwen3-asr-0.6b-coreml",
            cacheDirectory: directory,
            selections: [
                HuggingFaceModelSelection(
                    remoteDirectory: "int8",
                    includedPaths: Set(required),
                    recursive: true
                )
            ],
            requiredArtifactAlternatives: completenessRequirements(for: required)
        )
    }

    public static func parakeetRealtimeEOU320(modelsRoot: URL? = nil) -> ManagedASRModelPlan {
        let required = [
            "streaming_encoder.mlmodelc", "decoder.mlmodelc", "joint_decision.mlmodelc", "vocab.json",
        ]
        let directory = (modelsRoot ?? fluidAudioModelsRoot())
            .appendingPathComponent("parakeet-eou-streaming/320ms", isDirectory: true)
        return ManagedASRModelPlan(
            modelID: "FluidInference/parakeet-realtime-eou-120m-coreml/320ms",
            repository: "FluidInference/parakeet-realtime-eou-120m-coreml",
            cacheDirectory: directory,
            selections: [
                HuggingFaceModelSelection(
                    remoteDirectory: "320ms",
                    includedPaths: Set(required),
                    recursive: true
                )
            ],
            requiredArtifactAlternatives: completenessRequirements(for: required)
        )
    }

    public static func whisperKit(
        modelName: String,
        downloadRoot: URL? = nil
    ) -> ManagedASRModelPlan {
        let fullName = modelName.hasPrefix("openai_whisper-") ? modelName : "openai_whisper-\(modelName)"
        let root = downloadRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
        let directory = root.appendingPathComponent(fullName, isDirectory: true)
        let requiredModels = [
            "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc",
        ]
        return ManagedASRModelPlan(
            modelID: modelName,
            repository: "argmaxinc/whisperkit-coreml",
            cacheDirectory: directory,
            selections: [HuggingFaceModelSelection(
                remoteDirectory: fullName,
                includedPaths: Set(requiredModels + ["config.json", "generation_config.json"])
            )],
            requiredArtifactAlternatives: completenessRequirements(for: requiredModels)
        )
    }

    private static func fluidAudioPlan(
        modelID: String,
        repository: String,
        directoryName: String,
        required: [String],
        modelsRoot: URL?
    ) -> ManagedASRModelPlan {
        let directory = (modelsRoot ?? fluidAudioModelsRoot())
            .appendingPathComponent(directoryName, isDirectory: true)
        return ManagedASRModelPlan(
            modelID: modelID,
            repository: repository,
            cacheDirectory: directory,
            selections: [HuggingFaceModelSelection(includedPaths: Set(required))],
            requiredArtifactAlternatives: completenessRequirements(for: required)
        )
    }

    private static func completenessRequirements(for paths: [String]) -> [[String]] {
        paths.map { path in
            if path.hasSuffix(".mlmodelc") {
                return [path + "/coremldata.bin"]
            }
            return [path]
        }
    }
}

/// Bridges Hugging Face discovery to the resumable coordinator and legacy scalar UI callbacks.
public enum ManagedASRModelDownloader {
    @discardableResult
    public static func downloadIfNeeded(
        _ plan: ManagedASRModelPlan,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil,
        resolver: HuggingFaceModelManifestResolver = .shared,
        coordinator: ModelDownloadCoordinator = .shared
    ) async throws -> URL {
        if plan.isComplete() { return plan.cacheDirectory }

        let scalarProgress = ManagedASRScalarProgressRelay(progress)
        scalarProgress.call(0.01, "Finding model files...")
        progressSnapshot?(ModelDownloadProgress(
            modelID: plan.modelID,
            phase: .downloading,
            currentFile: nil,
            completedBytes: 0,
            totalBytes: nil,
            currentFileCompletedBytes: 0,
            currentFileTotalBytes: nil,
            bytesPerSecond: 0,
            estimatedSecondsRemaining: nil,
            retryCount: 0,
            message: "Finding model files..."
        ))
        let manifest = try await resolver.resolve(
            modelID: plan.modelID,
            repository: plan.repository,
            revision: plan.revision,
            selections: plan.selections,
            maximumConcurrency: plan.maximumConcurrency
        )
        try await coordinator.download(manifest, to: plan.cacheDirectory) { snapshot in
            if let fraction = snapshot.fractionCompleted {
                scalarProgress.call(fraction, snapshot.message)
            }
            progressSnapshot?(snapshot)
        }
        guard plan.isComplete() else {
            throw HuggingFaceModelManifestError.emptySelection(plan.repository)
        }
        return plan.cacheDirectory
    }
}

private final class ManagedASRScalarProgressRelay: @unchecked Sendable {
    private let handler: ((Double, String?) -> Void)?

    init(_ handler: ((Double, String?) -> Void)?) {
        self.handler = handler
    }

    func call(_ fraction: Double, _ message: String?) {
        handler?(fraction, message)
    }
}
