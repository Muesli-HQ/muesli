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
}

actor TranscriptionCoordinator {
    private let fluidTranscriber = FluidAudioTranscriber()
    private let whisperTranscriber = WhisperKitTranscriber()
    private var _nemotronTranscriber: Any?
    private var _qwen3Transcriber: Any?
    private var _qwen3PostProcessor: Any?
    private var _canaryQwenTranscriber: Any?
    private var _cohereTranscriber: Any?
    private var vadManager: VadManager?
    private var diarizerManager: DiarizerManager?
    private var activeBackend: String?

    @available(macOS 15, *)
    private var nemotronTranscriber: NemotronStreamingTranscriber {
        if _nemotronTranscriber == nil {
            _nemotronTranscriber = NemotronStreamingTranscriber()
        }
        return _nemotronTranscriber as! NemotronStreamingTranscriber
    }

    /// Public accessor for streaming dictation — triggers lazy init if needed.
    @available(macOS 15, *)
    func getNemotronTranscriber() -> NemotronStreamingTranscriber {
        return nemotronTranscriber
    }

    @available(macOS 15, *)
    private var qwen3Transcriber: Qwen3AsrTranscriber {
        if _qwen3Transcriber == nil {
            _qwen3Transcriber = Qwen3AsrTranscriber()
        }
        return _qwen3Transcriber as! Qwen3AsrTranscriber
    }

    @available(macOS 15, *)
    private var canaryQwenTranscriber: CanaryQwenTranscriber {
        if _canaryQwenTranscriber == nil {
            _canaryQwenTranscriber = CanaryQwenTranscriber()
        }
        return _canaryQwenTranscriber as! CanaryQwenTranscriber
    }

    private var postProcessorModelURL: URL = PostProcessorOption.defaultOption.modelURL
    private var postProcessorSystemPrompt: String = PostProcessorOption.defaultSystemPrompt
    private var postProcessorModelId: String = PostProcessorOption.defaultOption.id

    @available(macOS 15, *)
    private var qwen3PostProcessor: Qwen3PostProcessor {
        if _qwen3PostProcessor == nil {
            _qwen3PostProcessor = Qwen3PostProcessor(
                modelURL: postProcessorModelURL,
                systemPrompt: postProcessorSystemPrompt
            )
        }
        return _qwen3PostProcessor as! Qwen3PostProcessor
    }

    @available(macOS 15, *)
    func setActivePostProcessor(option: PostProcessorOption, systemPrompt: String) async {
        postProcessorModelURL = option.modelURL
        postProcessorSystemPrompt = systemPrompt
        postProcessorModelId = option.id
        if let existing = _qwen3PostProcessor as? Qwen3PostProcessor {
            await existing.reconfigure(modelURL: option.modelURL, systemPrompt: systemPrompt)
        }
    }

    private struct PostProcPairLogEntry: Encodable {
        let ts: String
        let raw: String
        let processed: String
        let model: String
        let asr: String
    }

    private func logPostProcPair(raw: String, processed: String, asr: String) {
        guard Qwen3PostProcessorLogging.isPairLoggingEnabled else { return }
        let logURL = AppIdentity.supportDirectoryURL.appendingPathComponent("postproc-pairs.jsonl")
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso8601.string(from: Date())
        let entry = PostProcPairLogEntry(
            ts: ts,
            raw: raw,
            processed: processed,
            model: postProcessorModelId,
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

    func preload(
        backend: BackendOption,
        enablePostProcessor: Bool = false,
        includeMeetingHelpers: Bool = true,
        progress: ((Double, String?) -> Void)? = nil
    ) async {
        do {
            try await preloadRequired(
                backend: backend,
                enablePostProcessor: enablePostProcessor,
                includeMeetingHelpers: includeMeetingHelpers,
                progress: progress
            )
        } catch {
            fputs("[muesli-native] preload failed for \(backend.backend)/\(backend.model): \(error)\n", stderr)
        }
    }

    func preloadRequired(
        backend: BackendOption,
        enablePostProcessor: Bool = false,
        includeMeetingHelpers: Bool = true,
        progress: ((Double, String?) -> Void)? = nil
    ) async throws {
        activeBackend = backend.backend

        if includeMeetingHelpers {
            // Meeting helpers are intentionally loaded only when the caller needs meeting behavior.
            if vadManager == nil {
                do {
                    vadManager = try await VadManager()
                    fputs("[muesli-native] Silero VAD loaded\n", stderr)
                } catch {
                    fputs("[muesli-native] VAD load failed (non-critical): \(error)\n", stderr)
                }
            }

            if diarizerManager == nil {
                do {
                    let diarizer = DiarizerManager()
                    let models = try await DiarizerModels.download()
                    diarizer.initialize(models: models)
                    diarizerManager = diarizer
                    fputs("[muesli-native] Speaker diarization loaded\n", stderr)
                } catch {
                    fputs("[muesli-native] Diarization load failed (non-critical): \(error)\n", stderr)
                }
            }
        }

        switch backend.backend {
        case "fluidaudio":
            let version: AsrModelVersion = backend.model.contains("v2") ? .v2 : .v3
            try await fluidTranscriber.loadModels(version: version, progress: progress)
        case "whisper":
            try await whisperTranscriber.loadModel(modelName: backend.model, progress: progress)
            // Warmup ANE/GPU so first dictation doesn't pay CoreML compilation cost
            fputs("[muesli-native] WhisperKit warmup: running silent audio for CoreML compilation...\n", stderr)
            progress?(0.9, "Warming up model...")
            try await whisperTranscriber.warmup()
            fputs("[muesli-native] WhisperKit warmup complete\n", stderr)
            progress?(1.0, nil)
        case "nemotron":
            if #available(macOS 15, *) {
                try await nemotronTranscriber.loadModels(progress: progress)
                // Warmup ANE so first dictation starts instantly
                fputs("[muesli-native] Nemotron warmup: running silent chunk for ANE compilation...\n", stderr)
                var state = try await nemotronTranscriber.makeStreamState()
                let silence = [Float](repeating: 0, count: 8960)
                _ = try? await nemotronTranscriber.transcribeChunk(samples: silence, state: &state)
                fputs("[muesli-native] Nemotron warmup complete\n", stderr)
            } else {
                throw NSError(domain: "MuesliTranscriptionRuntime", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Nemotron requires macOS 15 or later.",
                ])
            }
        case "qwen":
            if #available(macOS 15, *) {
                try await qwen3Transcriber.loadModels(progress: progress)
            } else {
                throw NSError(domain: "MuesliTranscriptionRuntime", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Qwen3 ASR requires macOS 15 or later.",
                ])
            }
        case "canary":
            if #available(macOS 15, *) {
                try await canaryQwenTranscriber.prepare(progress: progress)
            } else {
                throw NSError(domain: "MuesliTranscriptionRuntime", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Canary Qwen requires macOS 15 or later.",
                ])
            }
        case "cohere":
            if #available(macOS 15, *) {
                try await cohereTranscriber.prepare(progress: progress)
            } else {
                throw NSError(domain: "MuesliTranscriptionRuntime", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Cohere Transcribe requires macOS 15 or later.",
                ])
            }
        default:
            throw NSError(domain: "MuesliTranscriptionRuntime", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Unknown transcription backend: \(backend.backend)",
            ])
        }

        await preloadPostProcessorIfNeeded(enabled: enablePostProcessor)
    }

    func preloadPostProcessorIfNeeded(enabled: Bool) async {
        if enabled, #available(macOS 15, *) {
            do {
                try await qwen3PostProcessor.prepare()
            } catch {
                Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor preload failed: \(error)")
            }
        }
    }

    func transcribeDictation(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage = CohereTranscribeLanguage.defaultLanguage,
        enablePostProcessor: Bool = false,
        customWords: [[String: Any]] = [],
        appContext: String? = nil
    ) async throws -> SpeechTranscriptionResult {
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
        var result = try await route(url: url, backend: backend, cohereLanguage: cohereLanguage)
        result = removeArtifacts(result)
        if !result.text.isEmpty {
            Qwen3PostProcessorLogging.logVerbose("Dictation raw transcript after artifact cleanup: \(result.text)")
        }
        result = await postProcessDictationIfNeeded(
            result,
            backend: backend,
            enabled: enablePostProcessor,
            appContext: appContext
        ) ?? removeFillersWithLogging(result)
        let final = applyCustomWords(result, customWords: customWords)
        if !final.text.isEmpty {
            Qwen3PostProcessorLogging.logVerbose("Dictation final transcript: \(final.text)")
        }
        return final
    }

    func transcribeMeeting(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage = CohereTranscribeLanguage.defaultLanguage
    ) async throws -> SpeechTranscriptionResult {
        // Meetings intentionally skip Qwen/custom-word post-processing. Keep deterministic artifact/filler cleanup only.
        cleanMeetingTranscript(try await route(url: url, backend: backend, cohereLanguage: cohereLanguage))
    }

    func transcribeMeetingChunk(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage = CohereTranscribeLanguage.defaultLanguage
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
        return cleanMeetingTranscript(try await route(url: url, backend: backend, cohereLanguage: cohereLanguage))
    }

    func diarizeSystemAudio(at url: URL) async throws -> DiarizationResult? {
        guard let diarizerManager, diarizerManager.isAvailable else {
            fputs("[muesli-native] diarization not available, skipping\n", stderr)
            return nil
        }
        fputs("[muesli-native] running speaker diarization on system audio...\n", stderr)
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(url)
        let result = try diarizerManager.performCompleteDiarization(samples, sampleRate: 16000)
        let speakerCount = Set(result.segments.map(\.speakerId)).count
        fputs("[muesli-native] diarization complete: \(result.segments.count) segments, \(speakerCount) speakers\n", stderr)
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
        await whisperTranscriber.shutdown()
        if #available(macOS 15, *) {
            await nemotronTranscriber.shutdown()
            await qwen3Transcriber.shutdown()
            if let postProcessor = _qwen3PostProcessor as? Qwen3PostProcessor {
                await postProcessor.shutdown()
            }
            await canaryQwenTranscriber.shutdown()
            await cohereTranscriber.shutdown()
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

    private func removeArtifacts(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        let filtered = TranscriptionEngineArtifactsFilter.apply(result.text)
        return SpeechTranscriptionResult(text: filtered, segments: filtered.isEmpty ? [] : result.segments)
    }

    private func postProcessDictationIfNeeded(
        _ result: SpeechTranscriptionResult,
        backend: BackendOption,
        enabled: Bool,
        appContext: String? = nil
    ) async -> SpeechTranscriptionResult? {
        guard enabled else {
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor disabled for dictation")
            return nil
        }
        guard !result.text.isEmpty else {
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor skipped: empty transcript")
            return nil
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
            let processed = try await qwen3PostProcessor.process(result.text, appContext: appContext)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, !Qwen3DeletionCueDetector.containsDeletionCue(result.text) {
                Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor returned empty output in \(String(format: "%.1f", elapsedMs))ms; falling back")
                return nil
            }
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor applied to \(backend.label) in \(String(format: "%.1f", elapsedMs))ms (chars=\(trimmed.count))")
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor final output: \(trimmed)")
            logPostProcPair(raw: result.text, processed: trimmed, asr: backend.backend)
            return SpeechTranscriptionResult(
                text: trimmed,
                // Original ASR segments describe pre-cleanup text. Keep them only for debug diagnostics.
                segments: Qwen3PostProcessorLogging.isVerboseEnabled && !trimmed.isEmpty ? result.segments : []
            )
        } catch {
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor failed, falling back: \(error)")
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
        cohereLanguage: CohereTranscribeLanguage
    ) async throws -> SpeechTranscriptionResult {
        switch backend.backend {
        case "whisper":
            return try await transcribeWithWhisperKit(url: url)
        case "nemotron":
            return try await transcribeWithNemotron(url: url)
        case "qwen":
            return try await transcribeWithQwen3(url: url)
        case "canary":
            return try await transcribeWithCanaryQwen(url: url)
        case "cohere":
            return try await transcribeWithCohere(url: url, language: cohereLanguage)
        default:
            return try await transcribeWithFluidAudio(url: url)
        }
    }

    // MARK: - FluidAudio (Parakeet on ANE)

    private func transcribeWithFluidAudio(url: URL) async throws -> SpeechTranscriptionResult {
        fputs("[muesli-native] transcribing with FluidAudio: \(url.lastPathComponent)\n", stderr)
        let result = try await fluidTranscriber.transcribe(wavURL: url)
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

    // MARK: - WhisperKit (Whisper on ANE/GPU via CoreML)

    private func transcribeWithWhisperKit(url: URL) async throws -> SpeechTranscriptionResult {
        fputs("[muesli-native] transcribing with WhisperKit: \(url.lastPathComponent)\n", stderr)
        let result = try await whisperTranscriber.transcribe(wavURL: url)
        fputs("[muesli-native] WhisperKit result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpeechTranscriptionResult(
            text: text,
            segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
        )
    }

    // MARK: - Qwen3 ASR (Autoregressive CoreML on ANE)

    private func transcribeWithQwen3(url: URL) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[muesli-native] transcribing with Qwen3 ASR: \(url.lastPathComponent)\n", stderr)
            let result = try await qwen3Transcriber.transcribe(wavURL: url)
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

    private func transcribeWithCanaryQwen(url: URL) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[muesli-native] transcribing with Canary Qwen: \(url.lastPathComponent)\n", stderr)
            let result = try await canaryQwenTranscriber.transcribe(wavURL: url)
            fputs("[muesli-native] Canary Qwen result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            CanaryProfilingLog.write("[muesli-native] Canary Qwen profile: \(result.profile.logDescription(prefix: "profile"))")
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Canary Qwen requires macOS 15 or later.",
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

    // MARK: - Nemotron Streaming (RNNT CoreML on ANE)

    private func transcribeWithNemotron(url: URL) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[muesli-native] transcribing with Nemotron: \(url.lastPathComponent)\n", stderr)
            let result = try await nemotronTranscriber.transcribe(wavURL: url)
            fputs("[muesli-native] Nemotron result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Nemotron requires macOS 15 or later.",
            ])
        }
    }

}
