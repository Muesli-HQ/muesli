import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

struct MuesliCleanupV2Tests {
    @Test func trainingContract() {
        let request = MuesliCleanupV2Prompt.request("hello", appContext: String(repeating: "x", count: 1300))
        #expect(request == MuesliCleanupV2Prompt.systemPrompt + "\n\n<APP-CONTEXT>\n" + String(repeating: "x", count: 1200) + "\n</APP-CONTEXT>\n\nhello")
        #expect(!request.contains("<USER-INPUT>"))
        #expect(MuesliCleanupV2Prompt.request("hello", appContext: nil) == MuesliCleanupV2Prompt.systemPrompt + "\n\nhello")
    }
    @Test func stripsOnlyLeadingArtifacts() {
        #expect(MuesliCleanupV2Prompt.cleanOutput("model\n</APP-CONTEXT>\n\nHello") == "Hello")
        #expect(MuesliCleanupV2Prompt.cleanOutput(MuesliCleanupV2Prompt.systemPrompt + "\n\nHello") == "Hello")
        #expect(MuesliCleanupV2Prompt.cleanOutput("model training is useful") == "model training is useful")
        #expect(MuesliCleanupV2Prompt.cleanOutput("Hello\nmodel") == "Hello\nmodel")
    }
    @Test func cleanupOnlyIdentity() {
        let model = Gemma4LiteRTModel.muesliCleanupV2
        #expect(!Gemma4LiteRTModel.generalPurpose.contains(model))
        #expect(!BackendOption.all.contains { $0.model == model.repoID })
        #expect(!ComputerUseLocalPlanner.models.contains { $0.id.contains(model.repoID) })
        #expect(PostProcessorOption.defaultOption.id == "qwen35-postproc-v3")
        let url = Gemma4LiteRTModelStore.resolvedModelURL(for: model, environment: [Gemma4LiteRTModelStore.modelPathEnvVar: "/tmp/wrong-model"])
        #expect(url.lastPathComponent == model.filename)
    }
    @Test func migratesV10Selection() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"post_processor_backend":"gemma4-litert","post_processor_gemma_model":"muesli-cleanup-v2-gemma-v10"}"#.utf8))
        #expect(config.postProcessorGemmaModel == Gemma4LiteRTModel.muesliCleanupV2.repoID)
        #expect(config.postProcessorGemmaModel == "muesli-cleanup-v2-gemma-v12")
        #expect(Gemma4LiteRTModel.muesliCleanupV2.filename.contains("v12"))
    }
    @Test func localArtifactSmoke() async throws {
        guard #available(macOS 15, *) else { return }
        guard ProcessInfo.processInfo.environment["MUESLI_CLEANUP_V2_SMOKE"] == "1" else { return }
        let transcriber = Gemma4LiteRTTranscriber()
        for (input, context) in [
            ("thanks ill send it tomorow", "App: Mail\nDocument context: Reply body"),
            ("lets meet tuesday no wait wednesday", "App: Slack"),
            ("add a unit test for the empty input case", "App: Claude Code"),
            ("muesli download", "App: Safari\nDocument context: Search"),
            ("Hello world.", "App: TextEdit"),
            ("this is being dictated using Mueslys cleanup pipeline", "App: ChatGPT\nDocument context: Work with Codex\nOCR screen text: Codex — Integrate Gemma cleanup model v2. Muesli Cleanup v2 (Beta).")
        ] {
            let result = try await transcriber.cleanTranscript(input, systemPrompt: "IGNORED FOR FINE TUNE", appContext: context, model: .muesliCleanupV2)
            #expect(!result.text.isEmpty)
            #expect(!result.text.contains("APP-CONTEXT"))
            #expect(!result.text.contains("IGNORED FOR FINE TUNE"))
            print("V2 smoke: \(input) -> \(result.text) (\(result.processingTime)s)")
        }
        await transcriber.shutdown()
    }

}

struct ManagedCleanupV12Tests {
    @Test func rawPromptContracts() {
        let user = MuesliCleanupV2Prompt.request("hello", appContext: nil)
        #expect(MuesliCleanupV2Prompt.ggufRequest("hello", appContext: nil, format: .muesliTrainedV12LFM) == "<|startoftext|><|im_start|>user\n" + user + "<|im_end|>\n<|im_start|>assistant\n")
        #expect(MuesliCleanupV2Prompt.ggufRequest("hello", appContext: nil, format: .muesliTrainedV12Qwen) == "<|im_start|>user\n" + user + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
        #expect(MuesliCleanupV2Prompt.guardedOutput("", input: "hello") == "hello")
        #expect(MuesliCleanupV2Prompt.guardedOutput(String(repeating: "x", count: 16), input: "hello") == "hello")
        #expect(PostProcessorOption.defaultOption == .finetunedV3)
        #expect(!PostProcessorOption.lfmV12.supportsQuil)
    }

