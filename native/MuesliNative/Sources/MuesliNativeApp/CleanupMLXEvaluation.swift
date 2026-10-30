import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import Hub

/// Shared native cleanup tokenizer adapter. Training framing is constructed by Muesli, never a chat template.
struct CleanupHFTokenizer: MLXLMCommon.Tokenizer {
    let tokenizer: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenizer.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }
    var bosToken: String? { tokenizer.bosToken }
    var eosToken: String? { tokenizer.eosToken }
    var unknownToken: String? { tokenizer.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
}

struct CleanupHFTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        // The Gemma export omits this option. Swift defaults it to true,
        // silently rewriting spaces around punctuation/quotes on decode.
        // Preserve raw model text; cleanup belongs to the explicit output guard.
        let decoder = JSONDecoder()
        let config = try decoder.decode(Config.self, from: Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json")))
        var values = config.dictionary(or: [:])
        values["clean_up_tokenization_spaces"] = false
        // Qwen3.5 uses the same byte-level BPE as Qwen2. The pinned Swift
        // tokenizer does not yet recognize the export's new class name.
        if values["tokenizer_class"]?.string() == "Qwen3_5Tokenizer" {
            values["tokenizer_class"] = "Qwen2Tokenizer"
        }
        let data = try decoder.decode(Config.self, from: Data(contentsOf: directory.appendingPathComponent("tokenizer.json")))
        return CleanupHFTokenizer(tokenizer: try AutoTokenizer.from(tokenizerConfig: Config(values), tokenizerData: data))
    }
}

/// Shared native cleanup engine; raw training prompts bypass chat templates.
actor CleanupMLXEvaluation {
    enum Model: String, Sendable { case lfm, gemma, qwen, qwen08
        var stop: String { self == .gemma ? "<turn|>" : "<|im_end|>" }
        func prompt(_ text: String, context: String?) -> String {
            switch self {
            case .lfm:
                return MuesliCleanupV2Prompt.ggufRequest(text, appContext: context, format: .muesliTrainedV12LFM)
            case .qwen, .qwen08:
                return MuesliCleanupV2Prompt.ggufRequest(text, appContext: context, format: self == .qwen ? .muesliTrainedV12Qwen : .muesliTrainedV12Qwen08)
            case .gemma:
                // Gemma turn-start is token 105 (<|turn>), not the ordinary-text typo
                // <|turn|> in the handoff table. Preserve the training user content.
                return "<bos><|turn>user\n" + MuesliCleanupV2Prompt.request(text, appContext: context) + "<turn|>\n<|turn>model\n"
            }
        }
    }
    struct Result: Sendable, Codable {
        let raw: String
        let output: String
        let didFallback: Bool
        let seconds: Double
        let tokenizeSeconds: Double
        let prefillSeconds: Double
        let decodeSeconds: Double
        let inputTokens: Int
        let outputTokens: Int
        let stopReason: String
        let startedAt: Date
        let thermalStateBefore: Int
        let thermalStateAfter: Int
        let prefillStepSize: Int
    }
    private let container: ModelContainer
    private let model: Model

    init(directory: URL, descriptor: ManagedCleanupModel, model: Model) async throws {
        try descriptor.validate(modelURL: directory.appendingPathComponent(descriptor.modelFilename))
        self.model = model
        let factory: LLMModelFactory
        if model == .lfm {
            // Match Python mlx-lm's intermediate_size alias, omitted by Swift LM 3.32.3.
            // Adapt only in memory; keep pinned files and official model code unchanged.
            let registry = ModelTypeRegistry<LanguageModel>(creators: ["lfm2": { data in
                guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NSError(domain: "CleanupMLXEvaluation", code: 1)
                }
                if object["block_ff_dim"] == nil { object["block_ff_dim"] = object["intermediate_size"] }
                let config = try JSONDecoder().decode(LFM2Configuration.self, from: JSONSerialization.data(withJSONObject: object))
                return LFM2Model(config)
            }])
            factory = LLMModelFactory(typeRegistry: registry, modelRegistry: LLMRegistry.shared)
        } else { factory = .shared }
        container = try await factory.loadContainer(from: directory, using: CleanupHFTokenizerLoader())
        await container.update { context in context.configuration.extraEOSTokens.insert(model.stop) }
    }

    func process(_ text: String, context: String?, prefillStepSize: Int = 2048, maxTokens: Int = 1024) async throws -> Result {
        let prompt = model.prompt(text, context: context)
        return try await container.perform { context in
            let start = Date()
            let thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
            let ids = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
            let tokenizeSeconds = Date().timeIntervalSince(start)
            // Match the reference mlx-lm 0.32.2: stride 2048, reserve the final token.
            // Swift defaults to balanced 512-token chunks, which changes rounding.
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0, topK: 1, prefill: .init(stepSize: prefillStepSize, chunking: .remainder))
            // Swift's generic prepare also forwards short prompts whole. The Python
            // reference always evaluates all but the last token into a fresh cache.
            // Use official model/cache APIs to preserve those exact boundaries.
            let cache = try context.model.newCache(parameters: parameters)
            let prefillStart = Date()
            var processed = 0
            while processed < ids.count - 1 {
                try Task.checkCancellation()
                let end = min(processed + max(1, prefillStepSize), ids.count - 1)
                let input = MLXArray(Array(ids[processed..<end])).reshaped(1, -1)
                _ = context.model(input, cache: cache)
                eval(cache)
                processed = end
            }
            let manualPrefillSeconds = Date().timeIntervalSince(prefillStart)
            let stream = try MLXLMCommon.generateTokens(input: LMInput(tokens: MLXArray(Array(ids[processed...]))), cache: cache, parameters: parameters, context: context)
            var tokens: [Int] = []
            var completion: GenerateCompletionInfo?
            for await event in stream {
                switch event {
                case .token(let id): tokens.append(id)
                case .info(let info): completion = info
                }
            }
            try Task.checkCancellation()
            guard let completion else { throw CancellationError() }
            let raw = context.tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
            let guarded = MuesliCleanupV2Prompt.guardResult(raw, input: text, generationCompleted: completion.stopReason == .stop)
            return Result(raw: raw, output: guarded.text, didFallback: guarded.didFallback, seconds: Date().timeIntervalSince(start), tokenizeSeconds: tokenizeSeconds, prefillSeconds: manualPrefillSeconds + completion.promptTime, decodeSeconds: completion.generateTime, inputTokens: ids.count, outputTokens: tokens.count, stopReason: String(describing: completion.stopReason), startedAt: start, thermalStateBefore: thermalBefore, thermalStateAfter: ProcessInfo.processInfo.thermalState.rawValue, prefillStepSize: prefillStepSize)
        }
    }
}

