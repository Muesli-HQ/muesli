import Foundation
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon

/// Evaluation-only. No prompt templates or production model selection changes.
actor GemmaMTPEvaluation {
    struct Artifact: Codable {
        struct File: Codable { let file: String; let bytes: Int64; let sha256: String }
        let repo: String; let revision: String; let directory: String; let files: [File]
        var descriptor: ManagedCleanupModel {
            ManagedCleanupModel(repo, revision, files.sorted { ($0.file.hasSuffix(".safetensors") ? 0 : 1) < ($1.file.hasSuffix(".safetensors") ? 0 : 1) }.map { ($0.file, $0.bytes, $0.sha256) })
        }
        func validate() throws { try descriptor.validate(modelURL: URL(fileURLWithPath: directory).appendingPathComponent(descriptor.modelFilename)) }
    }
    struct Result: Codable, Sendable {
        let raw: String; let seconds: Double; let tokenizeSeconds: Double; let prefillSeconds: Double; let decodeSeconds: Double
        let firstTokenSeconds: Double; let inputTokens: Int; let outputTokens: Int; let stopReason: String
        let proposed: Int?; let accepted: Int?; let passthroughReason: String?; let thermalBefore: Int; let thermalAfter: Int
    }
    private let container: ModelContainer
    private let drafter: any MTPDrafterModel
    init(targetDirectory: URL, target: ManagedCleanupModel, drafterArtifact: Artifact, cleanup: Bool) async throws {
        try target.validate(modelURL: targetDirectory.appendingPathComponent(target.modelFilename))
        try drafterArtifact.validate()
        let registry = ModelTypeRegistry<LanguageModel>(creators: ["gemma4": { data in
            if cleanup {
                // The fine-tune exports text weights only. Use the official MTP-capable
                // text backbone without constructing missing vision/audio modules.
                var config = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                config.removeValue(forKey: "vision_config")
                config.removeValue(forKey: "audio_config")
                return Gemma4Unified(try JSONDecoder().decode(Gemma4UnifiedConfiguration.self, from: JSONSerialization.data(withJSONObject: config)))
            }
            return Gemma4(try JSONDecoder().decode(Gemma4Configuration.self, from: data))
        }])
        let factory = LLMModelFactory(typeRegistry: registry, modelRegistry: LLMRegistry.shared)
        container = try await factory.loadContainer(from: targetDirectory, using: CleanupHFTokenizerLoader())
        await container.update { $0.configuration.extraEOSTokens.formUnion(["<turn|>", "<eos>"]) }
        let directory = URL(fileURLWithPath: drafterArtifact.directory)
        let config = try JSONDecoder().decode(Gemma4AssistantConfiguration.self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        let draft = Gemma4AssistantDraftModel(config)
        try await loadWeights(modelDirectory: directory, model: draft)
        drafter = draft
    }
    static func quillPrompt(selected: String, instruction: String, appContext: String?) -> String {
        // Literal Gemma instruction framing; preserve the existing Quill system and user content.
        "<bos><|turn>system\n" + QuilTransformationPrompt.system + "<turn|>\n<|turn>user\n"
        + QuilTransformationPrompt.userPrompt(selectedText: selected, instruction: instruction, appContext: appContext)
        + "<turn|>\n<|turn>model\n"
    }
    func process(prompt: String, blockSize: Int, maxTokens: Int) async throws -> Result {
        let draft = drafter
        return try await container.perform { context in
            let start = Date(), thermal = ProcessInfo.processInfo.thermalState.rawValue
            let ids = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
            let tokenize = Date().timeIntervalSince(start)
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0, topK: 1, prefill: .init(stepSize: 2048, chunking: .remainder))
            let cache = try context.model.newCache(parameters: parameters)
            let prefillStart = Date()
            var pos = 0
            while pos < ids.count - 1 {
                try Task.checkCancellation()
                let end = min(pos + 2048, ids.count - 1)
                _ = context.model(MLXArray(Array(ids[pos..<end])).reshaped(1, -1), cache: cache)
                eval(cache); pos = end
            }
            let prefill = Date().timeIntervalSince(prefillStart)
            let input = LMInput(tokens: MLXArray(Array(ids[pos...])))
            let stream: AsyncStream<TokenGeneration>
            if blockSize > 1 {
                stream = try generateTokens(input: input, cache: cache, parameters: parameters, context: context, mtpDrafter: draft, blockSize: blockSize)
            } else {
                stream = try generateTokens(input: input, cache: cache, parameters: parameters, context: context)
            }
            var tokens: [Int] = [], first: Double?
            var completion: GenerateCompletionInfo?
            for await event in stream {
                switch event {
                case .token(let token):
                    if first == nil { first = Date().timeIntervalSince(start) }
                    tokens.append(token)
                case .info(let info): completion = info
                }
            }
            guard let info = completion else { throw CancellationError() }
            return Result(raw: context.tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false), seconds: Date().timeIntervalSince(start), tokenizeSeconds: tokenize, prefillSeconds: prefill + info.promptTime, decodeSeconds: info.generateTime, firstTokenSeconds: first ?? 0, inputTokens: ids.count, outputTokens: tokens.count, stopReason: String(describing: info.stopReason), proposed: info.proposedDraftTokens, accepted: info.acceptedDraftTokens, passthroughReason: info.passthroughReason, thermalBefore: thermal, thermalAfter: ProcessInfo.processInfo.thermalState.rawValue)
        }
    }
}
