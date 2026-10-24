import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite
struct MuesliCleanupV2Tests {
    @Test func truncatedOutputPreservesEntireTranscript() {
        let input = "First send the report. Then email the customer. Finally archive the results."
        #expect(MuesliCleanupV2Prompt.guardedOutput("First send the report.", input: input, generationCompleted: false) == input)
        #expect(MuesliCleanupV2Prompt.guardResult("First send the report.", input: input, generationCompleted: false).didFallback)
        #expect(MuesliCleanupV2Prompt.guardResult("", input: input).didFallback)
        #expect(!MuesliCleanupV2Prompt.guardResult(input, input: input).didFallback)
    }

    @Test func blankCleanupOverridesUseManagedCache() {
        let model = Gemma4LiteRTModel.muesliCleanupV2
        for path in ["", "  ", "\n\t"] {
            let environment = ["MUESLI_CLEANUP_V2_MODEL_PATH": path]
            #expect(Gemma4LiteRTModelStore.cleanupOverrideURL(environment: environment) == nil)
            #expect(Gemma4LiteRTModelStore.resolvedModelURL(for: model, environment: environment) == Gemma4LiteRTModelStore.managedModelURL(for: model))
        }
        #expect(Gemma4LiteRTModelStore.cleanupOverrideURL(environment: ["MUESLI_CLEANUP_V2_MODEL_PATH": " /tmp/model "]) == URL(fileURLWithPath: "/tmp/model"))
    }

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
    @Test func preservesDictatedOpeningModelLine() {
        for input in ["model training is useful", "Model training is useful", "  model\ntraining is useful"] {
            let result = MuesliCleanupV2Prompt.guardResult("model\ntraining is useful", input: input)
            #expect(result.text == "model\ntraining is useful")
            #expect(!result.didFallback)
        }
        #expect(MuesliCleanupV2Prompt.guardResult("model", input: "model").text == "model")
        #expect(!MuesliCleanupV2Prompt.guardResult("model", input: "model").didFallback)
        #expect(MuesliCleanupV2Prompt.cleanOutput("model\nHello", input: "Hello") == "Hello")
        #expect(MuesliCleanupV2Prompt.cleanOutput("model\nModeling is useful", input: "Modeling is useful") == "Modeling is useful")
    }

