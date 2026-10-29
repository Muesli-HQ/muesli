import FluidAudio
import Foundation
import MuesliCore

struct SpeechSegment: Sendable {
    let start: Double
    let end: Double
    let text: String
}

struct SpeechTranscriptionResult: Sendable {
    let text: String
    let segments: [SpeechSegment]
    let bodhanMeasurement: BodhanWBCSMeasurement?

    init(text: String, segments: [SpeechSegment], bodhanMeasurement: BodhanWBCSMeasurement? = nil) {
        self.text = text
        self.segments = segments
        self.bodhanMeasurement = bodhanMeasurement
    }
}

actor AppleSpeechUseLifecycle {
    typealias Cleanup = @Sendable () async -> Void

    struct Snapshot: Equatable, Sendable {
        let activeUseCount: Int
        let hasDeferredCleanup: Bool
        let isCleaningUp: Bool
    }

    private struct CleanupOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var activeUseCount = 0
    private var deferredCleanup: Cleanup?
    private var cleanupOperation: CleanupOperation?

    func beginUse() async {
        deferredCleanup = nil
        activeUseCount += 1

        if let operation = cleanupOperation {
            await operation.task.value
            finishCleanupIfCurrent(operation.id)
        }
    }

    func endUse() async {
        precondition(activeUseCount > 0, "Apple Speech use ended without a matching begin")
        activeUseCount -= 1
        if activeUseCount == 0 {
            await runDeferredCleanupIfNeeded()
        }
    }

    func requestCleanup(_ cleanup: @escaping Cleanup) async {
        deferredCleanup = cleanup

        if let operation = cleanupOperation {
            await operation.task.value
            finishCleanupIfCurrent(operation.id)
            if activeUseCount == 0 {
                await runDeferredCleanupIfNeeded()
            }
            return
        }

        if activeUseCount == 0 {
            await runDeferredCleanupIfNeeded()
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            activeUseCount: activeUseCount,
            hasDeferredCleanup: deferredCleanup != nil,
            isCleaningUp: cleanupOperation != nil
        )
    }

    private func runDeferredCleanupIfNeeded() async {
        guard cleanupOperation == nil, let cleanup = deferredCleanup else { return }
        deferredCleanup = nil

        let id = UUID()
        let task = Task { await cleanup() }
        cleanupOperation = CleanupOperation(id: id, task: task)
        await task.value
        finishCleanupIfCurrent(id)
    }

    private func finishCleanupIfCurrent(_ id: UUID) {
        if cleanupOperation?.id == id {
            cleanupOperation = nil
        }
    }
}

