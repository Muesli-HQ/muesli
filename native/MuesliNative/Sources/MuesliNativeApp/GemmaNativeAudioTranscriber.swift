import MLXGuidedGeneration
import Foundation
import MuesliCore
import MLX
import MLXNN
import MLXVLM
import MLXLLM
import MLXLMCommon
import FluidAudio
import GemmaAudioEvaluation

enum GemmaNativeAudioError: Error, LocalizedError {
    case invalidResponse
    case modelMissing(path: String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Gemma could not produce a complete transcription. Please try again."
        case .modelMissing(let path): return "The verified native Gemma model files are missing at \(path)."
        }
    }
}

/// Native MLX routing. Saved model selections and prompts remain unchanged.
enum GemmaNativeAudioPolicy {
    static func isEnabled(for model: Gemma4LiteRTModel, bundle: Bundle = .main) -> Bool {
        true
    }

    static func isDigitalSilence(_ samples: [Float]) throws -> Bool {
        guard samples.allSatisfy(\.isFinite) else { throw GemmaAudioError.invalid("Nonfinite audio samples") }
        // Only digital silence / sub-quantization noise; do not use an amplitude
        // threshold as a substitute for speech detection on quiet microphones.
        return samples.allSatisfy { abs($0) <= 0.0000001 }
    }

    @available(macOS 15, *)
    static func validatedOutput(_ raw: String, completed: Bool) throws -> String {
        guard completed, !raw.contains("<|"), !raw.contains("<turn|>"), !raw.contains("<channel|>"), !raw.contains("<eos>") else {
            throw GemmaNativeAudioError.invalidResponse
        }
        let text = Gemma4LiteRTTranscriber.cleanTranscript(raw)
        guard !Gemma4LiteRTTranscriber.looksLikePromptLeak(text),
              !Gemma4LiteRTTranscriber.looksLikeAssistantResponse(text) else { throw GemmaNativeAudioError.invalidResponse }
        return text
    }
}

