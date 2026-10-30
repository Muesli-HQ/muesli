import Foundation
import CoreML
import MuesliCore
import MuesliLLM
import MLX
import Testing
@testable import MuesliNativeApp

@Suite(.serialized)
struct CleanupMLXEvaluationTests {
    init() {
        // Swift Build places the Metal resource in a nested test bundle.
        if let path = ProcessInfo.processInfo.environment["MUESLI_MLX_EVAL_METALLIB"] {
            GPU.metallib = URL(fileURLWithPath: path)
        }
    }
    @Test func qwenMLXCatalogAndPromptContract() {
        for option in [PostProcessorOption.finetunedV4, .qwenV12] {
            #expect(option.modelURL.pathExtension == "safetensors")
            #expect(option.managedModel?.files.count == 6)
            #expect(option.managedModel?.revision.count == 40)
            #expect(option.managedModel?.files.allSatisfy { $0.sha256?.count == 64 } == true)
            #expect(!option.label.contains("Light"))
            let model: CleanupMLXEvaluation.Model = option == .finetunedV4 ? .qwen08 : .qwen
            #expect(model.prompt("First check latency. Second check formatting.", context: "App: Codex") ==
                MuesliCleanupV2Prompt.ggufRequest("First check latency. Second check formatting.", appContext: "App: Codex", format: option.inputFormat))
        }
        #expect(PostProcessorOption.lfmV12.modelURL.pathExtension == "gguf")
        #expect(PostProcessorOption.finetunedV4.label == "muesli Cleanup Lite")
    }

    /// Exercises the actual production manager, not just the evaluation adapter.
    @Test func qwenProductionMLXGolden() async throws {
        guard #available(macOS 15, *), let root = ProcessInfo.processInfo.environment["MUESLI_QWEN_MLX_VERIFY_ROOT"] else { return }
        func rows(_ path: String) throws -> [Row] {
            try String(contentsOfFile: root + "/" + path).split(separator: "\n").map {
                try JSONDecoder().decode(Row.self, from: Data($0.utf8))
            }
        }
        struct NativeReference: Decodable { let kind: String; let text: String }
        let inputs = Array(try rows("common/data/context_authored_v1/heldout.jsonl").prefix(10))
        for option in [PostProcessorOption.finetunedV4, .qwenV12] {
            let references: [String]
            if option == .finetunedV4 {
                references = Array(try rows("models/gemma4/eval/results/challengers/qwen08mlxq8_held.jsonl").prefix(10)).map { $0.pred_text ?? "" }
            } else {
                references = Array(try String(contentsOfFile: root + "/models/gemma4/eval/results/native/sets/qwen2b_mlxq8_held.raw.jsonl")
                    .split(separator: "\n").map { try JSONDecoder().decode(NativeReference.self, from: Data($0.utf8)) }
                    .filter { $0.kind != "warmup" }.prefix(10)).map(\.text)
            }
            let processor = Qwen3PostProcessor(modelURL: option.modelURL, systemPrompt: "ignored", inputFormat: option.inputFormat)
            let config = Qwen3PostProcessor.Configuration(modelURL: option.modelURL, systemPrompt: "ignored", inputFormat: option.inputFormat)
            let loadStart = Date()
            try await processor.prepare()
            print("MLX PRODUCTION \(option.id) load_seconds=\(Date().timeIntervalSince(loadStart))")
            _ = try await processor.process("Hello world.", configuration: config)
            var times: [Double] = []
            for (index, row) in inputs.enumerated() {
                let start = Date()
                let result = try await processor.processResult(row.input_text, appContext: row.context?.formatted, configuration: config)
                times.append(Date().timeIntervalSince(start))
                let matchesReference = result.rawOutput == references[index]
                #expect(matchesReference, "\(option.id) \(row.id): reference mismatch")
                #expect(!result.didFallback)
                let preservesGuardedOutput = result.text == result.rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(preservesGuardedOutput, "\(option.id) \(row.id): guard mismatch")
            }
            print("MLX PRODUCTION \(option.id) warm_median_seconds=\((times.sorted()[4] + times.sorted()[5]) / 2)")
            let bulletInput = "Put this in bullet points. First I am testing the latency. Second I am checking whether formatting survives. Third combine both."
            let bullet = try await processor.processResult(bulletInput, appContext: "App: Codex", configuration: config)
            print("MLX PRODUCTION \(option.id) bullets=\(String(reflecting: bullet.text))")
            #expect(!bullet.didFallback)
            #expect(bullet.text.contains("\n"))
            let unchanged = try await processor.process("The meeting starts at 3 PM.", configuration: config)
            #expect(unchanged == "The meeting starts at 3 PM.")
            await processor.shutdown()
        }
    }

    @Test func exactPromptFraming() {
        let text = "Put this in bullets. First check latency. Second check formatting."
        let context = "App: Codex\nOCR screen text: Muesli"
        #expect(CleanupMLXEvaluation.Model.lfm.prompt(text, context: context) == MuesliCleanupV2Prompt.ggufRequest(text, appContext: context, format: .muesliTrainedV12LFM))
        #expect(CleanupMLXEvaluation.Model.gemma.prompt(text, context: context) == "<bos><|turn>user\n" + MuesliCleanupV2Prompt.request(text, appContext: context) + "<turn|>\n<|turn>model\n")
    }

