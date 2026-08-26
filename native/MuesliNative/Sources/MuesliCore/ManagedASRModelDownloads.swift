import Foundation

/// A third-party ASR model whose transport is owned by Muesli.
public struct ManagedASRModelPlan: Sendable {
    private struct CompletionMarker: Codable {
        struct File: Codable {
            let relativePath: String
            let expectedByteCount: Int64?
        }

        let modelID: String
        let revision: String
        let manifestVersion: String
        let files: [File]
    }

    private static let completionMarkerName = ".muesli-managed-model-complete.json"
    private static let downloadStateName = ".muesli-download-state.json"
    private static let legacyManifestVersion = "legacy-local-v1"

    public let modelID: String
    public let repository: String
    public let revision: String
    public let cacheDirectory: URL
    public let selections: [HuggingFaceModelSelection]
    /// Optional immutable Muesli mirror used before Hugging Face discovery.
    public let mirror: MuesliModelMirror?
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
        mirror: MuesliModelMirror? = nil,
        maximumConcurrency: Int = 2
    ) {
        self.modelID = modelID
        self.repository = repository
        self.revision = revision
        self.cacheDirectory = cacheDirectory
        self.selections = selections
        self.requiredArtifactAlternatives = requiredArtifactAlternatives
        self.mirror = mirror
        self.maximumConcurrency = maximumConcurrency
    }

    public func isComplete(fileManager: FileManager = .default) -> Bool {
        guard requiredArtifactsExist(fileManager: fileManager),
              let data = try? Data(contentsOf: completionMarkerURL),
              let marker = try? JSONDecoder().decode(CompletionMarker.self, from: data),
              marker.modelID == modelID,
              marker.revision == revision,
              !marker.files.isEmpty
        else { return false }

        return marker.files.allSatisfy { file in
            let url = cacheDirectory.appendingPathComponent(file.relativePath)
            guard fileManager.fileExists(atPath: url.path) else { return false }
            guard let expectedByteCount = file.expectedByteCount else { return true }
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            return size == expectedByteCount
        }
    }

    /// True for either a marker-validated managed download or a complete cache
    /// created by a Muesli version that predates managed completion markers.
    /// Legacy recognition is refused when resumable state or partial files are
    /// present, so interrupted managed downloads cannot masquerade as installs.
    public func isAvailableLocally(fileManager: FileManager = .default) -> Bool {
        isComplete(fileManager: fileManager) || isLegacyInstallation(fileManager: fileManager)
    }

    /// Whether this cache predates managed completion markers and still needs
    /// one successful runtime load before it can be trusted as complete.
    public func requiresRuntimeValidation(fileManager: FileManager = .default) -> Bool {
        isLegacyInstallation(fileManager: fileManager)
    }

    /// Records a successful, fully validated coordinator install. The marker
    /// carries every manifest file so readiness cannot be inferred from an
    /// early sentinel while sibling weights are still partial or missing.
    public func recordSuccessfulInstallation(
        _ manifest: ModelDownloadManifest,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let marker = CompletionMarker(
            modelID: modelID,
            revision: revision,
            manifestVersion: manifest.version,
            files: manifest.files.map {
                CompletionMarker.File(
                    relativePath: $0.relativePath,
                    expectedByteCount: $0.expectedByteCount
                )
            }
        )
        try JSONEncoder().encode(marker).write(to: completionMarkerURL, options: .atomic)
    }

    /// Backfills a completion marker after a legacy cache has successfully
    /// loaded through its runtime. This deliberately runs after validation: a
    /// file-presence check alone must never certify a partially installed model.
    public func recordValidatedLegacyInstallationIfNeeded(
        fileManager: FileManager = .default
    ) throws {
        guard !isComplete(fileManager: fileManager),
              isLegacyInstallation(fileManager: fileManager)
        else { return }

        let files = try selectedLocalFiles(fileManager: fileManager)
        guard !files.isEmpty else { return }
        let marker = CompletionMarker(
            modelID: modelID,
            revision: revision,
            manifestVersion: Self.legacyManifestVersion,
            files: files
        )
        try JSONEncoder().encode(marker).write(to: completionMarkerURL, options: .atomic)
    }

    public func delete(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: cacheDirectory.path) else { return }
        try fileManager.removeItem(at: cacheDirectory)
    }

    private var completionMarkerURL: URL {
        cacheDirectory.appendingPathComponent(Self.completionMarkerName)
    }

    private func requiredArtifactsExist(fileManager: FileManager) -> Bool {
        !requiredArtifactAlternatives.isEmpty
            && requiredArtifactAlternatives.allSatisfy { alternatives in
                alternatives.contains { relativePath in
                    fileManager.fileExists(
                        atPath: cacheDirectory.appendingPathComponent(relativePath).path
                    )
                }
            }
    }

    private func isLegacyInstallation(fileManager: FileManager) -> Bool {
        guard requiredArtifactsExist(fileManager: fileManager),
              !fileManager.fileExists(atPath: completionMarkerURL.path),
              !fileManager.fileExists(
                atPath: cacheDirectory.appendingPathComponent(Self.downloadStateName).path
              )
        else { return false }

        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator where url.pathExtension == "part" {
            return false
        }
        return true
    }

    private func selectedLocalFiles(fileManager: FileManager) throws -> [CompletionMarker.File] {
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let rootPath = cacheDirectory.standardizedFileURL.path
        var files: [CompletionMarker.File] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relativePath = String(path.dropFirst(rootPath.count + 1))
            guard isSelected(relativePath: relativePath) else { continue }
            files.append(CompletionMarker.File(
                relativePath: relativePath,
                expectedByteCount: values.fileSize.map(Int64.init)
            ))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func isSelected(relativePath: String) -> Bool {
        selections.contains { selection in
            let destination = selection.destinationDirectory.map { $0 + "/" } ?? ""
            if selection.includedPaths.isEmpty {
                return destination.isEmpty || relativePath.hasPrefix(destination)
            }
            return selection.includedPaths.contains { includedPath in
                let selectedPath = destination + includedPath
                return relativePath == selectedPath || relativePath.hasPrefix(selectedPath + "/")
            }
        }
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
            mirror: MuesliModelMirror(manifestURL: URL(string: "https://assets.muesli.works/models/fluidaudio/parakeet-tdt-0.6b-v2/legacy-local-v1/manifest.json")!),
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
            mirror: muesliMirror(
                "models/fluidaudio/parakeet-tdt-0.6b-v3/legacy-local-v1/manifest.json"
            ),
            modelsRoot: modelsRoot
        )
    }

    /// Parakeet Unified 0.6B (FastConformer-RNNT), English-focused offline batch
    /// path: int8 full-attention encoder + decoder + joint + vocabulary.
    public static func parakeetUnified(modelsRoot: URL? = nil) -> ManagedASRModelPlan {
        let required = [
            "parakeet_unified_encoder_int8.mlmodelc",
            "parakeet_unified_decoder.mlmodelc",
            "parakeet_unified_joint_decision_single_step.mlmodelc",
            "vocab.json",
            "metadata.json",
        ]
        return fluidAudioPlan(
            modelID: "FluidInference/parakeet-unified-en-0.6b-coreml",
            repository: "FluidInference/parakeet-unified-en-0.6b-coreml",
            directoryName: "parakeet-unified-en-0.6b-coreml",
            required: required,
            mirror: muesliMirror(
                "models/fluidaudio/parakeet-unified-en-0.6b/legacy-local-v1/manifest.json"
            ),
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
        let directory = (modelsRoot ?? fluidAudioModelsRoot())
            .appendingPathComponent("qwen3-asr-0.6b/int8", isDirectory: true)
        return qwen3ASRInt8(cacheDirectory: directory)
    }

    /// Qwen3 ASR int8 plan with an explicit install directory, so callers can
    /// install into any location the managed downloader supports.
    public static func qwen3ASRInt8(cacheDirectory: URL) -> ManagedASRModelPlan {
        let required = [
            "qwen3_asr_audio_encoder_v2.mlmodelc",
            "qwen3_asr_decoder_stateful.mlmodelc",
            "qwen3_asr_embeddings.bin",
            "vocab.json",
        ]
        return ManagedASRModelPlan(
            modelID: "FluidInference/qwen3-asr-0.6b-coreml",
            repository: "FluidInference/qwen3-asr-0.6b-coreml",
            cacheDirectory: cacheDirectory,
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
        let requiredFiles = requiredModels + ["config.json", "generation_config.json"]
        return ManagedASRModelPlan(
            modelID: modelName,
            repository: "argmaxinc/whisperkit-coreml",
            cacheDirectory: directory,
            selections: [HuggingFaceModelSelection(
                remoteDirectory: fullName,
                includedPaths: Set(requiredFiles)
            )],
            requiredArtifactAlternatives: completenessRequirements(for: requiredFiles),
            mirror: whisperKitMirror(fullName: fullName)
        )
    }

    private static func muesliMirror(_ path: String) -> MuesliModelMirror {
        MuesliModelMirror(manifestURL: URL(string: "https://assets.muesli.works/\(path)")!)
    }

    /// Only variants that Muesli has copied and checksum-pinned in R2 are
    /// eligible for the first-party transport. Unknown WhisperKit paths keep
    /// using the normal Hugging Face discovery flow.
    private static func whisperKitMirror(fullName: String) -> MuesliModelMirror? {
        let mirroredVariants: Set<String> = [
            "openai_whisper-tiny",
            "openai_whisper-tiny.en",
            "openai_whisper-small",
            "openai_whisper-small.en",
            "openai_whisper-medium.en",
            "openai_whisper-large-v3-v20240930_626MB",
        ]
        guard mirroredVariants.contains(fullName) else { return nil }
        return muesliMirror("models/whisperkit/\(fullName)/legacy-local-v1/manifest.json")
    }

    private static func fluidAudioPlan(
        modelID: String,
        repository: String,
        directoryName: String,
        required: [String],
        mirror: MuesliModelMirror? = nil,
        modelsRoot: URL?
    ) -> ManagedASRModelPlan {
        let directory = (modelsRoot ?? fluidAudioModelsRoot())
            .appendingPathComponent(directoryName, isDirectory: true)
        return ManagedASRModelPlan(
            modelID: modelID,
            repository: repository,
            cacheDirectory: directory,
            selections: [HuggingFaceModelSelection(includedPaths: Set(required))],
            requiredArtifactAlternatives: completenessRequirements(for: required),
            mirror: mirror
        )
    }

    private static func completenessRequirements(for paths: [String]) -> [[String]] {
        paths.flatMap { path in
            if path.hasSuffix(".mlmodelc") {
                return [
                    [path + "/coremldata.bin"],
                    [path + "/weights/weight.bin"],
                ]
            }
            return [[path]]
        }
    }
}

/// Bridges Hugging Face discovery to the resumable coordinator and legacy scalar UI callbacks.
public enum ManagedASRModelDownloader {
    private static let operations = ManagedASRModelOperations()

    @discardableResult
    public static func downloadIfNeeded(
        _ plan: ManagedASRModelPlan,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil,
        resolver: HuggingFaceModelManifestResolver = .shared,
        mirrorResolver: MuesliModelMirrorManifestResolver = .shared,
        coordinator: ModelDownloadCoordinator = .shared
    ) async throws -> URL {
        try await operations.run(modelID: plan.modelID) {
            if plan.isAvailableLocally() { return plan.cacheDirectory }

            return try await performDownload(
                plan,
                progress: progress,
                progressSnapshot: progressSnapshot,
                resolver: resolver,
                mirrorResolver: mirrorResolver,
                coordinator: coordinator
            )
        }
    }

    /// Loads a managed model and validates markerless legacy caches through the
    /// real runtime. A legacy cache that cannot load is removed and downloaded
    /// once from scratch; a successful legacy load is promoted to a strict,
    /// size-aware managed installation without requiring network access.
    public static func loadValidated<T>(
        _ plan: ManagedASRModelPlan,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil,
        resolver: HuggingFaceModelManifestResolver = .shared,
        mirrorResolver: MuesliModelMirrorManifestResolver = .shared,
        coordinator: ModelDownloadCoordinator = .shared,
        load: (URL) async throws -> T
    ) async throws -> T {
        let requiresRuntimeValidation = plan.requiresRuntimeValidation()
        let directory = try await downloadIfNeeded(
            plan,
            progress: progress,
            progressSnapshot: progressSnapshot,
            resolver: resolver,
            mirrorResolver: mirrorResolver,
            coordinator: coordinator
        )

        do {
            let value = try await load(directory)
            try? plan.recordValidatedLegacyInstallationIfNeeded()
            return value
        } catch {
            let validationError = error
            guard requiresRuntimeValidation, !(error is CancellationError) else { throw error }
            try Task.checkCancellation()

            let deletionToken = await beginDeletion(
                modelID: plan.modelID,
                coordinator: coordinator
            )
            let shouldRepair = plan.requiresRuntimeValidation()
            do {
                if shouldRepair { try plan.delete() }
            } catch {
                await endDeletion(deletionToken)
                throw error
            }
            await endDeletion(deletionToken)
            guard shouldRepair else { throw validationError }

            let repairedDirectory = try await downloadIfNeeded(
                plan,
                progress: progress,
                progressSnapshot: progressSnapshot,
                resolver: resolver,
                mirrorResolver: mirrorResolver,
                coordinator: coordinator
            )
            return try await load(repairedDirectory)
        }
    }

    /// Cancels manifest discovery and transfer for a model without blocking a
    /// later resume.
    public static func cancel(
        modelID: String,
        coordinator: ModelDownloadCoordinator = .shared
    ) async {
        await operations.cancel(modelID: modelID)
        await coordinator.cancel(modelID: modelID)
    }

    /// Cancels and awaits manifest discovery plus any registered transfer.
    public static func cancelAndWait(
        modelID: String,
        coordinator: ModelDownloadCoordinator = .shared
    ) async {
        await operations.cancelAndWait(modelID: modelID)
        await coordinator.cancelAndWait(modelID: modelID)
    }

    /// Blocks new operations for a model while callers remove its cache.
    public static func beginDeletion(
        modelID: String,
        coordinator: ModelDownloadCoordinator = .shared
    ) async -> ManagedASRModelDeletionToken {
        let token = await operations.beginDeletion(modelID: modelID)
        await coordinator.cancelAndWait(modelID: modelID)
        return token
    }

    public static func endDeletion(_ token: ManagedASRModelDeletionToken) async {
        await operations.endDeletion(token)
    }

    private static func performDownload(
        _ plan: ManagedASRModelPlan,
        progress: ((Double, String?) -> Void)?,
        progressSnapshot: ModelDownloadProgressHandler?,
        resolver: HuggingFaceModelManifestResolver,
        mirrorResolver: MuesliModelMirrorManifestResolver,
        coordinator: ModelDownloadCoordinator
    ) async throws -> URL {
        try Task.checkCancellation()

        let scalarProgress = ManagedASRScalarProgressRelay(progress)
        func report(_ message: String) {
            scalarProgress.call(0.01, message)
            progressSnapshot?(ModelDownloadProgress.preparing(
                modelID: plan.modelID,
                message: message
            ))
        }
        func download(_ manifest: ModelDownloadManifest) async throws {
            try await coordinator.download(manifest, to: plan.cacheDirectory) { snapshot in
                if let fraction = snapshot.fractionCompleted {
                    scalarProgress.call(fraction, snapshot.message)
                }
                progressSnapshot?(snapshot)
            }
        }

        var failedMirrorManifest: ModelDownloadManifest?
        if let mirror = plan.mirror {
            do {
                report("Checking Muesli model mirror...")
                let manifest = try await mirrorResolver.resolve(
                    modelID: plan.modelID,
                    mirror: mirror,
                    maximumConcurrency: plan.maximumConcurrency
                )
                // Preserve the exact mirror manifest until this transfer has
                // succeeded. If the mirror fails partway through, it is the
                // only complete record of files that may need removing before
                // a Hugging Face fallback begins.
                failedMirrorManifest = manifest
                try await download(manifest)
                try plan.recordSuccessfulInstallation(manifest)
                guard plan.isComplete() else {
                    throw MuesliModelMirrorManifestError.invalidManifest(mirror.manifestURL)
                }
                return plan.cacheDirectory
            } catch {
                if isCancellation(error) { throw CancellationError() }
                if let failedMirrorManifest {
                    // Never resume a mirror's partial bytes against a Hugging
                    // Face revision. The mirror manifest includes files that
                    // may not exist in the fallback manifest, so clean it
                    // before resolving Hugging Face.
                    try? await coordinator.removeDownload(
                        failedMirrorManifest,
                        at: plan.cacheDirectory
                    )
                }
                report("Muesli mirror unavailable; trying Hugging Face...")
            }
        } else {
            report("Finding model files...")
        }

        let manifest = try await resolver.resolve(
            modelID: plan.modelID,
            repository: plan.repository,
            revision: plan.revision,
            selections: plan.selections,
            maximumConcurrency: plan.maximumConcurrency
        )
        try await download(manifest)
        try plan.recordSuccessfulInstallation(manifest)
        guard plan.isComplete() else {
            throw HuggingFaceModelManifestError.emptySelection(plan.repository)
        }
        return plan.cacheDirectory
    }

    private static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled
            || error is CancellationError
            || (error as? URLError)?.code == .cancelled
    }
}