@available(macOS 15, *)
actor GemmaNativeAudioTranscriber {
    private static let e2bEngine = GemmaNativeAudioTranscriber()
    private static let e4bEngine = GemmaNativeAudioTranscriber()
    private static let cleanupEngine = GemmaNativeAudioTranscriber()
    static func shared(for model: Gemma4LiteRTModel) -> GemmaNativeAudioTranscriber {
        switch model { case .e2b: e2bEngine; case .e4b: e4bEngine; case .muesliCleanupV2: cleanupEngine }
    }

    struct Result: Sendable, Codable {
        let text: String
        let processingTime: Double
        let frontendSeconds: Double
        let encoderSeconds: Double
        let prefillSeconds: Double
        let decodeSeconds: Double
        let vadSeconds: Double
        let skippedSilence: Bool
        var mtpBlock: Int = 1
        var proposedDraftTokens: Int? = nil
        var acceptedDraftTokens: Int? = nil
        var passthroughReason: String? = nil
    }
    private struct Loaded {
        let model: Gemma4LiteRTModel
        let context: ModelContext
        let encoder: GemmaAudioEncoder?
        let frontend: GemmaAudioFeatures
        let audioTokenID: Int?
    }
    private var loaded: Loaded?
    private var warmedAudio = false
    private var warmedText = false
    private var vad: VadManager?
    private var drafter: (model: Gemma4LiteRTModel, value: any MTPDrafterModel)?
    // An environment override keeps paired developer benchmarks independent of saved settings.
    private let mtpBlock: Int
    init(mtpBlock: Int? = nil) {
        self.mtpBlock = mtpBlock ?? GemmaMTPPolicy.blockSize()
    }
    private func loadDrafter(model: Gemma4LiteRTModel) async throws {
        if drafter?.model == model { return }
        drafter = nil
        let artifact = GemmaNativeAudioModels.drafter(for: model)
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/muesli/models/mlx-evaluation/" + artifact.revision)
        try artifact.validate(modelURL: directory.appendingPathComponent(artifact.modelFilename))
        let config = try JSONDecoder().decode(Gemma4AssistantConfiguration.self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        let draft = Gemma4AssistantDraftModel(config)
        try await loadWeights(modelDirectory: directory, model: draft)
        drafter = (model, draft)
    }
    // Serialize across suspension points: model switches, shutdown and generation
    // must not share mutable MLX state while generation is consuming its cache.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
    func shutdown() async {
        await acquire(); defer { release() }
        loaded = nil
        warmedAudio = false; warmedText = false
        drafter = nil
        vad = nil
    }
    func prepare(model: Gemma4LiteRTModel) async throws {
        await acquire(); defer { release() }
        try Task.checkCancellation()
        try await prepareLocked(model: model)
    }
    /// Bounded kernel warm-up; synthetic input is never logged as user audio or pasted.
    func prepareForInteraction(model: Gemma4LiteRTModel, audio: Bool, text: Bool) async throws {
        await acquire(); defer { release() }
        try Task.checkCancellation()
        try await prepareLocked(model: model)
        let state = loaded!
        let start = Date()
        var didWork = false
        if audio && !warmedAudio {
            guard let encoder = state.encoder, let tokenID = state.audioTokenID else { throw GemmaNativeAudioError.invalidResponse }
            let features = try state.frontend.extract(samples: [Float](repeating: 0, count: 16000), sampleRate: 16000)
            let trace = try encoder.encode(features, retainTrace: false)
            let encoded = trace["encoder"]!, mask = trace["encoder_mask"]!
            eval(encoded, mask)
            let count = mask.asType(.int32).sum().item(Int.self)
            let prompt = Self.framed(system: nil, user: Gemma4LiteRTModelStore.resolvedPrompt() + "<|audio>" + String(repeating: "<|audio|>", count: count) + "<audio|>")
            let ids = state.context.tokenizer.encode(text: prompt, addSpecialTokens: false)
            guard ids.filter({ $0 == tokenID }).count == count else { throw GemmaNativeAudioError.invalidResponse }
            _ = try await generateRaw(input: LMInput(text: .init(tokens: MLXArray(ids).reshaped(1, -1)), audio: .init(features: encoded, mask: mask.reshaped(1, -1))), model: model, context: state.context, block: mtpBlock, maxTokens: 4)
            warmedAudio = true; didWork = true
        }
        if text && !warmedText {
            let prompt = model.isCleanupOnly
                ? CleanupMLXEvaluation.Model.gemma.prompt("The model is ready.", context: nil)
                : Self.framed(system: QuilTransformationPrompt.system, user: QuilTransformationPrompt.userPrompt(selectedText: "The model is ready.", instruction: "Convert to uppercase."))
            let ids = state.context.tokenizer.encode(text: prompt, addSpecialTokens: false)
            _ = try await generateRaw(input: LMInput(tokens: MLXArray(ids)), model: model, context: state.context, block: mtpBlock, maxTokens: 4)
            warmedText = true; didWork = true
        }
        try Task.checkCancellation()
        if didWork { log("interaction_ready model=\(model.label) audio=\(warmedAudio) text=\(warmedText) warmup_seconds=\(Date().timeIntervalSince(start))") }
    }

    private func prepareLocked(model: Gemma4LiteRTModel) async throws {
        if loaded?.model == model { return }
        // Release the old model before materializing the other multi-GB checkpoint.
        loaded = nil
        warmedAudio = false; warmedText = false
        drafter = nil
        let start = Date()
        let descriptor = GemmaNativeAudioModels.descriptor(for: model)
        let directory = GemmaNativeAudioModels.directory(for: model)
        guard descriptor.isPresent(at: directory) else { throw GemmaNativeAudioError.modelMissing(path: directory.path) }
        try descriptor.validate(modelURL: directory.appendingPathComponent(descriptor.modelFilename))
        try Task.checkCancellation()
        if !model.isCleanupOnly, vad == nil { vad = try await VadManager() }
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let audioConfig: GemmaAudioEncoder.Configuration? = try model.isCleanupOnly ? nil : JSONDecoder().decode(GemmaAudioEncoder.Configuration.self,
            from: JSONSerialization.data(withJSONObject: object["audio_config"]!))
        object.removeValue(forKey: "vision_config")
        if model.isCleanupOnly { object.removeValue(forKey: "audio_config") }
        let config = try JSONDecoder().decode(Gemma4UnifiedConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object))
        let backbone = Gemma4Unified(config)
        let baseConfig = try JSONDecoder().decode(BaseConfiguration.self, from: data)
        var weights = try MLX.loadArrays(url: directory.appendingPathComponent("model.safetensors"))
        let tower = weights.filter { $0.key.hasPrefix("audio_tower.") }
        let encoder = try audioConfig.map { try GemmaAudioEncoder(config: $0, weights: tower) }
        eval(Array(tower.values))
        weights = backbone.sanitize(weights: weights.filter { !$0.key.hasPrefix("audio_tower.") && !$0.key.hasPrefix("vision_tower.") })
        quantize(model: backbone) { path, _ in
            weights[path + ".scales"] == nil ? nil : baseConfig.perLayerQuantization?.quantization(layer: path)?.asTuple
        }
        try backbone.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        try backbone.prepare()
        eval(backbone)
        weights.removeAll()
        let tokenizer = try await CleanupHFTokenizerLoader().load(from: directory)
        try Task.checkCancellation()
        var modelConfig = ModelConfiguration(directory: directory)
        modelConfig.extraEOSTokens.formUnion(["<turn|>", "<eos>"])
        let context = ModelContext(configuration: modelConfig, model: backbone, processor: StandInUserInputProcessor(), tokenizer: tokenizer)
        loaded = Loaded(model: model, context: context, encoder: encoder, frontend: try GemmaAudioFeatures(), audioTokenID: config.audioTokenId)
        if mtpBlock > 1 { try await loadDrafter(model: model) }
        log("engine_ready model=\(model.label) runtime=mlx-swift-lm mtp=\(mtpBlock > 1) block=\(mtpBlock) load_seconds=\(Date().timeIntervalSince(start))")
    }
    func transcribe(wavURL: URL, model: Gemma4LiteRTModel, mtpBlockOverride: Int? = nil, systemPrompt: String? = nil, userPrompt: String? = nil, maxOutputTokens: Int = Int(Gemma4LiteRTTranscriber.maxOutputTokens)) async throws -> Result {
        await acquire(); defer { release() }
        try Task.checkCancellation()
        let start = Date()
        let wav = try WavReader.readFloatMonoWAV(from: wavURL)
        guard wav.sampleRate == 16000, wav.samples.count <= 480000 else {
            throw GemmaAudioError.invalid("Native Gemma expects 16 kHz mono audio up to 30 seconds")
        }
        func empty(_ vadSeconds: Double) -> Result {
            Result(text: "", processingTime: Date().timeIntervalSince(start), frontendSeconds: 0, encoderSeconds: 0,
                   prefillSeconds: 0, decodeSeconds: 0, vadSeconds: vadSeconds, skippedSilence: true)
        }
        if try GemmaNativeAudioPolicy.isDigitalSilence(wav.samples) {
            log("silence_skipped model=\(model.label) reason=digital_silence")
            return empty(0)
        }
        // Run the already-used Silero detector even when meeting helpers have not
        // been loaded. A failed detector is an error, never permission to hallucinate.
        if vad == nil { vad = try await VadManager() }
        let vadStart = Date()
        let speech = try await vad!.process(wav.samples)
        let vadSeconds = Date().timeIntervalSince(vadStart)
        try Task.checkCancellation()
        guard speech.contains(where: { $0.probability > 0.5 }) else {
            log("silence_skipped model=\(model.label) reason=vad vad_seconds=\(vadSeconds)")
            return empty(vadSeconds)
        }
        try await prepareLocked(model: model)
        let state = loaded!
        guard let encoder = state.encoder, let audioTokenID = state.audioTokenID else { throw GemmaNativeAudioError.invalidResponse }
        let frontendStart = Date()
        let features = try state.frontend.extract(samples: wav.samples, sampleRate: wav.sampleRate)
        eval(features.features)
        let frontendSeconds = Date().timeIntervalSince(frontendStart)
        let encoderStart = Date()
        let trace = try encoder.encode(features, retainTrace: false)
        let encoded = trace["encoder"]!, mask = trace["encoder_mask"]!
        eval(encoded, mask)
        let encoderSeconds = Date().timeIntervalSince(encoderStart)
        try Task.checkCancellation()
        let count = mask.asType(.int32).sum().item(Int.self)
        let prompt = Self.framed(system: systemPrompt, user: (userPrompt ?? Gemma4LiteRTModelStore.resolvedPrompt())
            + "<|audio>" + String(repeating: "<|audio|>", count: count) + "<audio|>")
        let ids = state.context.tokenizer.encode(text: prompt, addSpecialTokens: false)
        guard ids.filter({ $0 == audioTokenID }).count == count else { throw GemmaNativeAudioError.invalidResponse }
        let input = LMInput(text: .init(tokens: MLXArray(ids).reshaped(1, -1)), audio: .init(features: encoded, mask: mask.reshaped(1, -1)))
        let block = mtpBlockOverride ?? mtpBlock
        let (raw, info, tokenCount) = try await generateRaw(input: input, model: model, context: state.context, block: block, maxTokens: maxOutputTokens)
        let text: String
        do {
            if systemPrompt != nil {
                try Self.validateCompletion(raw, completed: info.stopReason == .stop)
                text = try QuilTransformationOutput.validated(raw)
            } else { text = try GemmaNativeAudioPolicy.validatedOutput(raw, completed: info.stopReason == .stop) }
        }
        catch {
            log("output_rejected model=\(model.label) stop=\(info.stopReason) tokens=\(tokenCount)")
            throw error
        }
        var result = Result(text: text, processingTime: Date().timeIntervalSince(start), frontendSeconds: frontendSeconds,
                            encoderSeconds: encoderSeconds, prefillSeconds: info.promptTime, decodeSeconds: info.generateTime,
                            vadSeconds: vadSeconds, skippedSilence: false)
        result.mtpBlock = block
        result.proposedDraftTokens = info.proposedDraftTokens
        result.acceptedDraftTokens = info.acceptedDraftTokens
        result.passthroughReason = info.passthroughReason
        log("transcription_completed model=\(model.label) total_seconds=\(result.processingTime) vad_seconds=\(vadSeconds) frontend_seconds=\(frontendSeconds) encoder_seconds=\(encoderSeconds) prefill_seconds=\(info.promptTime) decode_seconds=\(info.generateTime) tokens=\(tokenCount) mtp=\(block > 1) block=\(block) proposed=\(info.proposedDraftTokens ?? 0) accepted=\(info.acceptedDraftTokens ?? 0) fallback=\(info.passthroughReason ?? "none")")
        return result
    }
    static func framed(system: String?, user: String) -> String {
        "<bos>" + (system.map { "<|turn>system\n" + $0 + "<turn|>\n" } ?? "")
            + "<|turn>user\n" + user + "<turn|>\n<|turn>model\n"
    }
    static func validateCompletion(_ raw: String, completed: Bool) throws {
        guard completed, !raw.contains("<|"), !raw.contains("<turn|>"), !raw.contains("<channel|>"), !raw.contains("<eos>") else {
            throw GemmaNativeAudioError.invalidResponse
        }
    }
    private func generateRaw(input: LMInput, cache: [KVCache]? = nil, model: Gemma4LiteRTModel, context: ModelContext,
                             block: Int, maxTokens: Int) async throws -> (String, GenerateCompletionInfo, Int) {
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0, topK: 1, prefill: .init(stepSize: 2048, chunking: .remainder))
        let stream: AsyncStream<TokenGeneration>
        let generationTask: Task<Void, Never>?
        if block > 1 {
            try await loadDrafter(model: model)
            stream = try generateTokens(input: input, cache: cache, parameters: parameters, context: context, mtpDrafter: drafter!.value, blockSize: block)
            generationTask = nil
        } else {
            (stream, generationTask) = try generateTokensTask(input: input, cache: cache, parameters: parameters, context: context)
        }
        // A separate consumer is intentionally not canceled with its caller: the
        // pinned MTP API has no producer handle, so its bounded stream must finish
        // before shutdown/model switching can release the target and drafter.
        let consumer = Task {
            var tokens: [Int] = []
            var completion: GenerateCompletionInfo?
            for await event in stream {
                switch event {
                case .token(let token): tokens.append(token)
                case .info(let info): completion = info
                }
            }
            await generationTask?.value
            return (tokens, completion)
        }
        let (tokens, completion) = await withTaskCancellationHandler {
            await consumer.value
        } onCancel: { generationTask?.cancel() }
        try Task.checkCancellation()
        guard let info = completion else { throw GemmaNativeAudioError.invalidResponse }
        let raw = context.tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
        return (raw, info, tokens.count)

    }

    struct TextResult: Sendable, Codable {
        let raw: String
        let seconds: Double
        let completed: Bool
        let proposed: Int?
        let accepted: Int?
        let fallback: String?
    }
    func generatePrompt(_ prompt: String, model: Gemma4LiteRTModel, maxTokens: Int, mtpBlockOverride: Int? = nil) async throws -> TextResult {
        await acquire(); defer { release() }
        try Task.checkCancellation()
        try await prepareLocked(model: model)
        let context = loaded!.context
        let start = Date()
        let ids = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0, topK: 1)
        let cache = try context.model.newCache(parameters: parameters)
        // Preserve the evaluated text path's reference-style prefill and final-token reservation.
        var pos = 0
        while pos < ids.count - 1 {
            try Task.checkCancellation()
            let end = min(pos + 2048, ids.count - 1)
            _ = context.model(MLXArray(Array(ids[pos..<end])).reshaped(1, -1), cache: cache)
            eval(cache); pos = end
        }
        let prefillSeconds = Date().timeIntervalSince(start)
        let block = mtpBlockOverride ?? mtpBlock
        let (raw, info, count) = try await generateRaw(input: LMInput(tokens: MLXArray(Array(ids[pos...]))), cache: cache,
            model: model, context: context, block: block, maxTokens: maxTokens)
        let seconds = Date().timeIntervalSince(start)
        log("text_completed model=\(model.label) total_seconds=\(seconds) prefill_seconds=\(prefillSeconds + info.promptTime) decode_seconds=\(info.generateTime) tokens=\(count) mtp=\(block > 1) proposed=\(info.proposedDraftTokens ?? 0) accepted=\(info.acceptedDraftTokens ?? 0) fallback=\(info.passthroughReason ?? "none")")
        return TextResult(raw: raw, seconds: seconds, completed: info.stopReason == .stop,
            proposed: info.proposedDraftTokens, accepted: info.acceptedDraftTokens, fallback: info.passthroughReason)
    }
    func generateToolResponse(systemPrompt: String, userPrompt: String, model: Gemma4LiteRTModel, toolsJSON: String) async throws -> String {
        guard !model.isCleanupOnly else { throw GemmaToolCalling.invalid() }
        await acquire(); defer { release() }
        try Task.checkCancellation()
        try await prepareLocked(model: model)
        let context = loaded!.context
        let prompt = try GemmaToolCalling.prompt(system: systemPrompt, user: userPrompt, toolsJSON: toolsJSON)
        let ids = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
        try Gemma4LiteRTTranscriber.validatePlannerTokenBudget(ids.count)
        // Gemma has unused token IDs: do not stop at the first vocabulary gap.
        let configData = try Data(contentsOf: GemmaNativeAudioModels.directory(for: model).appendingPathComponent("config.json"))
        let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
        guard let textConfig = config?["text_config"] as? [String: Any], let size = textConfig["vocab_size"] as? Int,
              size > 0, size <= 500_000 else { throw GemmaToolCalling.invalid() }
        let vocabulary = (0..<size).map { context.tokenizer.convertIdToToken($0) ?? "" }
        let tokenizer = try GrammarTokenizer(vocab: vocabulary, vocabType: .byteFallback,
            eosTokenId: Int32(context.tokenizer.eosTokenId ?? 1))
        let grammar = try GemmaToolGrammar.make(toolsJSON: toolsJSON)
        // Hybrid mode replays forced spans through target verification; never splice
        // tokens into matcher state without the corresponding target-cache inputs.
        let toolMTP = mtpBlock > 1
        let constraint = try GrammarConstraint(tokenizer: tokenizer, grammar: grammar,
            fastForward: true, hostTokenizer: context.tokenizer)
        var raw = ""
        let start = Date()
        if toolMTP {
            try await loadDrafter(model: model)
            let processor = GemmaToolGrammarProcessor(constraint: constraint,
                vocabSize: size, eos: context.tokenizer.eosTokenId ?? 1)
            let hybridDrafter = GemmaGrammarDrafter(base: drafter!.value, processor: processor)
            var iterator = try MTPSpeculativeTokenIterator(
                input: LMInput(tokens: MLXArray(ids)), mainModel: context.model,
                drafter: hybridDrafter, parameters: GenerateParameters(maxTokens: 768, temperature: 0, topK: 1),
                blockSize: mtpBlock, components: GenerationComponents(logitProcessorFactory: { processor }))
            var output = [Int]()
            var ended = false
            while let token = iterator.next() {
                try Task.checkCancellation()
                if let failure = processor.failure { throw failure }
                if token == processor.eos { ended = true; break }
                output.append(token)
            }
            guard ended, processor.terminated else { throw GemmaToolCalling.invalid() }
            raw = context.tokenizer.decode(tokenIds: output, skipSpecialTokens: false)
            log("tool_mtp hybrid=true forced=\(processor.forcedCount) skipped_drafter_blocks=\(hybridDrafter.skippedBlocks) proposed=\(iterator.proposedCount) accepted=\(iterator.acceptedCount) prefill_seconds=\(iterator.promptPrefillTime) passthrough=\(iterator.passthroughReason ?? "none")")
        } else {
            try GuidedGenerationLoop.run(input: LMInput(tokens: MLXArray(ids)), context: context,
                constraint: constraint, maxTokens: 768, vocabSize: tokenizer.vocabSize) { delta in
                if Task.isCancelled { return false }
                raw += delta
                return true
            }
        }
        try Task.checkCancellation()
        if ProcessInfo.processInfo.environment["MUESLI_GEMMA_TOOL_TEST"] == "1" { print("MLX_TOOL_RAW model=\(model.label) output=\(raw)") }
        let response = try GemmaToolCalling.response(raw)
        log("tool_completed model=\(model.label) runtime=mlx-swift-lm constrained=true mtp=\(toolMTP) total_seconds=\(Date().timeIntervalSince(start))")
        return response
    }

    func generateText(systemPrompt: String, userPrompt: String, model: Gemma4LiteRTModel, maxOutputTokens: Int32) async throws -> String {
        guard !model.isCleanupOnly else { throw GemmaNativeAudioError.invalidResponse }
        let result = try await generatePrompt(Self.framed(system: systemPrompt, user: userPrompt), model: model, maxTokens: Int(maxOutputTokens))
        try Self.validateCompletion(result.raw, completed: result.completed)
        return result.raw
    }
    func generateFromAudio(wavURL: URL, systemPrompt: String, userPrompt: String, model: Gemma4LiteRTModel, maxOutputTokens: Int32) async throws -> String {
        guard !model.isCleanupOnly else { throw GemmaNativeAudioError.invalidResponse }
        let result = try await transcribe(wavURL: wavURL, model: model, systemPrompt: systemPrompt, userPrompt: userPrompt, maxOutputTokens: Int(maxOutputTokens))
        guard !result.skippedSilence else { throw QuilTransformationError.emptyInstruction }
        return result.text
    }
    func cleanTranscript(_ text: String, systemPrompt: String, appContext: String?, model: Gemma4LiteRTModel) async throws -> (text: String, rawOutput: String, processingTime: Double, didFallback: Bool) {
        let request = Gemma4LiteRTTranscriber.cleanupRequest(text, systemPrompt: systemPrompt, appContext: appContext, model: model)
        TranscriptCleanupDebugLogger.prompt(request)
        let effectiveSystem = TranscriptCleanupClient.systemPromptWithAppContextGuidance(systemPrompt, appContext: appContext)
        let result = try await generatePrompt(Self.framed(system: model.isCleanupOnly ? nil : effectiveSystem, user: request), model: model, maxTokens: Int(Gemma4LiteRTTranscriber.maxCleanupOutputTokens))
        if model.isCleanupOnly {
            let guarded = MuesliCleanupV2Prompt.guardResult(result.raw, input: text, generationCompleted: result.completed)
            return (guarded.text, result.raw, result.seconds, guarded.didFallback)
        }
        try Self.validateCompletion(result.raw, completed: result.completed)
        let cleaned = TranscriptCleanupClient.cleanOutput(result.raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!cleaned.isEmpty || Qwen3DeletionCueDetector.containsDeletionCue(text)),
              !Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(cleaned: cleaned, input: text) else { throw GemmaNativeAudioError.invalidResponse }
        return (cleaned, result.raw, result.seconds, false)
    }
    private func log(_ message: String) {
        fputs("[gemma-native-audio] \(message)\n", stderr)
        Gemma4LiteRTLogging.profile("native_audio \(message)")
    }
}

