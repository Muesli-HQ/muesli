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
        try await operations.run(modelID: plan.modelID) { cancellation in
            if plan.isAvailableLocally() { return plan.cacheDirectory }

            return try await performDownload(
                plan,
                progress: progress,
                progressSnapshot: progressSnapshot,
                resolver: resolver,
                mirrorResolver: mirrorResolver,
                coordinator: coordinator,
                cancellation: cancellation
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
        await coordinator.cancel(modelID: modelID)
        // Mark the high-level operation last. That makes a download started
        // immediately after this method returns wait for cancellation cleanup
        // and begin a fresh attempt, rather than attaching to the cancelled
        // task during the observer's cleanup window.
        await operations.cancel(modelID: modelID)
    }

    /// Cancels and awaits manifest discovery plus any registered transfer.
    public static func cancelAndWait(
        modelID: String,
        coordinator: ModelDownloadCoordinator = .shared
    ) async {
        // The coordinator owns the actual URLSession tasks. Stop those first
        // so awaiting the high-level mirror/fallback operation cannot leave a
        // detached transfer writing its cache in the background.
        await coordinator.cancel(modelID: modelID)
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
        coordinator: ModelDownloadCoordinator,
        cancellation: ManagedASRModelCancellationToken
    ) async throws -> URL {
        func checkCancellation() throws {
            try Task.checkCancellation()
            try cancellation.check()
        }

        try checkCancellation()
        try recoverInterruptedFallbackCache(for: plan)

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

        var mirrorTransferStarted = false
        var fallbackCacheBackup: URL?
        if let mirror = plan.mirror {
            do {
                report("Checking Muesli model mirror...")
                let manifest = try await mirrorResolver.resolve(
                    modelID: plan.modelID,
                    mirror: mirror,
                    maximumConcurrency: plan.maximumConcurrency
                )
                try checkCancellation()
                // Once a mirror transfer starts, Hugging Face must not resume
                // any files in the same directory against another revision.
                mirrorTransferStarted = true
                try await download(manifest)
                try checkCancellation()
                try plan.recordSuccessfulInstallation(manifest)
                guard plan.isComplete() else {
                    throw MuesliModelMirrorManifestError.invalidManifest(mirror.manifestURL)
                }
                return plan.cacheDirectory
            } catch {
                if isCancellation(error) || cancellation.isCancelled { throw CancellationError() }
                if mirrorTransferStarted {
                    // Download the fallback into a new directory so it cannot
                    // resume mirror bytes or stale partial files. Keep the
                    // prior directory aside until the fallback succeeds: valid
                    // files reused by the failed mirror remain available if
                    // Hugging Face is unavailable too.
                    fallbackCacheBackup = try moveCacheAside(plan.cacheDirectory)
                }
                report("Muesli mirror unavailable; trying Hugging Face...")
            }
        } else {
            report("Finding model files...")
        }

        do {
            let manifest = try await resolver.resolve(
                modelID: plan.modelID,
                repository: plan.repository,
                revision: plan.revision,
                selections: plan.selections,
                maximumConcurrency: plan.maximumConcurrency
            )
            try checkCancellation()
            try await download(manifest)
            try checkCancellation()
            try plan.recordSuccessfulInstallation(manifest)
            guard plan.isComplete() else {
                throw HuggingFaceModelManifestError.emptySelection(plan.repository)
            }
        } catch {
            if let fallbackCacheBackup {
                try restoreCache(from: fallbackCacheBackup, to: plan.cacheDirectory)
            }
            if isCancellation(error) || cancellation.isCancelled {
                throw CancellationError()
            }
            throw error
        }

        // The fallback's completion marker has made the replacement durable.
        // A failed best-effort cleanup does not invalidate the new install.
        if let fallbackCacheBackup {
            try? FileManager.default.removeItem(at: fallbackCacheBackup)
        }
        return plan.cacheDirectory
    }

    /// Moves a plan-owned cache out of the fallback's destination directory.
    /// The unique sibling avoids sharing resumable state between origins.
    private static func moveCacheAside(_ cacheDirectory: URL) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cacheDirectory.path) else { return nil }

        let backup = cacheDirectory.deletingLastPathComponent().appendingPathComponent(
            ".\(cacheDirectory.lastPathComponent).muesli-mirror-fallback-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.moveItem(at: cacheDirectory, to: backup)
        return backup
    }

    /// Restores the last mirror cache if the app was terminated while an
    /// origin-isolated Hugging Face fallback was in progress.  A surviving
    /// backup is itself the transaction marker: normal fallback completion or
    /// failure always removes or restores it before returning.  Restoring it
    /// before another attempt prevents a later mirror download from seeing
    /// partial bytes that came from Hugging Face.
    private static func recoverInterruptedFallbackCache(for plan: ManagedASRModelPlan) throws {
        let fileManager = FileManager.default
        let cacheDirectory = plan.cacheDirectory
        let prefix = ".\(cacheDirectory.lastPathComponent).muesli-mirror-fallback-"
        let parentDirectory = cacheDirectory.deletingLastPathComponent()
        let contents = (try? fileManager.contentsOfDirectory(
            at: parentDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        )) ?? []
        let backups = contents.filter { url in
            guard url.lastPathComponent.hasPrefix(prefix) else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard let backup = backups.max(by: { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate < rhsDate
        }) else { return }

        if fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.removeItem(at: cacheDirectory)
        }
        try fileManager.moveItem(at: backup, to: cacheDirectory)

        // A previous abrupt termination could have left more than one stale
        // backup. They cannot belong to the active operation (per-model work
        // is serialized), and retaining them only consumes model storage.
        for staleBackup in backups where staleBackup != backup {
            try? fileManager.removeItem(at: staleBackup)
        }
    }

    /// Restores a pre-fallback cache after Hugging Face fails. Removing the
    /// fallback attempt first prevents incomplete fallback bytes surviving.
    private static func restoreCache(from backup: URL, to cacheDirectory: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.removeItem(at: cacheDirectory)
        }
        try fileManager.moveItem(at: backup, to: cacheDirectory)
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
        let cancellation: ManagedASRModelCancellationToken
        var cancellationRequested = false
    }

    // A model's mirror and fallback state transitions share one cache
    // directory, so callers for the same model must share one operation.
    private var operations: [String: Operation] = [:]
    private var completionWaiters: [UUID: [UUID: CheckedContinuation<URL, Error>]] = [:]
    private var deletionTokens: [String: UUID] = [:]

    func run(
        modelID: String,
        operation: @escaping @Sendable (ManagedASRModelCancellationToken) async throws -> URL
    ) async throws -> URL {
        guard deletionTokens[modelID] == nil else { throw CancellationError() }
        if let active = operations[modelID] {
            // An explicit model cancellation means the next user-initiated
            // download is a new attempt, not another observer of the task
            // that is already winding down.  We still wait for that task to
            // finish before starting it so two attempts cannot mutate the
            // same cache directory concurrently.
            if active.cancellationRequested {
                _ = try? await waitForCompletion(of: active)
                try Task.checkCancellation()
                return try await run(modelID: modelID, operation: operation)
            }
            return try await waitForCompletion(of: active)
        }

        let id = UUID()
        let cancellation = ManagedASRModelCancellationToken()
        let task = Task { try await operation(cancellation) }
        let active = Operation(id: id, task: task, cancellation: cancellation)
        operations[modelID] = active
        Task { [weak self] in
            let result: Result<URL, Error>
            do {
                result = .success(try await task.value)
            } catch {
                result = .failure(error)
            }
            await self?.finish(modelID: modelID, operationID: id, result: result)
        }
        return try await waitForCompletion(of: active)
    }

    func cancel(modelID: String) {
        requestCancellation(modelID: modelID)?.task.cancel()
    }

    func cancelAndWait(modelID: String) async {
        guard let active = requestCancellation(modelID: modelID) else { return }
        let result: Result<URL, Error>
        do {
            result = .success(try await active.task.value)
        } catch {
            result = .failure(error)
        }

        // The detached completion observer also calls `finish`, but a caller
        // that awaits cancellation must not return while this cancelled
        // operation is still eligible for a new caller to join. The operation
        // ID guard in `finish` makes this safe if the observer already ran or
        // a newer operation has since replaced it.
        finish(modelID: modelID, operationID: active.id, result: result)
    }

    private func requestCancellation(modelID: String) -> Operation? {
        guard var active = operations[modelID] else { return nil }
        active.cancellationRequested = true
        operations[modelID] = active
        active.cancellation.cancel()
        return active
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

    /// Each caller waits independently. Cancelling a caller therefore detaches
    /// it from the shared model operation; only explicit model cancellation
    /// above stops the transfer for every caller.
    private func waitForCompletion(of operation: Operation) async throws -> URL {
        let callerID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    completionWaiters[operation.id, default: [:]][callerID] = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(callerID, for: operation.id) }
        })
    }

    private func cancelWaiter(_ callerID: UUID, for operationID: UUID) {
        guard let continuation = completionWaiters[operationID]?[callerID] else { return }
        completionWaiters[operationID]?[callerID] = nil
        if completionWaiters[operationID]?.isEmpty == true {
            completionWaiters[operationID] = nil
        }
        continuation.resume(throwing: CancellationError())
    }

    private func finish(
        modelID: String,
        operationID: UUID,
        result: Result<URL, Error>
    ) {
        guard operations[modelID]?.id == operationID else { return }
        operations[modelID] = nil
        let waiters = completionWaiters.removeValue(forKey: operationID) ?? [:]
        for continuation in waiters.values {
            continuation.resume(with: result)
        }
    }
}

/// Explicit model cancellation must survive the small URLSession race where a
/// manifest response completes just as its parent task is cancelled.
private final class ManagedASRModelCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        guard !isCancelled else { throw CancellationError() }
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