    @Test func preservesSpacesBeforeRelativePaths() {
        for text in ["git worktree add ../hotfix-4.2 origin/release/4.2", "open .config", "run ./script", "set the value to .5"] {
            #expect(Qwen3PostProcessorOutputCleaner.clean(text) == text)
            #expect(TranscriptCleanupClient.cleanOutput(text) == text)
        }
        #expect(TranscriptCleanupClient.cleanOutput("Hello , world .") == "Hello, world.")
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

@Suite
struct ManagedCleanupV12Tests {
    @Test func warmupSkipsUnloadedEngine() async {
        guard #available(macOS 15, *) else { return }
        let transcriber = Gemma4LiteRTTranscriber()
        let ran = await transcriber.warmUpCleanupIfIdle(requestedAt: ProcessInfo.processInfo.systemUptime)
        #expect(!ran)
    }

    @Test func gemmaLongIdleWarmup() async throws {
        guard #available(macOS 15, *),
              let fixturePath = ProcessInfo.processInfo.environment["MUESLI_LATENCY_FIXTURE"],
              let reportPath = ProcessInfo.processInfo.environment["MUESLI_IDLE_REPORT"] else { return }
        struct Fixture: Decodable {
            let rawASRText: String
            let appContextText: String?
            let cleanupOutputText: String
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
        let inputs = [fixture.rawASRText,
                      "Put this in bullet points. First send the report tomorrow. Second check the formatting. Third compare the latency.",
                      "Make a numbered list. First open the settings. Second select the cleanup model. Third test the output."]
        let transcriber = Gemma4LiteRTTranscriber()
        var baseline: [String] = []
        var rows: [[String: Any]] = []
        for input in inputs {
            let result = try await transcriber.cleanTranscript(input, systemPrompt: "",
                appContext: fixture.appContextText, model: .muesliCleanupV2)
            baseline.append(result.text)
            #expect(!result.didFallback)
        }
        #expect(baseline[0] == fixture.cleanupOutputText)
        let recent = await transcriber.warmUpCleanupIfIdle(requestedAt: ProcessInfo.processInfo.systemUptime)
        #expect(!recent)
        Gemma4LiteRTLogging.profile("idle_test waiting_seconds=180")
        try await Task.sleep(for: .seconds(180))
        let expired = await transcriber.warmUpCleanupIfIdle(requestedAt: ProcessInfo.processInfo.systemUptime - 3)
        #expect(!expired)
        let cancelledTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await transcriber.warmUpCleanupIfIdle(requestedAt: ProcessInfo.processInfo.systemUptime)
        }
        let cancelled = await cancelledTask.value
        #expect(!cancelled)
        let warmStart = ProcessInfo.processInfo.systemUptime
        let ran = await transcriber.warmUpCleanupIfIdle(requestedAt: warmStart)
        #expect(ran)
        let warmSeconds = ProcessInfo.processInfo.systemUptime - warmStart
        let duplicate = await transcriber.warmUpCleanupIfIdle(requestedAt: ProcessInfo.processInfo.systemUptime)
        #expect(!duplicate)
        try await Task.sleep(for: .seconds(15))
        for (index, input) in inputs.enumerated() {
            let result = try await transcriber.cleanTranscript(input, systemPrompt: "",
                appContext: fixture.appContextText, model: .muesliCleanupV2)
            #expect(!result.didFallback)
            #expect(result.text == baseline[index])
            #expect(result.rawOutput == result.text)
            rows.append(["index": index, "seconds": result.processingTime, "output": result.text,
                         "baseline": baseline[index], "warmupSeconds": warmSeconds])
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: reportPath))
        await transcriber.shutdown()
    }

    /// Private fixture is a cleanup debug log row, kept outside the repository.
    @Test func gemmaLatencyInvestigation() async throws {
        guard #available(macOS 15, *),
              let fixturePath = ProcessInfo.processInfo.environment["MUESLI_LATENCY_FIXTURE"],
              let reportPath = ProcessInfo.processInfo.environment["MUESLI_LATENCY_REPORT"] else { return }
        struct Fixture: Decodable {
            let rawASRText: String
            let appContextText: String?
            let cleanupOutputText: String
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
        var rows: [[String: Any]] = []
        let warmupExperiment = ProcessInfo.processInfo.environment["MUESLI_LATENCY_WARMUP"] == "1"
        for (label, contextTokens, context) in [
            ("full_4096", Int32(4096), fixture.appContextText),
            ("full_2048", Int32(2048), fixture.appContextText),
            ("app_only_4096", Int32(4096), Optional("App: ChatGPT")),
            ("full_4096_repeat", Int32(4096), fixture.appContextText)
        ] {
            if warmupExperiment && label != "full_4096" { continue }
            let transcriber = Gemma4LiteRTTranscriber()
            if warmupExperiment {
                Gemma4LiteRTLogging.profile("experiment warmup=unrelated_short_input")
                _ = try await transcriber.cleanTranscript("The meeting starts tomorrow morning.",
                    systemPrompt: "", appContext: "App: Notes", model: .muesliCleanupV2)
            }
            for iteration in 0..<4 {
                if warmupExperiment && iteration == 2 {
                    try await Task.sleep(for: .seconds(15))
                }
                Gemma4LiteRTLogging.profile("experiment variant=\(label) iteration=\(iteration)")
                let result = try await transcriber.cleanTranscript(fixture.rawASRText,
                    systemPrompt: "", appContext: context, model: .muesliCleanupV2, contextTokens: contextTokens)
                rows.append(["variant": label, "iteration": iteration, "generationSeconds": result.processingTime,
                             "output": result.text, "rawOutput": result.rawOutput, "fallback": result.didFallback,
                             "matchesRecordedOutput": result.text == fixture.cleanupOutputText])
                #expect(!result.didFallback)
            }
            await transcriber.shutdown()
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: reportPath))
    }

    /// Diagnostic replay of stored final text, not a reconstruction of the missing ASR/OCR logs.
    @Test func gemmaBulletDiagnosticReplay() async throws {
        guard #available(macOS 15, *),
              let report = ProcessInfo.processInfo.environment["MUESLI_BULLET_REPLAY_REPORT"] else { return }
        let original = "I am trying to use the cleanup mode with formatting. First, is latency if multiple token prediction is switched on, how does it work? Second, does it stick to the bullet formatting or not? Third, overall, can it combine both these behaviors into one?"
        let transcriber = Gemma4LiteRTTranscriber()
        var rows: [[String: Any]] = []
        for input in [original, "Put this in bullet points. " + original] {
            let result = try await transcriber.cleanTranscript(input, systemPrompt: "",
                appContext: "App: Codex", model: .muesliCleanupV2)
            rows.append(["input": input, "prompt": MuesliCleanupV2Prompt.request(input, appContext: "App: Codex"),
                         "rawOutput": result.rawOutput, "output": result.text,
                         "fallback": result.didFallback, "generationSeconds": result.processingTime])
            #expect(!result.didFallback)
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: report))
        await transcriber.shutdown()
    }