actor TranscriptionCoordinator {
    typealias DiarizerModelLoader = @Sendable (DiarizerRuntimePolicy) async throws -> DiarizerModels
    typealias VADLoader = @Sendable () async throws -> VadManager

    private enum DiarizerLoadWaitOutcome {
        case succeeded
        case failed
        case cancelled
        case timedOut
    }

    private struct DiarizerLoadWaiter {
        let continuation: CheckedContinuation<DiarizerLoadWaitOutcome, Never>
        let timeoutTask: Task<Void, Never>
    }

    // Product flows stop waiting after two minutes and continue without optional
    // diarization. The shared background load gets a longer cooperative deadline.
    private static let defaultDiarizerLoadWaitTimeout: Duration = .seconds(120)
    private static let defaultDiarizerLoadOperationTimeout: Duration = .seconds(300)

    static let explicitlyRoutedBackendIdentifiers: Set<String> = [
        "whisper", "nemotron35", "parakeet-unified", "qwen", "cohere", "medasr", "bodhan", "sensevoice", "gemma4-litert", "apple-speech",
    ]

    private let fluidTranscriber: FluidAudioTranscriber
    private let fluidAudioTranscriberFactory: @Sendable () -> FluidAudioTranscriber
    typealias LibraryModelDownload = @Sendable (
        String, ((Double, String?) -> Void)?, ModelDownloadProgressHandler?
    ) async throws -> Void
    private let libraryModelDownload: LibraryModelDownload
    private let libraryModelPreparation: ModelLibraryPreparation
    private let parakeetUnifiedTranscriber = ParakeetUnifiedTranscriber()
    private let whisperTranscriber = WhisperKitTranscriber()

    /// Constructs a preview session over already-loaded models. No microphone,
    /// download, cleanup, or durable transcript ownership belongs to this layer.
    nonisolated func makeBufferedTranscriptionSession(
        backend: BackendOption,
        whisperLanguage: WhisperKitLanguage,
        parakeetLanguage: ParakeetLanguage,
        bodhanLanguage: BodhanLanguage = .defaultLanguage,
        bodhanOutputMode: BodhanOutputMode = .mixed,
        onUpdate: @escaping @Sendable (BufferedTranscriptionUpdate) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void,
        onDiagnostic: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> BufferedTranscriptionSession {
        guard backend.supportsBufferedLiveTranscription else {
            throw NSError(domain: "MuesliBufferedTranscription", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Live previews require a supported Parakeet, WhisperKit, or Bodhan model."])
        }
        if backend.backend == "bodhan" {
            let metadata = BodhanPreviewMetadata()
            return BufferedTranscriptionSession(decodeWithoutTimings: { samples in
                try await self.transcribeBufferedBodhan(samples: samples, modelID: backend.model,
                    language: bodhanLanguage, outputMode: bodhanOutputMode,
                    onLanguageSample: { metadata.append($0) })
            }, measurement: { text in
                metadata.measurement(text: text, modelID: backend.model, outputMode: bodhanOutputMode)
            }, onSilentAudio: { metadata.advanceSilentAudio(samples: $0) }, onUpdate: onUpdate, onFailure: onFailure, onDiagnostic: onDiagnostic)
        }
        if backend.backend == "whisper" {
            let transcriber = whisperTranscriber
            let expectedModel = backend.model
            return BufferedTranscriptionSession(configuration: .whisper, decode: { samples in
                try await transcriber.transcribePreview(
                    samples: samples, language: whisperLanguage, expectedModel: expectedModel
                )
            }, decodeWithoutTimings: { samples in
                try await transcriber.transcribePreview(
                    samples: samples, language: whisperLanguage, expectedModel: expectedModel,
                    requiresWordTimings: false
                ).text
            }, onUpdate: onUpdate, onFailure: onFailure, onDiagnostic: onDiagnostic)
        }
        if backend == .parakeetUnified {
            let transcriber = parakeetUnifiedTranscriber
            return BufferedTranscriptionSession(decode: { samples in
                try await transcriber.transcribePreview(samples: samples)
            }, decodeWithoutTimings: { samples in
                try await transcriber.transcribePreview(samples: samples, requiresWordTimings: false).text
            }, onUpdate: onUpdate, onFailure: onFailure, onDiagnostic: onDiagnostic)
        }
        let transcriber = fluidTranscriber
        let version = FluidAudioModel.version(for: backend.model)
        return BufferedTranscriptionSession(decode: { samples in
            try await transcriber.transcribePreview(
                samples: samples, language: parakeetLanguage == .auto ? nil : parakeetLanguage.rawValue,
                expectedVersion: version
            )
        }, decodeWithoutTimings: { samples in
            try await transcriber.transcribePreview(
                samples: samples, language: parakeetLanguage == .auto ? nil : parakeetLanguage.rawValue,
                expectedVersion: version, requiresWordTimings: false
            ).text
        }, onUpdate: onUpdate, onFailure: onFailure, onDiagnostic: onDiagnostic)
    }
    private func transcribeBufferedBodhan(samples: [Float], modelID: String,
                                         language: BodhanLanguage, outputMode: BodhanOutputMode,
                                         onLanguageSample: @Sendable (BodhanLanguageSample) -> Void) async throws -> String {
        guard #available(macOS 15, *) else {
            throw NSError(domain: "BodhanASR", code: 32,
                          userInfo: [NSLocalizedDescriptionKey: "Bodhan requires macOS 15 or later."])
        }
        return try await bodhanTranscriber.transcribePreview(samples: samples, modelID: modelID,
                                                            language: language, outputMode: outputMode, onLanguageSample: onLanguageSample)
    }

    private var _qwen3Transcriber: Any?
    private var _qwen3PostProcessor: Any?
    private var _cohereTranscriber: Any?
    private var _bodhanTranscriber: Any?
    private var _gemma4LiteRTTranscriber: Any?
    private var nativeGemmaEngines: [Gemma4LiteRTModel: Any] = [:]
    private var _appleSpeechTranscriber: Any?
    private let appleSpeechLifecycle = AppleSpeechUseLifecycle()
    private let senseVoiceTranscriber = SenseVoiceTranscriber()
    private let medASRTranscriber = MedASRTranscriber()
    private var vadManager: VadManager?
    private var diarizerManager: DiarizerManager?
    private var isDiarizerLoadInProgress = false
    private var activeDiarizerLoadID: UUID?
    private var diarizerLoadTask: Task<Void, Never>?
    private var diarizerLoadTimeoutTask: Task<Void, Never>?
    private var didDiarizerLoadTimeOut = false
    private var diarizerLoadWaiters: [UUID: DiarizerLoadWaiter] = [:]
    private let diarizerModelLoader: DiarizerModelLoader
    private let vadLoader: VADLoader
    private let diarizerLoadOperationTimeout: Duration
    private let diarizerDiagnostics: DiarizerPreloadDiagnostics
    private var activeBackend: String?
    private let nativeGemmaReadinessInvalidated: @MainActor @Sendable () -> Void

    init(
        diarizerModelLoader: @escaping DiarizerModelLoader = { policy in
            try await DiarizerModels.download(configuration: policy.modelConfiguration)
        },
        vadLoader: @escaping VADLoader = { try await VadManager() },
        diarizerLoadOperationTimeout: Duration = TranscriptionCoordinator.defaultDiarizerLoadOperationTimeout,
        diarizerDiagnostics: DiarizerPreloadDiagnostics = DiarizerPreloadDiagnostics(),
        nativeGemmaReadinessInvalidated: @escaping @MainActor @Sendable () -> Void = {},
        fluidAudioTranscriberFactory: @escaping @Sendable () -> FluidAudioTranscriber = { FluidAudioTranscriber() },
        libraryModelPreparation: ModelLibraryPreparation = .shared,
        libraryModelDownload: @escaping LibraryModelDownload = { modelID, progress, progressSnapshot in
            _ = try await ManagedASRModelDownloader.downloadIfNeeded(FluidAudioModel.plan(for: modelID),
                progress: progress, progressSnapshot: progressSnapshot)
        }
    ) {
        self.libraryModelDownload = libraryModelDownload
        self.libraryModelPreparation = libraryModelPreparation
        self.fluidAudioTranscriberFactory = fluidAudioTranscriberFactory
        self.fluidTranscriber = fluidAudioTranscriberFactory()
        self.diarizerModelLoader = diarizerModelLoader
        self.vadLoader = vadLoader
        self.diarizerLoadOperationTimeout = diarizerLoadOperationTimeout
        self.diarizerDiagnostics = diarizerDiagnostics
        self.nativeGemmaReadinessInvalidated = nativeGemmaReadinessInvalidated
    }

    private var _nemotron35Transcriber: Any?
    /// Selected Nemotron 3.5 language prompt id (101 = auto). Stored so it survives
    /// lazy (re)creation of the transcriber and is applied whenever it loads.
    private var nemotron35PromptId: Int32 = 101

    @available(macOS 15, *)
    private var nemotron35Transcriber: Nemotron35StreamingTranscriber {
        if _nemotron35Transcriber == nil {
            _nemotron35Transcriber = Nemotron35StreamingTranscriber()
        }
        return _nemotron35Transcriber as! Nemotron35StreamingTranscriber
    }

    /// Loaded accessor for production dictation paths. Preload normally warms the
    /// model, but direct hold-to-talk or early double-tap after relaunch must not
    /// reach the actor while its CoreML models are still unloaded.
    @available(macOS 15, *)
    func getLoadedNemotron35Transcriber(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws -> Nemotron35StreamingTranscriber {
        let transcriber = nemotron35Transcriber
        await transcriber.setPromptId(nemotron35PromptId)
        try await transcriber.loadModels(progress: progress, progressSnapshot: progressSnapshot)
        return transcriber
    }

    /// Set the Nemotron 3.5 language prompt id (from app config). Applies to the
    /// live transcriber if it already exists.
    func setNemotron35PromptId(_ id: Int32) async {
        nemotron35PromptId = id
        if #available(macOS 15, *), let t = _nemotron35Transcriber as? Nemotron35StreamingTranscriber {
            await t.setPromptId(id)
        }
    }

    func unloadNemotron35Transcriber() async {
        if #available(macOS 15, *), let transcriber = _nemotron35Transcriber as? Nemotron35StreamingTranscriber {
            await transcriber.shutdown()
        }
    }

    func unloadBodhanTranscriber(ifLoadedModelID modelID: String) async {
        if #available(macOS 15, *), let transcriber = _bodhanTranscriber as? BodhanTranscriber {
            await transcriber.shutdown(ifLoadedModelID: modelID)
        }
    }

    func unloadGemma4LiteRTTranscriber() async {
        // Invalidate before suspension so a cached plan cannot admit recording.
        await nativeGemmaReadinessInvalidated()
        if #available(macOS 15, *) {
            nativeGemmaEngines.removeAll()
            // The planner can load a shared engine without creating this facade.
            await Gemma4LiteRTTranscriber.shared.shutdown()
            _gemma4LiteRTTranscriber = nil
        }
        // Also discard preparation that raced with the asynchronous teardown.
        await nativeGemmaReadinessInvalidated()
    }

    func unloadFluidAudioTranscriber(ifLoadedModelID modelID: String) async {
        await fluidTranscriber.shutdown(ifLoadedModelID: modelID)
    }

    func unloadParakeetUnifiedTranscriber() async {
        await parakeetUnifiedTranscriber.shutdown()
    }

    func unloadQwen3Transcriber() async {
        if #available(macOS 15, *), let transcriber = _qwen3Transcriber as? Qwen3AsrTranscriber {
            await transcriber.shutdown()
            _qwen3Transcriber = nil
        }
    }

    func unloadAppleSpeechTranscriber() async {
        if #available(macOS 26.0, *) {
            await appleSpeechLifecycle.requestCleanup { [weak self] in
                await self?.releaseAppleSpeechTranscriber()
            }
        }
    }

    @available(macOS 26.0, *)
    private func releaseAppleSpeechTranscriber() async {
        guard let transcriber = _appleSpeechTranscriber as? AppleSpeechAnalyzerTranscriber else { return }
        // Runtime unloading must not unsubscribe the app's selected language
        // or a live meeting's assets. The shared owner retires only unused locales.
        guard let current = _appleSpeechTranscriber as? AppleSpeechAnalyzerTranscriber,
              current === transcriber else { return }
        _appleSpeechTranscriber = nil
    }

    @available(macOS 15, *)
    private var qwen3Transcriber: Qwen3AsrTranscriber {
        if _qwen3Transcriber == nil {
            _qwen3Transcriber = Qwen3AsrTranscriber()
        }
        return _qwen3Transcriber as! Qwen3AsrTranscriber
    }

    private var postProcessorModelURL: URL = PostProcessorOption.defaultOption.modelURL
    private var postProcessorSystemPrompt: String = PostProcessorOption.defaultSystemPrompt
    private var postProcessorInputFormat: PostProcessorOption.InputFormat = PostProcessorOption.defaultOption.inputFormat
    private var postProcessorModelId: String = PostProcessorOption.defaultOption.id
    private var postProcessorBackend: TranscriptCleanupBackendOption = .local
    private var postProcessorConfig: AppConfig = AppConfig()

    private struct PostProcessorSnapshot {
        let backend: TranscriptCleanupBackendOption
        let modelURL: URL
        let systemPrompt: String
        let modelId: String
        let inputFormat: PostProcessorOption.InputFormat
        let config: AppConfig
    }

    @available(macOS 15, *)
    private var qwen3PostProcessor: Qwen3PostProcessor {
        if _qwen3PostProcessor == nil {
            _qwen3PostProcessor = Qwen3PostProcessor(
                modelURL: postProcessorModelURL,
                systemPrompt: postProcessorSystemPrompt,
                inputFormat: postProcessorInputFormat
            )
        }
        return _qwen3PostProcessor as! Qwen3PostProcessor
    }

    @available(macOS 15, *)
    func setActivePostProcessor(option: PostProcessorOption, systemPrompt: String) async {
        await configurePostProcessor(
            backend: .local,
            option: option,
            systemPrompt: systemPrompt,
            config: postProcessorConfig
        )
    }

    func configurePostProcessor(
        backend: TranscriptCleanupBackendOption,
        option: PostProcessorOption?,
        systemPrompt: String,
        config: AppConfig
    ) async {
        postProcessorBackend = backend
        postProcessorSystemPrompt = systemPrompt
        postProcessorConfig = config

        if backend == .gemma4LiteRT {
            postProcessorModelId = Gemma4LiteRTModel.resolved(config.postProcessorGemmaModel).repoID
        } else if let option {
            postProcessorModelURL = option.modelURL
            postProcessorModelId = option.id
            postProcessorInputFormat = option.inputFormat
            let effectiveSystemPrompt = option.effectiveSystemPrompt(configuredSystemPrompt: systemPrompt)
            postProcessorSystemPrompt = effectiveSystemPrompt
            if #available(macOS 15, *), let existing = _qwen3PostProcessor as? Qwen3PostProcessor {
                await existing.reconfigure(
                    modelURL: option.modelURL,
                    systemPrompt: effectiveSystemPrompt,
                    inputFormat: option.inputFormat
                )
            }
        } else if backend.llmBackend != nil {
            postProcessorModelId = TranscriptCleanupClient.configuredModel(for: backend, config: config)
        }
    }

    /// Local ASR for short-audio display previews and required long-audio text fallback.
    /// Never downloads artifacts; callers decide whether failure is optional or fatal.
    func transcribeQuilDisplayAudio(at url: URL) async throws -> String {
        guard BackendOption.parakeetUnified.isDownloaded else {
            throw ParakeetUnifiedTranscriber.TranscriberError.notLoaded
        }
        try Task.checkCancellation()
        try await parakeetUnifiedTranscriber.loadModels(localOnly: true)
        try Task.checkCancellation()
        let result = try await parakeetUnifiedTranscriber.transcribe(wavURL: url)
        try Task.checkCancellation()
        return result.text
    }

    func transformAudioForQuil(
        wavURL: URL, selectedText: String, appContext: String?, model: String
    ) async throws -> String {
        guard #available(macOS 15, *) else { throw QuilTransformationError.unsupportedModel }
        let gemmaModel = Gemma4LiteRTModel.resolved(model)
        guard Gemma4LiteRTModelStore.isAvailableLocally(model: gemmaModel) else {
            throw QuilTransformationError.modelUnavailable
        }
        try QuilModelPolicy.validate(selectedText: selectedText, backend: .gemma4LiteRT, model: model)
        let prompt = QuilTransformationPrompt.userPrompt(
            selectedText: selectedText,
            instruction: "Carry out the spoken instruction in the attached audio.",
            appContext: appContext
        )
        let raw: String
        if GemmaNativeAudioPolicy.isEnabled(for: gemmaModel) {
            raw = try await nativeGemma(for: gemmaModel).generateFromAudio(wavURL: wavURL,
                systemPrompt: QuilTransformationPrompt.audioSystem, userPrompt: prompt, model: gemmaModel,
                maxOutputTokens: QuilModelPolicy.gemmaMaximumOutputTokens)
        } else {
            raw = try await gemma4LiteRTTranscriber.generateFromAudio(
            wavURL: wavURL, systemPrompt: QuilTransformationPrompt.audioSystem,
            userPrompt: prompt, model: gemmaModel,
            maxOutputTokens: QuilModelPolicy.gemmaMaximumOutputTokens
        )
        }
        try Task.checkCancellation()
        // Do not run an ASR fallback or corrective second generation on this path.
        return try QuilTransformationOutput.validated(raw)
    }

    func transformSelectedTextForQuil(
        selectedText: String,
        instruction: String,
        appContext: String?,
        backend: TranscriptCleanupBackendOption,
        model: String,
        config: AppConfig,
        localOnly: Bool = false
    ) async throws -> String {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else { throw QuilTransformationError.emptyInstruction }
        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (backend == .local
                ? PostProcessorOption.defaultQuilOption.id
                : TranscriptCleanupClient.defaultModel(for: backend))
            : model
        try QuilModelPolicy.validate(selectedText: selectedText, backend: backend, model: resolvedModel)
        let userPrompt = QuilTransformationPrompt.userPrompt(
            selectedText: selectedText,
            instruction: trimmedInstruction,
            appContext: appContext,
            maxAppContextCharacters: QuilModelPolicy.appContextCharacterLimit(for: backend)
        )
        let raw = try await generateQuilReplacement(
            userPrompt: userPrompt,
            backend: backend,
            resolvedModel: resolvedModel,
            config: config, localOnly: localOnly
        )
        do {
            return try QuilTransformationOutput.validated(raw)
        } catch QuilTransformationError.nonReplacementResponse {
            let correctivePrompt = QuilTransformationPrompt.correctiveUserPrompt(userPrompt)
            let correctedRaw = try await generateQuilReplacement(
                userPrompt: correctivePrompt,
                backend: backend,
                resolvedModel: resolvedModel,
                config: config, localOnly: localOnly
            )
            return try QuilTransformationOutput.validated(correctedRaw)
        }
    }

    private func generateQuilReplacement(
        userPrompt: String,
        backend: TranscriptCleanupBackendOption,
        resolvedModel: String,
        config: AppConfig,
        localOnly: Bool
    ) async throws -> String {
        switch backend {
        case .local:
            guard #available(macOS 15, *) else {
                throw QuilTransformationError.unsupportedModel
            }
            let option = PostProcessorOption.resolve(id: resolvedModel)
            guard option.supportsQuil else { throw QuilTransformationError.unsupportedModel }
            guard option.isDownloaded || Qwen3PostProcessorConfig.devOverrideURL() != nil else {
                throw QuilTransformationError.modelUnavailable
            }
            let configuration = Qwen3PostProcessor.Configuration(
                modelURL: option.modelURL,
                systemPrompt: QuilTransformationPrompt.system,
                inputFormat: .configurable,
                maxTokenCount: Qwen3PostProcessorConfig.quilMaxContextTokens
            )
            return try await qwen3PostProcessor.generate(userPrompt, configuration: configuration)
        case .gemma4LiteRT:
            guard #available(macOS 15, *) else { throw QuilTransformationError.unsupportedModel }
            let gemmaModel = Gemma4LiteRTModel.resolved(resolvedModel)
            guard Gemma4LiteRTModelStore.isAvailableLocally(model: gemmaModel) else {
                throw QuilTransformationError.modelUnavailable
            }
            if GemmaNativeAudioPolicy.isEnabled(for: gemmaModel) {
                return try await nativeGemma(for: gemmaModel).generateText(systemPrompt: QuilTransformationPrompt.system,
                    userPrompt: userPrompt, model: gemmaModel, maxOutputTokens: QuilModelPolicy.gemmaMaximumOutputTokens)
            }
            return try await gemma4LiteRTTranscriber.generateText(
                systemPrompt: QuilTransformationPrompt.system,
                userPrompt: userPrompt,
                model: gemmaModel,
                maxOutputTokens: QuilModelPolicy.gemmaMaximumOutputTokens,
                localOnly: localOnly
            )
        default:
            return try await TranscriptCleanupClient.generate(
                systemPrompt: QuilTransformationPrompt.system,
                userPrompt: userPrompt,
                backend: backend,
                model: resolvedModel,
                config: config,
                maxOutputTokens: QuilModelPolicy.remoteMaximumOutputTokens,
                logCategory: "quil"
            )
        }
    }

    private struct PostProcPairLogEntry: Encodable {
        let ts: String
        let raw: String
        let processed: String
        let model: String
        let asr: String
    }

    private func logPostProcPair(raw: String, processed: String, model: String, asr: String) {
        guard Qwen3PostProcessorLogging.isPairLoggingEnabled else { return }
        let logURL = AppIdentity.supportDirectoryURL.appendingPathComponent("postproc-pairs.jsonl")
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso8601.string(from: Date())
        let entry = PostProcPairLogEntry(
            ts: ts,
            raw: raw,
            processed: processed,
            model: model,
            asr: asr
        )
        guard var data = try? JSONEncoder().encode(entry) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let fh = try? FileHandle(forWritingTo: logURL) {
                defer { try? fh.close() }
                fh.seekToEndOfFile()
                fh.write(data)
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    @available(macOS 15, *)
    private var cohereTranscriber: CohereTranscribeTranscriber {
        if _cohereTranscriber == nil {
            _cohereTranscriber = CohereTranscribeTranscriber()
        }
        return _cohereTranscriber as! CohereTranscribeTranscriber
    }

    @available(macOS 15, *)
    private var bodhanTranscriber: BodhanTranscriber {
        if _bodhanTranscriber == nil {
            _bodhanTranscriber = BodhanTranscriber()
        }
        return _bodhanTranscriber as! BodhanTranscriber
    }

    @available(macOS 15, *)
    private func nativeGemma(for model: Gemma4LiteRTModel) -> GemmaNativeAudioTranscriber {
        if let engine = nativeGemmaEngines[model] as? GemmaNativeAudioTranscriber { return engine }
        let engine = GemmaNativeAudioTranscriber.shared(for: model)
        nativeGemmaEngines[model] = engine
        return engine
    }

    func prepareNativeGemmaModels(_ plan: GemmaPreparationPlan, progress: @escaping @Sendable (String) -> Void) async throws {
        guard #available(macOS 15, *) else { return }
        try await plan.prepare(optionalModelAvailable: { Gemma4LiteRTModelStore.isAvailableLocally(model: $0) }, using: { entry in
            progress("Preparing \(entry.model.label)… Mic off")
            try await nativeGemma(for: entry.model).prepareForInteraction(model: entry.model, audio: entry.audio, text: entry.text)
        }, optionalFailure: { entry, error in
            fputs("[gemma-preparation] optional \(entry.model.rawValue) unavailable: \(error)\n", stderr)
        })
    }

    @available(macOS 15, *)
    private var gemma4LiteRTTranscriber: Gemma4LiteRTTranscriber {
        if _gemma4LiteRTTranscriber == nil {
            _gemma4LiteRTTranscriber = Gemma4LiteRTTranscriber.shared
        }
        return _gemma4LiteRTTranscriber as! Gemma4LiteRTTranscriber
    }

    @available(macOS 26.0, *)
    private var appleSpeechTranscriber: AppleSpeechAnalyzerTranscriber {
        if _appleSpeechTranscriber == nil {
            _appleSpeechTranscriber = AppleSpeechAnalyzerTranscriber.shared
        }
        return _appleSpeechTranscriber as! AppleSpeechAnalyzerTranscriber
    }

    @available(macOS 26.0, *)
    private func prepareAppleSpeech(
        languageIdentifier: String,
        progress: ((Double, String?) -> Void)?,
        progressSnapshot: ModelDownloadProgressHandler?
    ) async throws {
        await appleSpeechLifecycle.beginUse()
        let transcriber = appleSpeechTranscriber
        do {
            try Task.checkCancellation()
            _ = try await transcriber.prepare(
                requestedLocale: AppleSpeechLanguageOption.requestedLocale(for: languageIdentifier),
                progress: progress,
                progressSnapshot: progressSnapshot
            )
            await appleSpeechLifecycle.endUse()
        } catch {
            await appleSpeechLifecycle.endUse()
            throw error
        }
    }

    @available(macOS 26.0, *)
    private func transcribeWithAppleSpeech(
        url: URL,
        languageIdentifier: String
    ) async throws -> SpeechTranscriptionResult {
        await appleSpeechLifecycle.beginUse()
        let transcriber = appleSpeechTranscriber
        do {
            try Task.checkCancellation()
            let result = try await transcriber.transcribe(
                wavURL: url,
                requestedLocale: AppleSpeechLanguageOption.requestedLocale(for: languageIdentifier)
            )
            await appleSpeechLifecycle.endUse()
            return result
        } catch {
            await appleSpeechLifecycle.endUse()
            throw error
        }
    }

    func preload(
        backend: BackendOption,
        enablePostProcessor: Bool = false,
        includeMeetingHelpers: Bool = true,
        meetingHelperTrigger: DiarizerPreloadTrigger = .unspecified,
        appleSpeechLanguage: String = AppleSpeechLanguageOption.systemIdentifier,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async {
        do {
            try await preloadRequired(
                backend: backend,
                enablePostProcessor: enablePostProcessor,
                includeMeetingHelpers: includeMeetingHelpers,
                meetingHelperTrigger: meetingHelperTrigger,
                appleSpeechLanguage: appleSpeechLanguage,
                progress: progress,
                progressSnapshot: progressSnapshot
            )
        } catch {
            fputs("[muesli-native] preload failed for \(backend.backend)/\(backend.model): \(error)\n", stderr)
        }
    }

    func preloadRequired(
        backend: BackendOption,
        enablePostProcessor: Bool = false,
        includeMeetingHelpers: Bool = true,
        meetingHelperTrigger: DiarizerPreloadTrigger = .unspecified,
        appleSpeechLanguage: String = AppleSpeechLanguageOption.systemIdentifier,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        if backend.backend == "medasr" { try MedASRLicense.shared.requireAcceptance() }
        if backend.backend == "medasr", meetingHelperTrigger == .modelLibrary {
            try await libraryModelPreparation.run {
                _ = try await ManagedASRModelDownloader.downloadIfNeeded(MedASRModel.plan(),
                    progress: progress, progressSnapshot: progressSnapshot)
            } onQueued: {
                progressSnapshot?(.preparing(modelID: backend.model, message: "Waiting to prepare MedASR..."))
            } prepare: {
                let transcriber = MedASRTranscriber()
                do {
                    try await transcriber.prepare(progress: progress, progressSnapshot: progressSnapshot)
                    await transcriber.shutdown()
                } catch {
                    await transcriber.shutdown()
                    throw error
                }
            }
            return
        }
        if backend.backend == "fluidaudio", meetingHelperTrigger == .modelLibrary {
            // A library download is not a selection: validate in a disposable runtime
            // so independent downloads cannot cancel or replace the active manager.
            try await libraryModelPreparation.run {
                try await self.libraryModelDownload(backend.model, progress, progressSnapshot)
            } onQueued: {
                progressSnapshot?(.preparing(modelID: backend.model,
                    message: "Waiting to prepare \(backend.label)..."))
            } prepare: {
                let downloadTranscriber = self.fluidAudioTranscriberFactory()
                do {
                    try await downloadTranscriber.loadModels(modelID: backend.model,
                        progress: progress, progressSnapshot: progressSnapshot)
                    await downloadTranscriber.shutdown()
                } catch {
                    await downloadTranscriber.shutdown()
                    throw error
                }
            }
            return
        }
        activeBackend = backend.backend

        if includeMeetingHelpers {
            await preloadMeetingHelpers(trigger: meetingHelperTrigger)
        }
        try Task.checkCancellation()

        switch backend.backend {
        case "fluidaudio":
            try await fluidTranscriber.loadModels(
                modelID: backend.model,
                progress: progress,
                progressSnapshot: progressSnapshot
            )
        case "parakeet-unified":
            try await parakeetUnifiedTranscriber.loadModels(
                progress: progress,
                progressSnapshot: progressSnapshot
            )
        case "whisper":
            try await whisperTranscriber.loadModel(
                modelName: backend.model,
                progress: progress,
                progressSnapshot: progressSnapshot
            )
            // Warmup ANE/GPU so first dictation doesn't pay CoreML compilation cost
            fputs("[muesli-native] WhisperKit warmup: running silent audio for CoreML compilation...\n", stderr)
            let warming = ModelDownloadProgress.preparing(
                modelID: backend.model,
                message: "Warming up model..."
            )
            progress?(0.9, warming.message)
            progressSnapshot?(warming)
            try await whisperTranscriber.warmup()
            fputs("[muesli-native] WhisperKit warmup complete\n", stderr)
            progress?(1.0, nil)
            progressSnapshot?(warming.replacing(phase: .ready, message: "Model ready"))
        case "nemotron35":
            if #available(macOS 15, *) {
                let transcriber = try await getLoadedNemotron35Transcriber(progress: progress, progressSnapshot: progressSnapshot)
                // Warmup ANE so first dictation starts instantly
                fputs("[muesli-native] Nemotron 3.5 warmup: running silent chunk for ANE compilation...\n", stderr)
                var state = try await transcriber.makeStreamState()
                let silence = [Float](repeating: 0, count: transcriber.chunkSamples)
                _ = try await transcriber.transcribeChunk(samples: silence, state: &state)
                fputs("[muesli-native] Nemotron 3.5 warmup complete\n", stderr)
            } else {
                throw NSError(domain: "MuesliTranscriptionRuntime", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Nemotron 3.5 requires macOS 15 or later.",
                ])
            }
        case "qwen":
            if #available(macOS 15, *) {
                try await qwen3Transcriber.loadModels(
                    progress: progress,
                    progressSnapshot: progressSnapshot
                )
            } else {
                throw NSError(domain: "MuesliTranscriptionRuntime", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Qwen3 ASR requires macOS 15 or later.",
                ])
            }
        case "medasr":
            try await medASRTranscriber.prepare(progress: progress, progressSnapshot: progressSnapshot)
        case "cohere":
            if #available(macOS 15, *) {
                try await cohereTranscriber.prepare(progress: progress, progressSnapshot: progressSnapshot)
            } else {
                throw NSError(domain: "MuesliTranscriptionRuntime", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Cohere Transcribe requires macOS 15 or later.",
                ])
            }
        case "bodhan":
            if #available(macOS 15, *) {
                try await bodhanTranscriber.prepare(modelID: backend.model, progress: progress, progressSnapshot: progressSnapshot)
            } else {
                throw NSError(domain: "MuesliTranscriptionRuntime", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "Bodhan requires macOS 15 or later.",
                ])
            }
        case "sensevoice":
            try await senseVoiceTranscriber.loadModels(
                progress: progress,
                progressSnapshot: progressSnapshot
            )
        case "gemma4-litert":
            if #available(macOS 15, *) {
                let model = Gemma4LiteRTModel.resolved(backend.model)
                // The compatibility facade performs managed target + drafter downloads
                // before preparing the shared native engine, including progress snapshots.
                try await gemma4LiteRTTranscriber.prepare(model: model, progress: progress, progressSnapshot: progressSnapshot)
            } else {
                throw NSError(domain: "MuesliTranscriptionRuntime", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "\(backend.label) requires macOS 15 or later.",
                ])
            }
        case "apple-speech":
            if #available(macOS 26.0, *) {
                try await prepareAppleSpeech(
                    languageIdentifier: appleSpeechLanguage,
                    progress: progress,
                    progressSnapshot: progressSnapshot
                )
            } else {
                throw AppleSpeechAnalyzerError.unavailable
            }
        default:
            throw NSError(domain: "MuesliTranscriptionRuntime", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Unknown transcription backend: \(backend.backend)",
            ])
        }

        await preloadPostProcessorIfNeeded(enabled: enablePostProcessor, transcriptionBackend: backend)
    }

    func preloadMeetingHelpers(trigger: DiarizerPreloadTrigger = .unspecified) async {
        await preloadMeetingVAD()
        await preloadDiarizer(trigger: trigger)
    }

    func preloadMeetingVAD() async {
        if vadManager == nil {
            do {
                vadManager = try await vadLoader()
                fputs("[muesli-native] Silero VAD loaded\n", stderr)
            } catch {
                fputs("[muesli-native] VAD load failed (non-critical): \(error)\n", stderr)
            }
        }
    }

    func preloadDiarizer(
        trigger: DiarizerPreloadTrigger = .unspecified,
        waitTimeout: Duration = TranscriptionCoordinator.defaultDiarizerLoadWaitTimeout
    ) async {
        let policy = DiarizerRuntimePolicy.resolve(for: .current())
        let context = DiarizerPreloadContext(
            trigger: trigger,
            policy: policy,
            cacheState: .resolve()
        )

        if diarizerManager != nil {
            diarizerDiagnostics.skipped(context, reason: "already_loaded")
            return
        }

        let startedLoad = !isDiarizerLoadInProgress
        if startedLoad {
            startDiarizerLoad(policy: policy, context: context)
        }

        let outcome = await waitForActiveDiarizerLoad(timeout: waitTimeout)
        let resolvedOutcome: DiarizerLoadWaitOutcome = Task.isCancelled ? .cancelled : outcome
        switch (startedLoad, resolvedOutcome) {
        case (true, .succeeded), (true, .failed):
            // The load lifecycle itself emits the terminal diagnostic.
            break
        case (false, .succeeded):
            diarizerDiagnostics.skipped(context, reason: "joined_load_succeeded")
        case (false, .failed):
            diarizerDiagnostics.skipped(context, reason: "joined_load_failed")
        case (true, .cancelled):
            diarizerDiagnostics.skipped(context, reason: "load_wait_cancelled")
        case (false, .cancelled):
            diarizerDiagnostics.skipped(context, reason: "joined_load_cancelled")
        case (true, .timedOut):
            diarizerDiagnostics.skipped(context, reason: "load_wait_timed_out")
        case (false, .timedOut):
            diarizerDiagnostics.skipped(context, reason: "joined_load_timed_out")
        }
    }

    private func startDiarizerLoad(
        policy: DiarizerRuntimePolicy,
        context: DiarizerPreloadContext
    ) {
        isDiarizerLoadInProgress = true
        didDiarizerLoadTimeOut = false
        let loadID = UUID()
        activeDiarizerLoadID = loadID
        let startedAt = diarizerDiagnostics.begin(context)

        let loader = diarizerModelLoader
        diarizerLoadTask = Task { [weak self] in
            do {
                let models = try await loader(policy)
                try Task.checkCancellation()
                await self?.finishDiarizerLoad(
                    id: loadID,
                    result: .success(models),
                    policy: policy,
                    context: context,
                    startedAt: startedAt
                )
            } catch {
                await self?.finishDiarizerLoad(
                    id: loadID,
                    result: .failure(error),
                    policy: policy,
                    context: context,
                    startedAt: startedAt
                )
            }
        }

        let operationTimeout = diarizerLoadOperationTimeout
        diarizerLoadTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: operationTimeout)
            } catch {
                return
            }
            await self?.timeoutDiarizerLoad(id: loadID)
        }
    }

    private func finishDiarizerLoad(
        id: UUID,
        result: Result<DiarizerModels, Error>,
        policy: DiarizerRuntimePolicy,
        context: DiarizerPreloadContext,
        startedAt: Date
    ) {
        guard activeDiarizerLoadID == id else { return }

        let didTimeOut = didDiarizerLoadTimeOut
        diarizerLoadTimeoutTask?.cancel()
        diarizerLoadTimeoutTask = nil
        diarizerLoadTask = nil
        activeDiarizerLoadID = nil
        isDiarizerLoadInProgress = false
        didDiarizerLoadTimeOut = false

        let outcome: DiarizerLoadWaitOutcome
        switch result {
        case .success(let models):
            let diarizer = DiarizerManager()
            diarizer.initialize(models: models)
            diarizerManager = diarizer
            diarizerDiagnostics.ready(context, startedAt: startedAt)
            fputs(
                "[muesli-native] Speaker diarization loaded (compute: \(policy.computePolicy.rawValue))\n",
                stderr
            )
            outcome = .succeeded
        case .failure(let error):
            let reportedError: Error = didTimeOut ? DiarizerPreloadFailure.operationTimedOut : error
            diarizerDiagnostics.failed(context, startedAt: startedAt, error: reportedError)
            fputs("[muesli-native] Diarization load failed (non-critical): \(reportedError)\n", stderr)
            outcome = .failed
        }

        resumeAllDiarizerLoadWaiters(with: outcome)
    }

    private func timeoutDiarizerLoad(id: UUID) {
        guard activeDiarizerLoadID == id else { return }
        didDiarizerLoadTimeOut = true
        diarizerLoadTask?.cancel()
        // A third-party model load may not observe cancellation while CoreML is
        // compiling. Release product callers immediately while retaining the
        // active-load guard so another expensive load cannot start in parallel.
        resumeAllDiarizerLoadWaiters(with: .timedOut)
    }

    private func waitForActiveDiarizerLoad(timeout: Duration) async -> DiarizerLoadWaitOutcome {
        if didDiarizerLoadTimeOut { return .timedOut }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }

                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.resumeDiarizerLoadWaiter(id: waiterID, with: .timedOut)
                }
                diarizerLoadWaiters[waiterID] = DiarizerLoadWaiter(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: { [weak self] in
            Task {
                await self?.resumeDiarizerLoadWaiter(id: waiterID, with: .cancelled)
            }
        }
    }

    private func resumeDiarizerLoadWaiter(id: UUID, with outcome: DiarizerLoadWaitOutcome) {
        guard let waiter = diarizerLoadWaiters.removeValue(forKey: id) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: outcome)
    }

    private func resumeAllDiarizerLoadWaiters(with outcome: DiarizerLoadWaitOutcome) {
        let waiters = diarizerLoadWaiters.values
        diarizerLoadWaiters.removeAll()
        for waiter in waiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: outcome)
        }
    }

    #if DEBUG
    func diarizerPreloadStateForTesting() -> (isActive: Bool, waiterCount: Int) {
        (isDiarizerLoadInProgress, diarizerLoadWaiters.count)
    }
    #endif

    /// Required, visible preparation. Unlike optional startup preload, failures
    /// propagate to the recording gate so it never announces a failed load as ready.
    func prepareLocalCleanupForRecording(option: PostProcessorOption, config: AppConfig) async throws {
        guard #available(macOS 15, *) else { return }
        try Task.checkCancellation()
        await configurePostProcessor(backend: .local, option: option,
                                     systemPrompt: config.postProcessorSystemPrompt, config: config)
        try await qwen3PostProcessor.prepare()
        try Task.checkCancellation()
    }

    func preloadPostProcessorIfNeeded(
        enabled: Bool,
        transcriptionBackend: BackendOption? = nil
    ) async {
        guard enabled,
              transcriptionBackend.map({ postProcessorBackend.isCompatible(with: $0) }) ?? true,
              #available(macOS 15, *) else { return }
        do {
            switch postProcessorBackend {
            case .local:
                try await qwen3PostProcessor.prepare()
            case .gemma4LiteRT:
                let model = Gemma4LiteRTModel.resolved(postProcessorModelId)
                if GemmaNativeAudioPolicy.isEnabled(for: model) { try await nativeGemma(for: model).prepare(model: model) }
                else { try await gemma4LiteRTTranscriber.prepare(model: model) }
            default:
                return
            }
        } catch {
            if postProcessorBackend == .local {
                Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor preload failed: \(error)")
            } else {
                Gemma4LiteRTLogging.log("Gemma cleanup preload failed: \(error)")
            }
        }
    }

    private func currentPostProcessorSnapshot() -> PostProcessorSnapshot {
        PostProcessorSnapshot(
            backend: postProcessorBackend,
            modelURL: postProcessorModelURL,
            systemPrompt: postProcessorSystemPrompt,
            modelId: postProcessorModelId,
            inputFormat: postProcessorInputFormat,
            config: postProcessorConfig
        )
    }

    func transcribeDictation(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage = CohereTranscribeLanguage.defaultLanguage,
        bodhanLanguage: BodhanLanguage = BodhanLanguage.defaultLanguage,
        bodhanOutputMode: BodhanOutputMode = .mixed,
        whisperLanguage: WhisperKitLanguage = WhisperKitLanguage.defaultLanguage,
        qwen3AsrLanguage: Qwen3AsrLanguage = Qwen3AsrLanguage.defaultLanguage,
        parakeetLanguage: ParakeetLanguage = ParakeetLanguage.defaultLanguage,
        appleSpeechLanguage: String = AppleSpeechLanguageOption.systemIdentifier,
        enablePostProcessor: Bool = false,
        customWords: [[String: Any]] = [],
        appContext: String? = nil,
        timingRequestID: String? = nil
    ) async throws -> SpeechTranscriptionResult {
        try await TranscriptCleanupDebugLogger.$requestID.withValue(timingRequestID ?? UUID().uuidString) {
            let totalStart = ProcessInfo.processInfo.systemUptime
            defer { TranscriptCleanupDebugLogger.timing("dictation_processing_total", since: totalStart) }
            // Qwen3 post-processing is intentionally dictation-only. Meeting transcription should keep raw backend/Parakeet output.
            // Cohere decodes hallucinated text from silence — skip if VAD detects no speech
            if backend.backend == "cohere", let vadManager {
                do {
                    let vadResults = try await vadManager.process(url)
                    let hasSpeech = vadResults.contains { $0.probability > 0.5 }
                    if !hasSpeech {
                        fputs("[muesli-native] VAD: dictation is silent, skipping Cohere transcription\n", stderr)
                        return SpeechTranscriptionResult(text: "", segments: [])
                    }
                } catch {
                    fputs("[muesli-native] VAD check failed, transcribing anyway: \(error)\n", stderr)
                }
            }
            let asrStart = ProcessInfo.processInfo.systemUptime
            var asrSucceeded = false
            defer {
                if !asrSucceeded {
                    TranscriptCleanupDebugLogger.timing("asr_failed", since: asrStart, detail: backend.backend)
                }
            }
            let result = try await route(
                url: url,
                backend: backend,
                cohereLanguage: cohereLanguage,
                bodhanLanguage: bodhanLanguage,
                bodhanOutputMode: bodhanOutputMode,
                whisperLanguage: whisperLanguage,
                qwen3AsrLanguage: qwen3AsrLanguage,
                parakeetLanguage: parakeetLanguage,
                appleSpeechLanguage: appleSpeechLanguage
            )
            asrSucceeded = true
            TranscriptCleanupDebugLogger.timing("asr_completed", since: asrStart, detail: backend.backend)
            return await finalizeDictationTranscript(
                result, backend: backend, enablePostProcessor: enablePostProcessor,
                customWords: customWords, appContext: appContext,
                timingRequestID: timingRequestID
            )
        }
    }

    /// Both full-recording ASR and a verified, drained stream use exactly the
    /// same artifact removal, optional local cleanup, and custom dictionary.
    func finalizeDictationTranscript(
        _ transcript: SpeechTranscriptionResult,
        backend: BackendOption,
        enablePostProcessor: Bool = false,
        customWords: [[String: Any]] = [],
        appContext: String? = nil,
        timingRequestID: String? = nil
    ) async -> SpeechTranscriptionResult {
        await TranscriptCleanupDebugLogger.$requestID.withValue(
            timingRequestID ?? TranscriptCleanupDebugLogger.requestID ?? UUID().uuidString
        ) {
            // WBCS describes the original Bodhan transcription of spoken words.
            // Cleanup and custom-word replacement can change displayed text, so
            // preserve the ASR measurement separately from that final text.
            var result = transcript
            let rawASRText = result.text
            let bodhanMeasurement = result.bodhanMeasurement
            result = removeArtifacts(result)
            if !result.text.isEmpty {
                Qwen3PostProcessorLogging.logVerbose("Dictation raw transcript after artifact cleanup: \(result.text)")
            }
            // Capture this after recognition finishes. The snapshot is then passed through the
            // complete cleanup path, so a model switch cannot change the model or
            // empty-output policy for this dictation.
            let postProcessorSnapshot = currentPostProcessorSnapshot()
            let cleanupStart = ProcessInfo.processInfo.systemUptime
            result = await postProcessDictationIfNeeded(
                result,
                backend: backend,
                enabled: enablePostProcessor,
                postProcessorSnapshot: postProcessorSnapshot,
                appContext: appContext
            ) ?? removeFillersWithLogging(result)
            TranscriptCleanupDebugLogger.timing("cleanup_total", since: cleanupStart,
                                                detail: "enabled=\(enablePostProcessor) model=\(postProcessorSnapshot.modelId)")
            let final = removeArtifacts(applyCustomWords(result, customWords: customWords), preservingLayout: true)
            TranscriptCleanupDebugLogger.append(
                status: "dictation_final", cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: postProcessorSnapshot.modelId, asrBackend: backend.backend,
                appContextText: appContext, rawASRText: rawASRText,
                cleanupOutputText: final.text)
            if !final.text.isEmpty {
                Qwen3PostProcessorLogging.logVerbose("Dictation final transcript: \(final.text)")
            }
            return SpeechTranscriptionResult(
                text: final.text,
                segments: final.segments,
                bodhanMeasurement: bodhanMeasurement
            )
        }
    }

    func transcribeMeeting(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage = CohereTranscribeLanguage.defaultLanguage,
        bodhanLanguage: BodhanLanguage = BodhanLanguage.defaultLanguage,
        bodhanOutputMode: BodhanOutputMode = .mixed,
        whisperLanguage: WhisperKitLanguage = WhisperKitLanguage.defaultLanguage,
        qwen3AsrLanguage: Qwen3AsrLanguage = Qwen3AsrLanguage.defaultLanguage,
        parakeetLanguage: ParakeetLanguage = ParakeetLanguage.defaultLanguage,
        appleSpeechLanguage: String = AppleSpeechLanguageOption.systemIdentifier
    ) async throws -> SpeechTranscriptionResult {
        // Meetings intentionally skip Qwen/custom-word post-processing. Keep deterministic artifact/filler cleanup only.
        cleanMeetingTranscript(try await route(
            url: url,
            backend: backend,
            cohereLanguage: cohereLanguage,
            bodhanLanguage: bodhanLanguage,
            bodhanOutputMode: bodhanOutputMode,
            whisperLanguage: whisperLanguage,
            qwen3AsrLanguage: qwen3AsrLanguage,
            parakeetLanguage: parakeetLanguage,
            appleSpeechLanguage: appleSpeechLanguage
        ))
    }

    /// Imports and retained recordings share bounded replay; live capture keeps
    /// its own chunking, repair and noise-cancellation path.
    func transcribeRecordedAudio(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage = CohereTranscribeLanguage.defaultLanguage,
        bodhanLanguage: BodhanLanguage = BodhanLanguage.defaultLanguage,
        bodhanOutputMode: BodhanOutputMode = .mixed,
        whisperLanguage: WhisperKitLanguage = WhisperKitLanguage.defaultLanguage,
        qwen3AsrLanguage: Qwen3AsrLanguage = Qwen3AsrLanguage.defaultLanguage,
        parakeetLanguage: ParakeetLanguage = ParakeetLanguage.defaultLanguage,
        appleSpeechLanguage: String = AppleSpeechLanguageOption.systemIdentifier,
        progress: @escaping @Sendable (Double, String) async -> Void = { _, _ in }
    ) async throws -> SpeechTranscriptionResult {
        try await MeetingRecordingTranscriber().transcribe(url: url, infer: { chunk in
            try await self.transcribeMeetingChunk(
                at: chunk,
                backend: backend,
                cohereLanguage: cohereLanguage,
                bodhanLanguage: bodhanLanguage,
                bodhanOutputMode: bodhanOutputMode,
                whisperLanguage: whisperLanguage,
                qwen3AsrLanguage: qwen3AsrLanguage,
                parakeetLanguage: parakeetLanguage,
                appleSpeechLanguage: appleSpeechLanguage
            )
        }, progress: progress)
    }

    func transcribeMeetingChunk(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage = CohereTranscribeLanguage.defaultLanguage,
        bodhanLanguage: BodhanLanguage = BodhanLanguage.defaultLanguage,
        bodhanOutputMode: BodhanOutputMode = .mixed,
        whisperLanguage: WhisperKitLanguage = WhisperKitLanguage.defaultLanguage,
        qwen3AsrLanguage: Qwen3AsrLanguage = Qwen3AsrLanguage.defaultLanguage,
        parakeetLanguage: ParakeetLanguage = ParakeetLanguage.defaultLanguage,
        appleSpeechLanguage: String = AppleSpeechLanguageOption.systemIdentifier
    ) async throws -> SpeechTranscriptionResult {
        // Meeting chunks intentionally skip Qwen/custom-word post-processing for reconciliation.
        // Run VAD to skip silent chunks (prevents hallucinations)
        if let vadManager {
            do {
                let vadResults = try await vadManager.process(url)
                let hasSpeech = vadResults.contains { $0.probability > 0.5 }
                if !hasSpeech {
                    fputs("[muesli-native] VAD: chunk is silent, skipping transcription\n", stderr)
                    return SpeechTranscriptionResult(text: "", segments: [])
                }
            } catch {
                fputs("[muesli-native] VAD check failed, transcribing anyway: \(error)\n", stderr)
            }
        }
        return cleanMeetingTranscript(try await route(
            url: url,
            backend: backend,
            cohereLanguage: cohereLanguage,
            bodhanLanguage: bodhanLanguage,
            bodhanOutputMode: bodhanOutputMode,
            whisperLanguage: whisperLanguage,
            qwen3AsrLanguage: qwen3AsrLanguage,
            parakeetLanguage: parakeetLanguage,
            appleSpeechLanguage: appleSpeechLanguage
        ))
    }

    /// Shared bounded PCM diarization for imported/retained recordings and both
    /// meeting channels. Each invocation has independent speaker identities.
    func diarizeRecordedAudio(
        at url: URL,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> [TimedSpeakerSegment] {
        try Task.checkCancellation()
        guard let diarizerManager, diarizerManager.isAvailable else { throw DiarizerError.notInitialized }
        let session = RecordedAudioDiarizationSession(manager: diarizerManager)
        let reader = try DiarizationPCMWindowReader(url: url)
        var segments: [TimedSpeakerSegment] = []
        while let window = try reader.next() {
            segments.append(contentsOf: try session.process(window))
            await progress(window.fraction)
        }
        try Task.checkCancellation()
        return segments
    }

    func diarizeSystemAudio(at url: URL) async throws -> [TimedSpeakerSegment]? {
        guard let diarizerManager, diarizerManager.isAvailable else {
            fputs("[muesli-native] diarization not available, skipping\n", stderr)
            return nil
        }
        fputs("[muesli-native] running speaker diarization on system audio...\n", stderr)
        let result = try await diarizeRecordedAudio(at: url)
        let speakerCount = Set(result.map(\.speakerId)).count
        fputs("[muesli-native] diarization complete: \(result.count) segments, \(speakerCount) speakers\n", stderr)
        return result
    }

    func getVadManager() -> VadManager? {
        vadManager
    }

    func getDiarizerManager() -> DiarizerManager? {
        diarizerManager
    }

    func shutdown() async {
        await fluidTranscriber.shutdown()
        await parakeetUnifiedTranscriber.shutdown()
        await whisperTranscriber.shutdown()
        await senseVoiceTranscriber.shutdown()
        await medASRTranscriber.shutdown()
        if #available(macOS 15, *) {
            if let nemotron35 = _nemotron35Transcriber as? Nemotron35StreamingTranscriber {
                await nemotron35.shutdown()
            }
            await qwen3Transcriber.shutdown()
            if let postProcessor = _qwen3PostProcessor as? Qwen3PostProcessor {
                await postProcessor.shutdown()
            }
            await cohereTranscriber.shutdown()
            await bodhanTranscriber.shutdown()
            await unloadGemma4LiteRTTranscriber()
        }
    }

    private func removeFillers(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        let filtered = FillerWordFilter.apply(result.text)
        return SpeechTranscriptionResult(text: filtered, segments: result.segments)
    }

    private func removeFillersWithLogging(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        let start = CFAbsoluteTimeGetCurrent()
        let filtered = removeFillers(result)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if filtered.text != result.text {
            Qwen3PostProcessorLogging.logVerbose("FillerWordFilter applied in \(String(format: "%.1f", elapsedMs))ms -> \(filtered.text)")
        } else {
            Qwen3PostProcessorLogging.logVerbose("FillerWordFilter skipped effective changes (\(String(format: "%.1f", elapsedMs))ms)")
        }
        return filtered
    }

    private func cleanMeetingTranscript(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        removeFillers(removeArtifacts(result))
    }

    private func removeArtifacts(_ result: SpeechTranscriptionResult, preservingLayout: Bool = false) -> SpeechTranscriptionResult {
        let filtered = preservingLayout
            ? TranscriptionEngineArtifactsFilter.applyPreservingLayout(result.text)
            : TranscriptionEngineArtifactsFilter.apply(result.text)
        let segments = filtered.isEmpty ? [] : TranscriptionEngineArtifactsFilter.apply(to: result.segments, preservingLayout: preservingLayout)
        return SpeechTranscriptionResult(text: filtered, segments: segments)
    }

    private func postProcessDictationIfNeeded(
        _ result: SpeechTranscriptionResult,
        backend: BackendOption,
        enabled: Bool,
        postProcessorSnapshot: PostProcessorSnapshot,
        appContext: String? = nil
    ) async -> SpeechTranscriptionResult? {
        guard enabled else {
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor disabled for dictation")
            return nil
        }
        guard !result.text.isEmpty else {
            Qwen3PostProcessorLogging.logVerbose("Post-processor skipped: empty transcript")
            return nil
        }
        guard postProcessorSnapshot.backend.isCompatible(with: backend, inputFormat: postProcessorSnapshot.inputFormat) else {
            Qwen3PostProcessorLogging.logVerbose("Cleanup skipped: incompatible transcription and cleanup models")
            return nil
        }
        if postProcessorSnapshot.backend.isGemma4LiteRT {
            return await postProcessDictationWithGemma4(
                result,
                backend: backend,
                postProcessorSnapshot: postProcessorSnapshot,
                appContext: appContext
            )
        }
        if postProcessorSnapshot.backend.llmBackend != nil {
            return await postProcessDictationWithHostedBackend(
                result,
                backend: backend,
                postProcessorSnapshot: postProcessorSnapshot,
                appContext: appContext
            )
        }
        guard #available(macOS 15, *) else {
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor skipped: requires macOS 15+")
            return nil
        }

        do {
            // The explicit toggle means "always try cleanup" for dictation.
            // Trigger heuristics were removed; the only remaining heuristic here preserves deletion-cue empty output.
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor forced by toggle")
            let start = CFAbsoluteTimeGetCurrent()
            let cleanup = try await qwen3PostProcessor.processResult(
                result.text,
                appContext: appContext,
                configuration: Qwen3PostProcessor.Configuration(
                    modelURL: postProcessorSnapshot.modelURL,
                    systemPrompt: postProcessorSnapshot.systemPrompt,
                    inputFormat: postProcessorSnapshot.inputFormat
                )
            )
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let processed = cleanup.text
            let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty,
               postProcessorSnapshot.inputFormat != .s1Mini,
               !Qwen3DeletionCueDetector.containsDeletionCue(result.text) {
                Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor returned empty output in \(String(format: "%.1f", elapsedMs))ms; falling back")
                TranscriptCleanupDebugLogger.append(
                    status: "fallback_empty_output",
                    cleanupBackend: postProcessorSnapshot.backend,
                    cleanupModel: postProcessorSnapshot.modelId,
                    asrBackend: backend.backend,
                    appContextText: appContext,
                    rawASRText: result.text,
                    rawCleanupOutputText: cleanup.rawOutput,
                    cleanupOutputText: trimmed,
                    elapsedMs: elapsedMs
                )
                return nil
            }
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor applied to \(backend.label) in \(String(format: "%.1f", elapsedMs))ms (chars=\(trimmed.count))")
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor final output: \(trimmed)")
            logPostProcPair(raw: result.text, processed: trimmed, model: postProcessorSnapshot.modelId, asr: backend.backend)
            TranscriptCleanupDebugLogger.append(
                status: cleanup.didFallback ? "fallback_original_transcript" : "applied",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: postProcessorSnapshot.modelId,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                rawCleanupOutputText: cleanup.rawOutput,
                cleanupOutputText: trimmed,
                elapsedMs: elapsedMs
            )
            return SpeechTranscriptionResult(
                text: trimmed,
                // Original ASR segments describe pre-cleanup text. Keep them only for debug diagnostics.
                segments: Qwen3PostProcessorLogging.isVerboseEnabled && !trimmed.isEmpty ? result.segments : []
            )
        } catch {
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor failed, falling back: \(error)")
            TranscriptCleanupDebugLogger.append(
                status: "fallback_error",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: postProcessorSnapshot.modelId,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                errorDescription: String(describing: error)
            )
            return nil
        }
    }

    private func postProcessDictationWithGemma4(
        _ result: SpeechTranscriptionResult,
        backend: BackendOption,
        postProcessorSnapshot: PostProcessorSnapshot,
        appContext: String?
    ) async -> SpeechTranscriptionResult? {
        guard #available(macOS 15, *) else {
            Gemma4LiteRTLogging.log("Gemma cleanup skipped: requires macOS 15+")
            return nil
        }
        do {
            let model = Gemma4LiteRTModel.resolved(postProcessorSnapshot.modelId)
            let cleanup: (text: String, rawOutput: String, processingTime: Double, didFallback: Bool)
            if GemmaNativeAudioPolicy.isEnabled(for: model) {
                cleanup = try await nativeGemma(for: model).cleanTranscript(result.text,
                    systemPrompt: postProcessorSnapshot.systemPrompt, appContext: appContext, model: model)
            } else {
                cleanup = try await gemma4LiteRTTranscriber.cleanTranscript(result.text,
                    systemPrompt: postProcessorSnapshot.systemPrompt, appContext: appContext, model: model)
            }
            let elapsedMs = cleanup.processingTime * 1000
            let trimmed = cleanup.text.trimmingCharacters(in: .whitespacesAndNewlines)
            Qwen3PostProcessorLogging.logVerbose(
                "Gemma 4 post-processor applied to \(backend.label) in \(String(format: "%.1f", elapsedMs))ms " +
                    "(chars=\(trimmed.count))"
            )
            logPostProcPair(
                raw: result.text,
                processed: trimmed,
                model: postProcessorSnapshot.modelId,
                asr: backend.backend
            )
            TranscriptCleanupDebugLogger.append(
                status: cleanup.didFallback ? "fallback_original_transcript" : "applied",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: postProcessorSnapshot.modelId,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                rawCleanupOutputText: cleanup.rawOutput,
                cleanupOutputText: trimmed,
                elapsedMs: elapsedMs
            )
            return SpeechTranscriptionResult(
                text: trimmed,
                segments: Qwen3PostProcessorLogging.isVerboseEnabled && !trimmed.isEmpty ? result.segments : []
            )
        } catch {
            Gemma4LiteRTLogging.log("Gemma cleanup failed, falling back: \(error)")
            TranscriptCleanupDebugLogger.append(
                status: "fallback_error",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: postProcessorSnapshot.modelId,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                errorDescription: String(describing: error)
            )
            return nil
        }
    }

    private func postProcessDictationWithHostedBackend(
        _ result: SpeechTranscriptionResult,
        backend: BackendOption,
        postProcessorSnapshot: PostProcessorSnapshot,
        appContext: String?
    ) async -> SpeechTranscriptionResult? {
        do {
            let start = CFAbsoluteTimeGetCurrent()
            let cleanup = try await TranscriptCleanupClient.clean(
                text: result.text,
                systemPrompt: postProcessorSnapshot.systemPrompt,
                appContext: appContext,
                backend: postProcessorSnapshot.backend,
                config: postProcessorSnapshot.config
            )
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let trimmed = cleanup.cleanedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, !Qwen3DeletionCueDetector.containsDeletionCue(result.text) {
                Qwen3PostProcessorLogging.logVerbose("\(postProcessorSnapshot.backend.label) post-processor returned empty output in \(String(format: "%.1f", elapsedMs))ms; falling back")
                TranscriptCleanupDebugLogger.append(
                    status: "fallback_empty_output",
                    cleanupBackend: postProcessorSnapshot.backend,
                    cleanupModel: cleanup.model,
                    asrBackend: backend.backend,
                    appContextText: appContext,
                    rawASRText: result.text,
                    rawCleanupOutputText: cleanup.rawOutput,
                    cleanupOutputText: trimmed,
                    elapsedMs: elapsedMs
                )
                return nil
            }
            Qwen3PostProcessorLogging.logVerbose("\(postProcessorSnapshot.backend.label) post-processor applied to \(backend.label) in \(String(format: "%.1f", elapsedMs))ms (chars=\(trimmed.count))")
            logPostProcPair(raw: result.text, processed: trimmed, model: cleanup.model, asr: backend.backend)
            TranscriptCleanupDebugLogger.append(
                status: "applied",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: cleanup.model,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                rawCleanupOutputText: cleanup.rawOutput,
                cleanupOutputText: trimmed,
                elapsedMs: elapsedMs
            )
            return SpeechTranscriptionResult(
                text: trimmed,
                segments: Qwen3PostProcessorLogging.isVerboseEnabled && !trimmed.isEmpty ? result.segments : []
            )
        } catch TranscriptCleanupError.rejectedOutput {
            Qwen3PostProcessorLogging.logVerbose("\(postProcessorSnapshot.backend.label) post-processor output rejected, falling back")
            TranscriptCleanupDebugLogger.append(
                status: "fallback_rejected_output",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: postProcessorSnapshot.modelId,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                errorDescription: TranscriptCleanupError.rejectedOutput.localizedDescription
            )
            return nil
        } catch {
            Qwen3PostProcessorLogging.logVerbose("\(postProcessorSnapshot.backend.label) post-processor failed, falling back: \(error)")
            TranscriptCleanupDebugLogger.append(
                status: "fallback_error",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: postProcessorSnapshot.modelId,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                errorDescription: String(describing: error)
            )
            return nil
        }
    }

    private func applyCustomWords(_ result: SpeechTranscriptionResult, customWords: [[String: Any]]) -> SpeechTranscriptionResult {
        guard !customWords.isEmpty, !result.text.isEmpty else { return result }
        let entries = customWords.compactMap { dict -> CustomWord? in
            guard let word = dict["word"] as? String else { return nil }
            let threshold = dict["matchingThreshold"] as? Double ?? 0.85
            return CustomWord(word: word, replacement: dict["replacement"] as? String, matchingThreshold: threshold)
        }
        guard !entries.isEmpty else { return result }
        let correctedText = CustomWordMatcher.apply(text: result.text, customWords: entries)
        return SpeechTranscriptionResult(text: correctedText, segments: result.segments)
    }

    private func route(
        url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        bodhanLanguage: BodhanLanguage,
        bodhanOutputMode: BodhanOutputMode,
        whisperLanguage: WhisperKitLanguage,
        qwen3AsrLanguage: Qwen3AsrLanguage,
        parakeetLanguage: ParakeetLanguage,
        appleSpeechLanguage: String
    ) async throws -> SpeechTranscriptionResult {
        switch backend.backend {
        case "whisper":
            let language = backend.supportsWhisperLanguageSelection
                ? whisperLanguage
                : WhisperKitLanguage.defaultLanguage
            return try await transcribeWithWhisperKit(url: url, language: language, expectedModel: backend.model)
        case "nemotron35":
            return try await transcribeWithNemotron35(url: url)
        case "parakeet-unified":
            return try await transcribeWithParakeetUnified(url: url)
        case "qwen":
            return try await transcribeWithQwen3(url: url, language: qwen3AsrLanguage)
        case "medasr":
            let result = try await medASRTranscriber.transcribe(wavURL: url)
            return SpeechTranscriptionResult(text: result.text, segments: [])
        case "cohere":
            return try await transcribeWithCohere(url: url, language: cohereLanguage)
        case "bodhan":
            return try await transcribeWithBodhan(url: url, modelID: backend.model, language: bodhanLanguage, outputMode: bodhanOutputMode)
        case "sensevoice":
            return try await transcribeWithSenseVoice(url: url)
        case "gemma4-litert":
            return try await transcribeWithGemma4LiteRT(url: url, model: Gemma4LiteRTModel.resolved(backend.model))
        case "apple-speech":
            if #available(macOS 26.0, *) {
                return try await transcribeWithAppleSpeech(
                    url: url,
                    languageIdentifier: appleSpeechLanguage
                )
            }
            throw AppleSpeechAnalyzerError.unavailable
        default:
            return try await transcribeWithFluidAudio(url: url, language: parakeetLanguage,
                expectedModelID: backend.model)
        }
    }

    // MARK: - FluidAudio (Parakeet on ANE)

    private func transcribeWithFluidAudio(url: URL, language: ParakeetLanguage, expectedModelID: String) async throws -> SpeechTranscriptionResult {
        fputs("[muesli-native] transcribing with FluidAudio: \(url.lastPathComponent)\n", stderr)
        let result = try await fluidTranscriber.transcribe(wavURL: url, language: language.isoCode, expectedModelID: expectedModelID)
        fputs("[muesli-native] FluidAudio result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = (result.tokenTimings ?? []).map { timing in
            SpeechSegment(start: timing.startTime, end: timing.endTime, text: timing.token)
        }
        return SpeechTranscriptionResult(
            text: text,
            segments: segments.isEmpty && !text.isEmpty ? [SpeechSegment(start: 0, end: result.duration, text: text)] : segments
        )
    }

    // MARK: - Parakeet Unified (FastConformer-RNNT offline batch)

    private func transcribeWithParakeetUnified(url: URL) async throws -> SpeechTranscriptionResult {
        fputs("[muesli-native] transcribing with Parakeet Unified: \(url.lastPathComponent)\n", stderr)
        let result = try await parakeetUnifiedTranscriber.transcribe(wavURL: url)
        fputs("[muesli-native] Parakeet Unified result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpeechTranscriptionResult(
            text: text,
            segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
        )
    }

    // MARK: - WhisperKit (Whisper on ANE/GPU via CoreML)

    private func transcribeWithWhisperKit(
        url: URL,
        language: WhisperKitLanguage,
        expectedModel: String
    ) async throws -> SpeechTranscriptionResult {
        fputs("[muesli-native] transcribing with WhisperKit: \(url.lastPathComponent)\n", stderr)
        let result = try await whisperTranscriber.transcribe(wavURL: url, language: language, expectedModel: expectedModel)
        fputs("[muesli-native] WhisperKit result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpeechTranscriptionResult(
            text: text,
            segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
        )
    }

    // MARK: - Qwen3 ASR (Autoregressive CoreML on ANE)

    private func transcribeWithQwen3(url: URL, language: Qwen3AsrLanguage) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[muesli-native] transcribing with Qwen3 ASR: \(url.lastPathComponent)\n", stderr)
            let result = try await qwen3Transcriber.transcribe(wavURL: url, language: language.pinnedCode)
            fputs("[muesli-native] Qwen3 ASR result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Qwen3 ASR requires macOS 15 or later.",
            ])
        }
    }

    func unloadMedASRTranscriber() async {
        await medASRTranscriber.shutdown()
    }

    // MARK: - SenseVoiceSmall (FunASR via FluidAudio/CoreML)

    private func transcribeWithSenseVoice(url: URL) async throws -> SpeechTranscriptionResult {
        fputs("[muesli-native] transcribing with SenseVoice: \(url.lastPathComponent)\n", stderr)
        let result = try await senseVoiceTranscriber.transcribe(wavURL: url)
        fputs("[muesli-native] SenseVoice result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpeechTranscriptionResult(
            text: text,
            // FluidAudio's SenseVoice API returns plain text only, so timestamped segments are not available here.
            segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
        )
    }

    // MARK: - Gemma 4 (LiteRT-LM multimodal)

    private func transcribeWithGemma4LiteRT(
        url: URL,
        model: Gemma4LiteRTModel
    ) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            Gemma4LiteRTLogging.log("transcribing \(url.lastPathComponent)")
            let result: (text: String, processingTime: Double)
            if GemmaNativeAudioPolicy.isEnabled(for: model) {
                let native = try await nativeGemma(for: model).transcribe(wavURL: url, model: model)
                result = (native.text, native.processingTime)
            } else {
                result = try await gemma4LiteRTTranscriber.transcribe(wavURL: url, model: model)
            }
            Gemma4LiteRTLogging.log("result chars=\(result.text.count), processingTime=\(String(format: "%.3f", result.processingTime))s")
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "MuesliTranscriptionRuntime", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "\(model.label) requires macOS 15 or later.",
            ])
        }
    }

    // MARK: - Cohere Transcribe (CoreML)

    private func transcribeWithCohere(
        url: URL,
        language: CohereTranscribeLanguage
    ) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[muesli-native] transcribing with Cohere Transcribe: \(url.lastPathComponent)\n", stderr)
            let result = try await cohereTranscriber.transcribe(wavURL: url, language: language)
            fputs("[muesli-native] Cohere Transcribe result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cohere Transcribe requires macOS 15 or later.",
            ])
        }
    }

    // MARK: - Bodhan Core/Flex (CoreML encoder, CoreML or MLX decoder)

    private func transcribeWithBodhan(
        url: URL,
        modelID: String,
        language: BodhanLanguage,
        outputMode: BodhanOutputMode
    ) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            BodhanLogging.logVerbose("transcribing with Bodhan (\(language.rawValue)): \(url.lastPathComponent)")
            let result = try await bodhanTranscriber.transcribe(wavURL: url, modelID: modelID, language: language, outputMode: outputMode)
            BodhanLogging.logVerbose("Bodhan result chars=\(result.text.count), processingTime=\(String(format: "%.3f", result.processingTime))s")
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let canMeasureSwitches = outputMode.supportsWordsBeforeCodeSwitch(modelID: modelID)
            let measurement = BodhanWBCSMeasurement(
                languageSamples: result.languageSamples,
                runLengths: canMeasureSwitches ? WordsBeforeCodeSwitch.bodhanMixedRunLengths(in: text) : nil
            )
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)],
                bodhanMeasurement: measurement
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Bodhan requires macOS 15 or later.",
            ])
        }
    }

    // MARK: - Nemotron 3.5 Streaming (RNNT CoreML on ANE)

    private func transcribeWithNemotron35(url: URL) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[muesli-native] transcribing with Nemotron 3.5: \(url.lastPathComponent)\n", stderr)
            let transcriber = try await getLoadedNemotron35Transcriber()
            let result = try await transcriber.transcribe(wavURL: url)
            fputs("[muesli-native] Nemotron 3.5 result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Nemotron 3.5 requires macOS 15 or later.",
            ])
        }
    }

}