/// Used only by the synchronous MTP iterator under the engine's operation gate.
/// The verifier masks each target row, then commits only the accepted/correction
/// token. Draft candidates never advance this matcher; rejected suffixes cannot
/// affect subsequent constraints. Errors abort the entire response before parsing.
@available(macOS 15.0, *)
final class GemmaToolGrammarProcessor: LogitProcessor, @unchecked Sendable {
    let constraint: GrammarConstraint
    let vocabSize: Int
    let eos: Int
    private(set) var failure: Error?
    private(set) var terminated = false
    private(set) var forcedTokens: [Int32] = []
    private(set) var forcedCount = 0
    private var pendingTermination = false
    init(constraint: GrammarConstraint, vocabSize: Int, eos: Int) {
        self.constraint = constraint; self.vocabSize = vocabSize; self.eos = eos
    }
    func prompt(_ prompt: MLXArray) {}
    func process(logits: MLXArray) -> MLXArray {
        var values = [Float](repeating: -.infinity, count: logits.dim(-1))
        do {
            if failure == nil && !terminated {
                if let forced = forcedTokens.first {
                    guard values.indices.contains(Int(forced)) else { throw GemmaToolCalling.invalid() }
                    values[Int(forced)] = 0
                    return logits + MLXArray(values)
                }
                let mask = try constraint.computeMask()
                for i in 0..<min(vocabSize, values.count) {
                    if !mask.needsApply || (UInt32(bitPattern: mask.mask[i / 32]) & (UInt32(1) << (i % 32))) != 0 {
                        values[i] = 0
                    }
                }
            } else if values.indices.contains(eos) { values[eos] = 0 }
        } catch { failure = error; if values.indices.contains(eos) { values[eos] = 0 } }
        return logits + MLXArray(values)
    }
    func didSample(token: MLXArray) {
        guard failure == nil, !terminated else { return }
        do {
            let sampled = Int32(token.item(Int.self))
            if let forced = forcedTokens.first {
                guard sampled == forced else { throw GemmaToolCalling.invalid() }
                forcedTokens.removeFirst()
                forcedCount += 1
                terminated = forcedTokens.isEmpty && pendingTermination
            } else {
                let result = try constraint.commitToken(sampled)
                // XGrammar has already accepted these tokens. Replay them through
                // the verifier/cache exactly once before consulting its next mask.
                forcedTokens = result.tokens
                pendingTermination = result.isTerminated
                terminated = forcedTokens.isEmpty && pendingTermination
            }
        } catch { failure = error }
    }
    func copy() -> Self {
        // This MTP implementation does not copy its verifier processor. Keep
        // independent matcher state if another caller ever requests a copy.
        do {
            let result = Self(constraint: try constraint.clone(), vocabSize: vocabSize, eos: eos)
            result.failure = failure; result.terminated = terminated
            result.forcedTokens = forcedTokens; result.forcedCount = forcedCount
            result.pendingTermination = pendingTermination
            return result
        } catch {
            let result = Self(constraint: constraint, vocabSize: vocabSize, eos: eos)
            result.failure = error
            return result
        }
    }
}

