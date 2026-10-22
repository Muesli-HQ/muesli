import Foundation
import Testing
@testable import MuesliNativeApp

struct CleanupFormattingReplayTests {
    @Test func replay() async throws {
        guard #available(macOS 15, *), let path = ProcessInfo.processInfo.environment["MUESLI_FORMATTING_REPLAY"] else { return }
        struct Row: Decodable { let rawASRText: String; let appContextText: String }
        let rows = try String(contentsOfFile: path).split(separator: "\n").map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }.suffix(4)
        func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
        for option in [PostProcessorOption.lfmV12, .qwenV12] {
            let processor = Qwen3PostProcessor(modelURL: option.modelURL, systemPrompt: "ignored", inputFormat: option.inputFormat)
            let config = Qwen3PostProcessor.Configuration(modelURL: option.modelURL, systemPrompt: "ignored", inputFormat: option.inputFormat)
            try await processor.prepare()
            _ = try await processor.process("Hello world.", configuration: config)
            for row in rows {
                log("REPLAY model=\(option.id) input=\(String(reflecting: row.rawASRText))")
                let result = try await processor.processResult(row.rawASRText, appContext: row.appContextText, configuration: config)
                #expect(result.text == MuesliCleanupV2Prompt.guardedOutput(result.rawOutput, input: row.rawASRText))
                log("REPLAY result raw=\(String(reflecting: result.rawOutput)) final=\(String(reflecting: result.text))")
            }
            await processor.shutdown()
        }
        let gemma = Gemma4LiteRTTranscriber()
        _ = try await gemma.cleanTranscript("Hello world.", systemPrompt: "ignored", appContext: nil, model: .muesliCleanupV2)
        for row in rows {
            let result = try await gemma.cleanTranscript(row.rawASRText, systemPrompt: "ignored", appContext: row.appContextText, model: .muesliCleanupV2)
            log("REPLAY gemma exact user message=\(String(reflecting: MuesliCleanupV2Prompt.request(row.rawASRText, appContext: row.appContextText)))")
            log("REPLAY gemma raw=\(String(reflecting: result.rawOutput)) final=\(String(reflecting: result.text))")
        }
        await gemma.shutdown()
        for value in ["- Latency\n- Formatting", "- Latency\n\n- Formatting", "- Latency\n  - Formatting"] {
            log("CLEANER input=\(String(reflecting: value)) output=\(String(reflecting: TranscriptCleanupClient.cleanOutput(value)))")
        }
    }
}