public struct ManagedASRModelDeletionToken: Sendable {
    fileprivate let modelID: String
    fileprivate let id: UUID
}

private actor ManagedASRModelOperations {
    private struct Operation {
        let id: UUID
        let task: Task<URL, Error>
    }

    private var operations: [String: [UUID: Operation]] = [:]
    private var deletionTokens: [String: UUID] = [:]

    func run(
        modelID: String,
        operation: @escaping @Sendable () async throws -> URL
    ) async throws -> URL {
        guard deletionTokens[modelID] == nil else { throw CancellationError() }
        let id = UUID()
        let task = Task { try await operation() }
        operations[modelID, default: [:]][id] = Operation(id: id, task: task)
        defer { operations[modelID]?[id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancel(modelID: String) {
        guard let active = operations[modelID]?.values else { return }
        for operation in active {
            operation.task.cancel()
        }
    }

    func cancelAndWait(modelID: String) async {
        let active = operations[modelID].map { Array($0.values) } ?? []
        for operation in active { operation.task.cancel() }
        for operation in active { _ = try? await operation.task.value }
    }

    func beginDeletion(modelID: String) async -> ManagedASRModelDeletionToken {
        let token = ManagedASRModelDeletionToken(modelID: modelID, id: UUID())
        deletionTokens[modelID] = token.id
        await cancelAndWait(modelID: modelID)
        return token
    }

    func endDeletion(_ token: ManagedASRModelDeletionToken) {
        guard deletionTokens[token.modelID] == token.id else { return }
        deletionTokens[token.modelID] = nil
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