// Pinned evaluation artifacts; reuse the existing managed download and integrity checks.
extension ManagedCleanupModel {
    static let lfmMLXEvaluation = Self("Muesli-HQ/lfm25-1.2b-muesli-cleanup-v12-mlx-8bit", "f23c8378659610fbe153799be73321bdbdb1fe24", [
        ("model.safetensors", 1243645809, "46c776d264da377209246d1e8a87e11cb2b09e9c98d42c95c5c5df33a584ed30"),
        ("chat_template.jinja", 5487, "ba551d58630afa3190b1be3602e28301f3d2e9bbac978dfc49d6d825171648b6"),
        ("config.json", 1645, "9f54a747b064beca028803148ba58efe1645a3210deec7d5561140a9dd8473e9"),
        ("generation_config.json", 131, "a899e603c6a23ecfba4ed7a091ab4db687aa2f92fca495b524c7b9151cca3afd"),
        ("model.safetensors.index.json", 23415, "fcfe171be23642632ad0e997d641bb2a92c137635660e28f07efa4eb3dbe659b"),
        ("tokenizer.json", 4733389, "df1d8d5ec5d091b460562ffd545e4a5e91d17d4a0db7ebe733be34ed374377bd"),
        ("LICENSE", 10644, "61d7e939a05911c765b7e98ffaa1ab5ca6c0174a65350766c25cb10197d19fc8"),
        ("tokenizer_config.json", 552, "ffaa952c559f2ff41eae3874e5e88e055074f6a6ef08ec7e3867ddc9e87e88a8"),
    ])
    static let gemmaMLXEvaluation = Self("Muesli-HQ/gemma4-e2b-muesli-cleanup-v12-mlx-4bit", "29d40bae87983afbc330f39bf6d2b47f38c2215c", [
        ("model.safetensors", 2604122719, "8bdf6a16ac2e0378750a6cd41f01c667c687fc5a37deb9083e0531e0d364d1d5"),
        ("chat_template.jinja", 18810, "241c50d86bdfe5e43307da87f559cd2416aacd67a8de46c15acc0105ef2200b7"),
        ("config.json", 4860, "503ab0b719071041505fa30263822d2f4ae5b199749b47feaa1cd0bccbe6994c"),
        ("generation_config.json", 203, "5439541d3bf0ba9ade7c1122dc14703f85f32a520150351b344b14f48c574cc2"),
        ("model.safetensors.index.json", 95576, "73914239147aea77ab9571f091ce48405493596b2ea61440f35fb78f2c993534"),
        ("tokenizer.json", 32169626, "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
        ("tokenizer_config.json", 2750, "47a25a81fe589682f4e3ca0b580943a70e241c599b463c1fe1954419dc0a4b6f"),
    ])
}