/// Per-generation adapter. Forced prefixes are verified by the normal MTP
/// iterator, so its existing staged KV commit/rollback remains authoritative.
@available(macOS 15.0, *)
final class GemmaGrammarDrafter: Module, MTPDrafterModel {
    let base: any MTPDrafterModel
    let processor: GemmaToolGrammarProcessor
    private(set) var skippedBlocks = 0
    var maximumBlockSize: Int? { base.maximumBlockSize }
    init(base: any MTPDrafterModel, processor: GemmaToolGrammarProcessor) {
        self.base = base; self.processor = processor
    }
    func draftBlock(target: any LanguageModel, lastToken: MLXArray, lastHidden: MLXArray,
                    sharedKV: [String: (MLXArray, MLXArray)], positionDeltas: MLXArray?,
                    queryOffset: Int, blockSize: Int, sampler: any LogitSampler) -> MLXArray {
        let count = blockSize - 1
        let forced = Array(processor.forcedTokens.prefix(count))
        if forced.count == count {
            skippedBlocks += 1
            return MLXArray(forced).reshaped(1, count)
        }
        let draft = base.draftBlock(target: target, lastToken: lastToken, lastHidden: lastHidden,
            sharedKV: sharedKV, positionDeltas: positionDeltas, queryOffset: queryOffset,
            blockSize: blockSize, sampler: sampler)
        guard !forced.isEmpty else { return draft }
        // Remaining predictions may be less accurate after replacing a prefix;
        // they are only proposals, never accepted without target verification.
        return concatenated([MLXArray(forced).reshaped(1, forced.count), draft[0..., forced.count...]], axis: 1)
    }
}
