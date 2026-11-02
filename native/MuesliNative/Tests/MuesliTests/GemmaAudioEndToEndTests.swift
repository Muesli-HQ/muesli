import Foundation
import Testing
import MLX
import MLXNN
import MLXVLM
import MLXLMCommon
import GemmaAudioEvaluation
@testable import MuesliNativeApp

/// Opt-in laboratory. Never registered with the app's backend router.
@Suite(.serialized)
struct GemmaAudioEndToEndTests {
    struct Clip: Codable { let id: String; let wav: String; let expected: String }
    struct Record: Codable {
        let id: String; let runtime: String; let round: Int; let expected: String; let output: String; let raw: String?
        let validationError: String?; let prompt: String; let audioSeconds: Double; let seconds: Double; let loadSeconds: Double
        let frontendSeconds: Double?; let encoderSeconds: Double?; let prefillSeconds: Double?; let decodeSeconds: Double?
        let firstTokenSeconds: Double?; let outputTokens: Int?; let stopReason: String?; let thermalBefore: Int; let thermalAfter: Int
    }
    init() {
        if let path = ProcessInfo.processInfo.environment["MUESLI_MLX_EVAL_METALLIB"] { GPU.metallib = URL(fileURLWithPath: path) }
    }
    @Test func evaluate() async throws {
        let env = ProcessInfo.processInfo.environment
        guard #available(macOS 15, *), let report = env["MUESLI_AUDIO_E2E_REPORT"], let casesPath = env["MUESLI_AUDIO_E2E_CASES"] else { return }
        Memory.cacheLimit = 256 * 1024 * 1024
        let runtime = env["MUESLI_AUDIO_E2E_RUNTIME"] ?? "e4b-mlx"
        guard !runtime.hasSuffix("litert") else { Issue.record("LiteRT was removed; use the archived reference results."); return }
        let rounds = Int(env["MUESLI_AUDIO_E2E_ROUNDS"] ?? "2")!
        let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: URL(fileURLWithPath: casesPath)))
        let prompt = Gemma4LiteRTModelStore.resolvedPrompt()
        FileManager.default.createFile(atPath: report, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: report)); defer { try? handle.close() }
        func save(_ record: Record) throws {
            try handle.write(contentsOf: JSONEncoder().encode(record) + Data([10]))
            try handle.synchronize()
            print("AUDIO_E2E \(record.runtime) \(record.id) round=\(record.round) seconds=\(record.seconds) output=\(record.output)")
        }
        let manifest = try JSONDecoder().decode(GemmaMTPEvaluation.Artifact.self,
            from: Data(contentsOf: URL(fileURLWithPath: env["MUESLI_AUDIO_E2E_MANIFEST"]!)))
        // Verification is deliberately outside model loading and inference timings.
        try manifest.validate()
        let directory = URL(fileURLWithPath: manifest.directory)
        let start = Date()
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let audioConfig = try JSONDecoder().decode(GemmaAudioEncoder.Configuration.self,
            from: JSONSerialization.data(withJSONObject: object["audio_config"]!))
        object.removeValue(forKey: "vision_config")
        // This public adapter accepts already-encoded E-series audio, not raw Unified audio.
        let configuration = try JSONDecoder().decode(Gemma4UnifiedConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object))
        let model = Gemma4Unified(configuration)
        let baseConfig = try JSONDecoder().decode(BaseConfiguration.self, from: data)
        var arrays = try MLX.loadArrays(url: directory.appendingPathComponent("model.safetensors"))
        let towerWeights = arrays.filter { $0.key.hasPrefix("audio_tower.") }
        let encoder = try GemmaAudioEncoder(config: audioConfig, weights: towerWeights)
        eval(Array(towerWeights.values))
        arrays = model.sanitize(weights: arrays.filter { !$0.key.hasPrefix("audio_tower.") && !$0.key.hasPrefix("vision_tower.") })
        quantize(model: model) { path, _ in
            guard arrays[path + ".scales"] != nil else { return nil }
            return baseConfig.perLayerQuantization?.quantization(layer: path)?.asTuple
        }
        try model.update(parameters: ModuleParameters.unflattened(arrays), verify: [.all])
        eval(model)
        arrays.removeAll()
        let tokenizer = try await CleanupHFTokenizerLoader().load(from: directory)
        var modelConfig = ModelConfiguration(directory: directory)
        modelConfig.extraEOSTokens.formUnion(["<turn|>", "<eos>"])
        let context = ModelContext(configuration: modelConfig, model: model, processor: StandInUserInputProcessor(), tokenizer: tokenizer)
        let load = Date().timeIntervalSince(start)
        let frontend = try GemmaAudioFeatures()
        for round in 0..<rounds { for clip in clips {
            let thermal = ProcessInfo.processInfo.thermalState.rawValue
            let start = Date()
            let wav = try WavReader.readFloatMonoWAV(from: URL(fileURLWithPath: clip.wav))
            let features = try frontend.extract(samples: wav.samples, sampleRate: wav.sampleRate)
            eval(features.features)
            let frontendTime = Date().timeIntervalSince(start)
            let encoderStart = Date()
            let trace = try encoder.encode(features, retainTrace: false)
            let encoded = trace["encoder"]!, mask = trace["encoder_mask"]!
            eval(encoded, mask)
            let encoderTime = Date().timeIntervalSince(encoderStart)
            let count = mask.asType(.int32).sum().item(Int.self)
            // Literal original Gemma framing: same user prompt followed by the audio.
            let framed = "<bos><|turn>user\n" + prompt + "<|audio>" + String(repeating: "<|audio|>", count: count) + "<audio|><turn|>\n<|turn>model\n"
            let ids = tokenizer.encode(text: framed, addSpecialTokens: false)
            #expect(ids.filter { $0 == configuration.audioTokenId }.count == count)
            let input = LMInput(text: .init(tokens: MLXArray(ids).reshaped(1, -1)), audio: .init(features: encoded, mask: mask.reshaped(1, -1)))
            let parameters = GenerateParameters(maxTokens: Int(Gemma4LiteRTTranscriber.maxOutputTokens), temperature: 0, topK: 1)
            let stream = try generateTokens(input: input, parameters: parameters, context: context)
            var tokens: [Int] = [], first: Double?, completion: GenerateCompletionInfo?
            for await event in stream {
                switch event {
                case .token(let token):
                    if first == nil { first = Date().timeIntervalSince(start) }
                    tokens.append(token)
                case .info(let info): completion = info
                }
            }
            let info = try #require(completion)
            let raw = tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
            let cleaned = Gemma4LiteRTTranscriber.cleanTranscript(raw)
            let rejected = Gemma4LiteRTTranscriber.looksLikePromptLeak(cleaned) || Gemma4LiteRTTranscriber.looksLikeAssistantResponse(cleaned)
            let output = rejected ? "" : cleaned
            try save(Record(id: clip.id, runtime: runtime, round: round, expected: clip.expected, output: output, raw: raw, validationError: rejected ? "invalidResponse" : nil,
                prompt: prompt, audioSeconds: Double(wav.samples.count)/Double(wav.sampleRate), seconds: Date().timeIntervalSince(start), loadSeconds: load,
                frontendSeconds: frontendTime, encoderSeconds: encoderTime, prefillSeconds: info.promptTime, decodeSeconds: info.generateTime,
                firstTokenSeconds: first, outputTokens: tokens.count, stopReason: String(describing: info.stopReason),
                thermalBefore: thermal, thermalAfter: ProcessInfo.processInfo.thermalState.rawValue))
            if !clip.expected.isEmpty { #expect(!output.isEmpty, "Empty transcript: \(clip.id)") }
            #expect(info.stopReason == .stop, "Output cap: \(clip.id)")
        } }
    }
}