    /// Run in separate processes with MUESLI_GEMMA_MLX_MTP=1 and =0.
    @Test func gemmaLongDictationTiming() async throws {
        guard #available(macOS 15, *),
              let root = ProcessInfo.processInfo.environment["MUESLI_V12_GOLDEN_ROOT"],
              let report = ProcessInfo.processInfo.environment["MUESLI_MTP_TIMING_REPORT"] else { return }
        struct Row: Decodable {
            let id: String
            let input_text: String
            let target_text: String
            let context: [String: String]?
            var appContext: String? {
                guard let context else { return nil }
                return [("application", "App"), ("focused_field", "Document context"), ("visible_screen_context", "OCR screen text")]
                    .compactMap { key, label in
                        guard let value = context[key], !value.isEmpty else { return nil }
                        return label + ": " + value
                    }.joined(separator: "\n")
            }
        }
        let rows = try ["heldout_coverage_v1", "heldout_coverage_ember1"].flatMap { dataset in
            try String(contentsOfFile: root + "/models/gemma4/data/\(dataset)/test.jsonl")
                .split(separator: "\n").map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        }.sorted { $0.target_text.count > $1.target_text.count }.prefix(5)
        let transcriber = Gemma4LiteRTTranscriber()
        _ = try await transcriber.cleanTranscript("Hello world.", systemPrompt: "", appContext: nil, model: .muesliCleanupV2)
        var results: [[String: Any]] = []
        for row in rows {
            let start = Date()
            let result = try await transcriber.cleanTranscript(row.input_text, systemPrompt: "", appContext: row.appContext, model: .muesliCleanupV2)
            let wallSeconds = Date().timeIntervalSince(start)
            results.append(["id": row.id, "seconds": wallSeconds, "generationSeconds": result.processingTime,
                            "rawOutput": result.rawOutput, "output": result.text, "didFallback": result.didFallback])
            #expect(!result.didFallback)
            FileHandle.standardError.write(Data("MTP_LONG id=\(row.id) seconds=\(wallSeconds) fallback=\(result.didFallback)\n".utf8))
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: report))
        await transcriber.shutdown()
    }

    @Test func gemmaLimitPreservesOriginalTranscript() async throws {
        guard #available(macOS 15, *),
              ProcessInfo.processInfo.environment["MUESLI_V12_GOLDEN_ROOT"] != nil else { return }
        let transcriber = Gemma4LiteRTTranscriber()
        let input = "First send the report tomorrow morning. Then email the customer and archive the results."
        let capped = try await transcriber.cleanTranscript(input, systemPrompt: "", appContext: nil,
            model: .muesliCleanupV2, maxOutputTokens: 1)
        #expect(capped.didFallback)
        #expect(capped.text == input)
        #expect(capped.rawOutput != input)
        let completed = try await transcriber.cleanTranscript(input, systemPrompt: "", appContext: nil,
            model: .muesliCleanupV2)
        #expect(!completed.didFallback)
        #expect(!completed.text.isEmpty)
        await transcriber.shutdown()
    }

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
        for (option, name) in [(PostProcessorOption.lfmV12, "lfm25gguf"), (.qwenV12, "qwen35gguf_q4km")]
            where ProcessInfo.processInfo.environment["MUESLI_V12_GEMMA_ONLY"] != "1" {
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
        let expected = Dictionary(uniqueKeysWithValues: try rows("models/gemma4/eval/results/litert/v12gpu_mtp_held.jsonl").map { ($0.id, $0.pred_text ?? "") })
        let gemmaInputs = try rows("common/data/context_authored_v1/heldout.jsonl")
        _ = try await gemma.cleanTranscript("Hello world.", systemPrompt: "ignored", appContext: nil, model: .muesliCleanupV2)
        var timings: [Double] = []
        var exactMatches = 0
        for row in gemmaInputs {
            let result = try await gemma.cleanTranscript(row.input_text, systemPrompt: "ignored", appContext: row.context?.formatted, model: .muesliCleanupV2)
            timings.append(result.processingTime)
            log("GOLDEN gemmalitert \(row.id) seconds=\(result.processingTime) expected=\(expected[row.id] ?? "") actual=\(result.text) raw=\(result.rawOutput)")
            if result.text == expected[row.id] { exactMatches += 1 }
        }
        // The MTP reference permits occasional GPU rounding differences (updated v12 spec).
        #expect(gemmaInputs.count == 400)
        #expect(Double(exactMatches) / Double(gemmaInputs.count) >= 0.96)
        let middle = timings.count / 2
        log("GOLDEN gemmalitert exact=\(exactMatches)/\(gemmaInputs.count) median=\(((timings.sorted()[middle - 1] + timings.sorted()[middle]) / 2))")
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