@Test func bodhanDecoderSmoke() throws {
    guard #available(macOS 15, *), let root = ProcessInfo.processInfo.environment["MUESLI_MLX_BODHAN_ROOT"] else { return }
    let directory = URL(fileURLWithPath: root)
    let tokenizer = try JSONDecoder().decode(BodhanCoreML.Tokenizer.self, from: Data(contentsOf: directory.appendingPathComponent("native-assets/tokenizer.json")))
    let decoder = try BodhanMLXDecoder(root: directory, weightPrecision: "int8")
    let acoustic = try MLMultiArray(shape: [1, 1, 1024], dataType: .float32)
    for i in 0..<1024 { acoustic[i] = 0 }
    let first = try decoder.generate(acoustic: acoustic, length: 1, tokenizer: tokenizer, language: "en", outputMode: .native, frontendSeconds: 0, encoderSeconds: 0, encoderPolicy: "evaluation")
    let second = try decoder.generate(acoustic: acoustic, length: 1, tokenizer: tokenizer, language: "en", outputMode: .native, frontendSeconds: 0, encoderSeconds: 0, encoderPolicy: "evaluation")
    #expect(first.text == second.text)
    #expect(first.tokens == second.tokens)
    #expect(first.decodeSeconds.isFinite)
    #expect(throws: (any Error).self) {
        try decoder.generate(acoustic: acoustic, length: 2, tokenizer: tokenizer, language: "en", outputMode: .native, frontendSeconds: 0, encoderSeconds: 0, encoderPolicy: "evaluation")
    }
}

    @Test func lfmTokenizerParity() async throws {
        guard let root = ProcessInfo.processInfo.environment["MUESLI_MLX_TOKENIZER_PARITY_ROOT"] else { return }
        let descriptor = ManagedCleanupModel.lfmMLXEvaluation
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/muesli/models/mlx-evaluation/" + descriptor.revision)
        try descriptor.validate(modelURL: directory.appendingPathComponent(descriptor.modelFilename))
        let tokenizer = try await CleanupHFTokenizerLoader().load(from: directory)
        let loaded = MuesliLLM.LLM(from: PostProcessorOption.lfmV12.modelURL.path, seed: 7, topK: 1, temp: 0, repeatPenalty: 1, historyLimit: 0)
        let gguf = try #require(loaded)
        let data = try String(contentsOfFile: root + "/common/data/context_authored_v1/heldout.jsonl")
        let rows = try data.split(separator: "\n").map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        for row in rows {
            let prompt = CleanupMLXEvaluation.Model.lfm.prompt(row.input_text, context: row.context?.formatted)
            let ids = tokenizer.encode(text: prompt, addSpecialTokens: false)
            let reference = await gguf.encode(prompt, shouldAddBOS: false).map(Int.init)
            #expect(ids == reference, "Tokenizer IDs differ for \(row.id)")
        }
    }

    @Test func trainingManifestPromptParity() throws {
        guard let root = ProcessInfo.processInfo.environment["MUESLI_MLX_TOKENIZER_PARITY_ROOT"] else { return }
        // Read the training literal as text, without executing Python or a template.
        let source = try String(contentsOfFile: root + "/common/data/build_gemma_manifest.py")
        let start = try #require(source.range(of: "SYSTEM_PROMPT = \"\"\""))
        let remainder = source[start.upperBound...]
        let end = try #require(remainder.range(of: "\"\"\""))
        let trainingInstruction = String(remainder[..<end.lowerBound])
        #expect(MuesliCleanupV2Prompt.systemPrompt == trainingInstruction)
        let rows = try String(contentsOfFile: root + "/common/data/context_authored_v1/heldout.jsonl").split(separator: "\n").map {
            try JSONDecoder().decode(Row.self, from: Data($0.utf8))
        }
        for row in rows {
            let context = row.context?.formatted
            let block = context.map { "<APP-CONTEXT>\n" + String(String.UnicodeScalarView($0.unicodeScalars.prefix(1200))) + "\n</APP-CONTEXT>\n\n" } ?? ""
            let expected = trainingInstruction + "\n\n" + block + row.input_text
            #expect(MuesliCleanupV2Prompt.request(row.input_text, appContext: context) == expected, "Training prompt bytes differ for \(row.id)")
        }
    }

    @Test func gemmaTokenizerRoundTrip() async throws {
        guard let root = ProcessInfo.processInfo.environment["MUESLI_MLX_TOKENIZER_PARITY_ROOT"] else { return }
        let descriptor = ManagedCleanupModel.gemmaMLXEvaluation
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/muesli/models/mlx-evaluation/" + descriptor.revision)
        try descriptor.validate(modelURL: directory.appendingPathComponent(descriptor.modelFilename))
        let tokenizer = try await CleanupHFTokenizerLoader().load(from: directory)
        #expect(tokenizer.encode(text: "<bos>", addSpecialTokens: false) == [2])
        #expect(tokenizer.encode(text: "<turn|>", addSpecialTokens: false) == [106])
        // Verify structural token IDs: a lossless string round trip alone cannot
        // distinguish real turn tokens from a misspelled marker encoded as text.
        #expect(tokenizer.encode(text: "<|turn>", addSpecialTokens: false) == [105])
        #expect(tokenizer.encode(text: "<|turn|>", addSpecialTokens: false) != [105])
        let rows = try String(contentsOfFile: root + "/common/data/context_authored_v1/heldout.jsonl").split(separator: "\n").map {
            try JSONDecoder().decode(Row.self, from: Data($0.utf8))
        }
        for row in rows {
            let prompt = CleanupMLXEvaluation.Model.gemma.prompt(row.input_text, context: row.context?.formatted)
            let ids = tokenizer.encode(text: prompt, addSpecialTokens: false)
            #expect(ids.first == 2)
            #expect(ids.filter { $0 == 2 }.count == 1)
            #expect(ids.filter { $0 == 105 }.count == 2)
            #expect(ids.filter { $0 == 106 }.count == 1)
            #expect(tokenizer.decode(tokenIds: ids, skipSpecialTokens: false) == prompt, "Round trip differs for \(row.id)")
        }
    }

    struct Row: Decodable {
        let id: String
        let input_text: String
        let bucket: String?
        let target_text: String?
        let pred_text: String?
        let context: Context?
        struct Context: Decodable {
            let application: String
            let focused_field: String?
            let visible_screen_context: String?
            var formatted: String {
                var parts = ["App: " + application]
                if let s = focused_field, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("Document context: " + s) }
                if let s = visible_screen_context, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("OCR screen text: " + s) }
                return parts.joined(separator: "\n")
            }
        }
    }
    struct Record: Codable {
        let id: String
        let runtime: String
        let round: Int
        let input: String
        let target: String
        let expected: String
        let raw: String
        let output: String
        let seconds: Double
        let loadSeconds: Double
        let details: CleanupMLXEvaluation.Result?
    }
    @Test func matchedEvaluation() async throws {
        guard #available(macOS 15, *),
              let root = ProcessInfo.processInfo.environment["MUESLI_MLX_EVAL_ROOT"],
              let report = ProcessInfo.processInfo.environment["MUESLI_MLX_EVAL_REPORT"] else { return }
        let environment = ProcessInfo.processInfo.environment
        let count = Int(environment["MUESLI_MLX_EVAL_COUNT"] ?? "60") ?? 60
        let rounds = Int(environment["MUESLI_MLX_EVAL_ROUNDS"] ?? "1") ?? 1
        let runtime = environment["MUESLI_MLX_EVAL_RUNTIME"] ?? "lfm-mlx"
        guard runtime != "gemma-litert" else { Issue.record("LiteRT was removed; use the archived reference results."); return }
        func rows(_ path: String) throws -> [Row] {
            try String(contentsOfFile: root + "/" + path).split(separator: "\n").map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        }
        let allInputs = try rows("common/data/context_authored_v1/heldout.jsonl")
        // The source is grouped by category; a prefix of 60 would contain only code.
        let inputs: [Row]
        if count == 60 {
            var seen: [String: Int] = [:]
            inputs = allInputs.filter { row in
                let bucket = row.bucket ?? "unknown"
                seen[bucket, default: 0] += 1
                return seen[bucket, default: 0] <= 10
            }
        } else { inputs = Array(allInputs.prefix(count)) }
        let reference: String
        switch runtime {
        case "lfm-mlx": reference = "challengers/lfm25mlxq8_held.jsonl"
        case "gemma-mlx": reference = "challengers/gemmav12mlxq4_held.jsonl"
        case "lfm-gguf": reference = "challengers/lfm25gguf_held.jsonl"
        case "qwen-gguf": reference = "challengers/qwen35gguf_q4km_held.jsonl"
        case "gemma-litert": reference = "litert/v12gpu_mtp_held.jsonl"
        default: throw NSError(domain: "CleanupEvaluation", code: 1)
        }
        let expected = Dictionary(uniqueKeysWithValues: try rows("models/gemma4/eval/results/" + reference).map { ($0.id, $0.pred_text ?? "") })
        FileManager.default.createFile(atPath: report, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: report))
        defer { try? handle.close() }
        func record(_ row: Row, round: Int, raw: String, output: String, seconds: Double, load: Double, details: CleanupMLXEvaluation.Result? = nil) throws {
            let value = Record(id: row.id, runtime: runtime, round: round, input: row.input_text, target: row.target_text ?? "", expected: expected[row.id] ?? "", raw: raw, output: output, seconds: seconds, loadSeconds: load, details: details)
            try handle.write(contentsOf: JSONEncoder().encode(value) + Data([10]))
            if round == 0 && inputs.firstIndex(where: { $0.id == row.id })! < 10 && runtime != "gemma-litert" {
                #expect(output == expected[row.id], "\(runtime) \(row.id): raw=\(raw)")
            }
        }
        if runtime.hasSuffix("mlx") {
            let model: CleanupMLXEvaluation.Model = runtime == "lfm-mlx" ? .lfm : .gemma
            let descriptor: ManagedCleanupModel = model == .lfm ? .lfmMLXEvaluation : .gemmaMLXEvaluation
            let directory = environment["MUESLI_MLX_MODEL_DIR"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/muesli/models/mlx-evaluation/" + descriptor.revision)
            if environment["MUESLI_MLX_MODEL_DIR"] == nil {
                try await ModelDownloadCoordinator.shared.download(descriptor.manifest(id: "cleanup-mlx-evaluation-" + model.rawValue), to: directory)
            }
            let loadStart = Date()
            let engine = try await CleanupMLXEvaluation(directory: directory, descriptor: descriptor, model: model)
            let load = Date().timeIntervalSince(loadStart)
            _ = try await engine.process("Hello world.", context: nil)
            for round in 0..<rounds {
                for row in inputs {
                    let result = try await engine.process(row.input_text, context: row.context?.formatted, prefillStepSize: Int(environment["MUESLI_MLX_PREFILL_STEP"] ?? "2048") ?? 2048)
                    try record(row, round: round, raw: result.raw, output: result.output, seconds: result.seconds, load: load, details: result)
                }
            }
        } else {
            let option: PostProcessorOption = runtime == "lfm-gguf" ? .lfmV12 : .qwenV12
            let descriptor: ManagedCleanupModel = runtime == "lfm-gguf" ? .lfm : .qwen
            let modelURL = option.cacheDirectory.appendingPathComponent(descriptor.modelFilename)
            try descriptor.validate(modelURL: modelURL)
            let engine = Qwen3PostProcessor(modelURL: modelURL, systemPrompt: "ignored", inputFormat: option.inputFormat)
            let config = Qwen3PostProcessor.Configuration(modelURL: modelURL, systemPrompt: "ignored", inputFormat: option.inputFormat)
            let start = Date()
            try await engine.prepare()
            let load = Date().timeIntervalSince(start)
            _ = try await engine.process("Hello world.", configuration: config)
            for round in 0..<rounds {
                for row in inputs {
                    let start = Date()
                    let output = try await engine.process(row.input_text, appContext: row.context?.formatted, configuration: config)
                    // Existing wrapper exposes guarded output here, not raw native tokens.
                    try record(row, round: round, raw: "", output: output, seconds: Date().timeIntervalSince(start), load: load)
                }
            }
            await engine.shutdown()
        }
    }
}