    @Test func rejectsCorruptArtifacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("model")
        try Data("bad".utf8).write(to: url)
        let descriptor = ManagedCleanupModel("test/model", "pinned", [("model", 3, String(repeating: "0", count: 64))])
        #expect(throws: (any Error).self) { try descriptor.validate(modelURL: url) }
    }

    @Test func goldenModels() async throws {
        guard #available(macOS 15, *),
              let root = ProcessInfo.processInfo.environment["MUESLI_V12_GOLDEN_ROOT"] else { return }
        struct Row: Decodable {
            let id: String
            let input_text: String
            let pred_text: String?
            let context: Context?
            struct Context: Decodable {
                let application: String
                let focused_field: String?
                let visible_screen_context: String?
                var formatted: String {
                    var parts = ["App: " + application]
                    if let value = focused_field, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("Document context: " + value) }
                    if let value = visible_screen_context, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("OCR screen text: " + value) }
                    return parts.joined(separator: "\n")
                }
            }
        }
        func rows(_ relative: String) throws -> [Row] {
            try String(contentsOfFile: root + "/" + relative).split(separator: "\n").map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        }
        func log(_ value: String) { FileHandle.standardError.write(Data((value + "\n").utf8)) }
        let smoke = [
            ("thanks ill send it tomorrow", "App: Slack"),
            ("thanks for the update new paragraph ill send the report tomorrow", "App: Gmail\nDocument context: Reply body"),
            ("update src slash auth dot swift to handle an empty token", "App: Claude Code\nOCR screen text: src/auth.swift"),
            ("lets meet tuesday no wait wednesday", "App: Slack"),
            ("muesli download", "App: Safari\nDocument context: Search box"),
            ("equals sum open parenthesis a one colon a ten close parenthesis", "App: Numbers\nDocument context: Formula cell")
        ]
        let inputs = Array(try rows("common/data/context_authored_v1/heldout.jsonl").prefix(10))
        for (option, name) in [(PostProcessorOption.lfmV12, "lfm25gguf"), (.qwenV12, "qwen35gguf_q4km")] {
            let descriptor = try #require(option.managedModel)
            try await MuesliCore.ModelDownloadCoordinator.shared.download(descriptor.manifest(id: option.id), to: option.cacheDirectory)
            let processor = Qwen3PostProcessor(modelURL: option.modelURL, systemPrompt: "ignored", inputFormat: option.inputFormat)
            let config = Qwen3PostProcessor.Configuration(modelURL: option.modelURL, systemPrompt: "ignored", inputFormat: option.inputFormat)
            try await processor.prepare()
            _ = try await processor.process("Hello world.", configuration: config)
            let expected = Dictionary(uniqueKeysWithValues: try rows("models/gemma4/eval/results/challengers/\(name)_held.jsonl").map { ($0.id, $0.pred_text ?? "") })
            var timings: [Double] = []
            for row in inputs {
                let start = Date()
                let output = try await processor.process(row.input_text, appContext: row.context?.formatted, configuration: config)
                timings.append(Date().timeIntervalSince(start))
                log("GOLDEN \(name) \(row.id) seconds=\(timings.last!) expected=\(expected[row.id] ?? "") actual=\(output)")
                #expect(output == expected[row.id])
            }
            log("GOLDEN \(name) median=\(((timings.sorted()[4] + timings.sorted()[5]) / 2))")
            var smokeTimes: [Double] = []
            for (text, context) in smoke {
                let start = Date()
                let output = try await processor.process(text, appContext: context, configuration: config)
                smokeTimes.append(Date().timeIntervalSince(start))
                log("SMOKE \(name) seconds=\(smokeTimes.last!) input=\(text) output=\(output)")
            }
            log("SMOKE \(name) median=\((smokeTimes.sorted()[2] + smokeTimes.sorted()[3]) / 2)")
            await processor.shutdown()
        }
        let gemma = Gemma4LiteRTTranscriber()
        let expected = Dictionary(uniqueKeysWithValues: try rows("models/gemma4/eval/results/litert/v12_mixed_heldout.jsonl").map { ($0.id, $0.pred_text ?? "") })
        _ = try await gemma.cleanTranscript("Hello world.", systemPrompt: "ignored", appContext: nil, model: .muesliCleanupV2)
        var timings: [Double] = []
        for row in inputs {
            let result = try await gemma.cleanTranscript(row.input_text, systemPrompt: "ignored", appContext: row.context?.formatted, model: .muesliCleanupV2)
            timings.append(result.processingTime)
            log("GOLDEN gemmalitert \(row.id) seconds=\(result.processingTime) expected=\(expected[row.id] ?? "") actual=\(result.text)")
            #expect(result.text == expected[row.id])
        }
        log("GOLDEN gemmalitert median=\(((timings.sorted()[4] + timings.sorted()[5]) / 2))")
        var smokeTimes: [Double] = []
        for (text, context) in smoke {
            let result = try await gemma.cleanTranscript(text, systemPrompt: "ignored", appContext: context, model: .muesliCleanupV2)
            smokeTimes.append(result.processingTime)
            log("SMOKE gemmalitert seconds=\(result.processingTime) input=\(text) output=\(result.text)")
        }
        log("SMOKE gemmalitert median=\((smokeTimes.sorted()[2] + smokeTimes.sorted()[3]) / 2)")
        await gemma.shutdown()
    }
}