@Suite(.serialized)
struct GemmaMTPEvaluationTests {
    init() {
        if let path = ProcessInfo.processInfo.environment["MUESLI_MLX_EVAL_METALLIB"] { GPU.metallib = URL(fileURLWithPath: path) }
    }
    struct QuillCase: Codable {
        let id: String; let selected: String; let instruction: String; let context: String?; let expected: String?
    }
    struct Record: Codable {
        let id: String; let mode: String; let block: Int; let round: Int; let prompt: String; let target: String?
        let raw: String; let output: String; let validationError: String?; let seconds: Double; let loadSeconds: Double
        let details: GemmaMTPEvaluation.Result?
    }
    @Test func evaluate() async throws {
        guard #available(macOS 15, *), let report = ProcessInfo.processInfo.environment["MUESLI_MTP_REPORT"] else { return }
        let env = ProcessInfo.processInfo.environment
        let mode = env["MUESLI_MTP_MODE"] ?? "cleanup"
        let block = Int(env["MUESLI_MTP_BLOCK"] ?? "3")!
        let count = Int(env["MUESLI_MTP_COUNT"] ?? "60")!
        let rounds = Int(env["MUESLI_MTP_ROUNDS"] ?? "1")!
        let root = env["MUESLI_MLX_EVAL_ROOT"]
        let cleanup = mode.hasPrefix("cleanup")
        let litert = mode.hasSuffix("-litert")
        guard !litert else { Issue.record("LiteRT was removed; use the archived reference results."); return }
        let rows: [(id: String, prompt: String, input: String, target: String?, appContext: String?)]
        if cleanup {
            guard let inputs = env["MUESLI_MTP_INPUTS"] ?? root.map({ $0 + "/common/data/context_authored_v1/heldout.jsonl" }) else {
                print("Skipping MTP cleanup evaluation: set MUESLI_MTP_INPUTS or MUESLI_MLX_EVAL_ROOT")
                return
            }
            let all = try String(contentsOfFile: inputs).split(separator: "\n").map { try JSONDecoder().decode(CleanupMLXEvaluationTests.Row.self, from: Data($0.utf8)) }
            var seen: [String: Int] = [:]
            let selected = count == 60 ? all.filter { row in
                seen[row.bucket ?? "", default: 0] += 1
                return seen[row.bucket ?? ""]! <= 10
            } : Array(all.prefix(count))
            rows = selected.map { ($0.id, CleanupMLXEvaluation.Model.gemma.prompt($0.input_text, context: $0.context?.formatted), $0.input_text, $0.target_text, $0.context?.formatted) }
        } else {
            let cases = try JSONDecoder().decode([QuillCase].self, from: Data(contentsOf: URL(fileURLWithPath: env["MUESLI_QUILL_CASES"]!)))
            rows = cases.prefix(count).map { item in
                let prompt = litert ? QuilTransformationPrompt.userPrompt(selectedText: item.selected, instruction: item.instruction, appContext: item.context)
                    : GemmaMTPEvaluation.quillPrompt(selected: item.selected, instruction: item.instruction, appContext: item.context)
                return (item.id, prompt, item.selected, item.expected, item.context)
            }
        }
        FileManager.default.createFile(atPath: report, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: report)); defer { try? handle.close() }
        func save(_ row: (id: String, prompt: String, input: String, target: String?, appContext: String?), raw: String, seconds: Double, load: Double, round: Int, details: GemmaMTPEvaluation.Result?, outputOverride: String? = nil, blockOverride: Int? = nil) throws {
            var output = raw, error: String?
            if cleanup { output = MuesliCleanupV2Prompt.guardedOutput(raw, input: row.input, generationCompleted: details?.stopReason == "stop") }
            else { do { output = try QuilTransformationOutput.validated(raw) } catch let e { error = String(describing: e) } }
            if let outputOverride { output = outputOverride }
            let record = Record(id: row.id, mode: mode, block: blockOverride ?? block, round: round, prompt: row.prompt, target: row.target, raw: raw, output: output, validationError: error, seconds: seconds, loadSeconds: load, details: details)
            try handle.write(contentsOf: JSONEncoder().encode(record) + Data([10]))
        }
        let start = Date()
        if mode == "cleanup-legacy" {
            let target = ManagedCleanupModel.gemmaMLXEvaluation
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/muesli/models/mlx-evaluation/" + target.revision)
            let engine = try await CleanupMLXEvaluation(directory: directory, descriptor: target, model: .gemma)
            let load = Date().timeIntervalSince(start)
            _ = try await engine.process(rows[0].input, context: rows[0].appContext)
            for round in 0..<rounds { for row in rows {
                let result = try await engine.process(row.input, context: row.appContext)
                try save(row, raw: result.raw, seconds: result.seconds, load: load, round: round, details: nil, outputOverride: result.output)
                #expect(!result.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty generation: \(row.id)")
            } }
        } else {
            let draftPath = env["MUESLI_MTP_DRAFTER_MANIFEST"] ?? (cleanup ? "/tmp/gemma-e2b-drafter-manifest.json" : "/tmp/gemma-e4b-drafter-manifest.json")
            let draft = try JSONDecoder().decode(GemmaMTPEvaluation.Artifact.self, from: Data(contentsOf: URL(fileURLWithPath: draftPath)))
            let target: ManagedCleanupModel, directory: URL
            if cleanup {
                target = .gemmaMLXEvaluation
                directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/muesli/models/mlx-evaluation/" + target.revision)
            } else {
                let artifact = try JSONDecoder().decode(GemmaMTPEvaluation.Artifact.self, from: Data(contentsOf: URL(fileURLWithPath: env["MUESLI_MTP_TARGET_MANIFEST"] ?? "/tmp/gemma-quill-e4b-manifest.json")))
                target = artifact.descriptor; directory = URL(fileURLWithPath: artifact.directory)
            }
            let engine = try await GemmaMTPEvaluation(targetDirectory: directory, target: target, drafterArtifact: draft, cleanup: cleanup)
            let load = Date().timeIntervalSince(start)
            let blocks = block == -1 ? [1, 3, 6] : [block]
            for choice in blocks { _ = try await engine.process(prompt: rows[0].prompt, blockSize: choice, maxTokens: cleanup ? 1024 : 4096) }
            for round in 0..<rounds { for (rowIndex, row) in rows.enumerated() {
                // Rotate within each round so no strategy always gets the first request.
                let offset = (round + rowIndex) % blocks.count
                let order = Array(blocks[offset...] + blocks[..<offset])
                for choice in order {
                    let result = try await engine.process(prompt: row.prompt, blockSize: choice, maxTokens: cleanup ? 1024 : 4096)
                    try save(row, raw: result.raw, seconds: result.seconds, load: load, round: round, details: result, blockOverride: choice)
                    #expect(!result.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty generation: \(row.id)")
                    #expect(result.stopReason == "stop", "\(row.id) did not finish normally")
                    if choice > 1 {
                        #expect((result.proposed ?? 0) > 0, "MTP did not draft: \(row.id)")
                        #expect(result.passthroughReason == nil, "MTP fell back: \(row.id)")
                    }
                }
            } }

        }
    }
}
