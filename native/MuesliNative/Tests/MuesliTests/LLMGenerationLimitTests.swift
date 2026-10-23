import Foundation
import Testing
@testable import MuesliLLM
@testable import MuesliNativeApp

@Suite
struct LLMGenerationLimitTests {
    @Test func limitsDecodingIndependentlyOfPromptAndResetsPerRequest() async throws {
        guard ProcessInfo.processInfo.environment["MUESLI_V12_GOLDEN_ROOT"] != nil else { return }
        let option = PostProcessorOption.lfmV12
        try ManagedCleanupModel.lfm.validate(modelURL: option.modelURL)
        let bot = try #require(LLM(from: option.modelURL, stopSequence: "<|im_end|>", seed: 7,
                                  topK: 1, topP: 1, temp: 0, repeatPenalty: 1,
                                  historyLimit: 0, maxTokenCount: 4096))
        let prompt = MuesliCleanupV2Prompt.ggufRequest(
            "Please send the full report tomorrow morning.",
            appContext: "App: Mail\nDocument context: Reply body",
            format: .muesliTrainedV12LFM)
        let promptTokens = await bot.encode(prompt)
        #expect(promptTokens.count > 2)
        let first = await bot.getCompletionResult(from: prompt)
        let baseline = first.text
        #expect(first.stopReason == .endOfSequence)
        #expect(!baseline.isEmpty)
        for cap in [0, 1, 2, -1] {
            let result = await bot.getCompletionResult(from: prompt, maxNewTokens: cap)
            let output = result.text
            #expect(result.stopReason == .tokenLimit)
            #expect(MuesliCleanupV2Prompt.guardedOutput(output, input: prompt, generationCompleted: result.stopReason == .endOfSequence) == prompt)
            let generated = await bot.core.lastCompletionTokenCount
            #expect(generated == max(0, cap))
            if cap <= 0 { #expect(output.isEmpty) }
            else {
                #expect(!output.isEmpty)
                #expect(baseline.hasPrefix(output))
                #expect(output != baseline)
            }
        }
        let complete = await bot.getCompletionResult(from: prompt, maxNewTokens: 1024)
        let bounded = complete.text
        #expect(complete.stopReason == .endOfSequence)
        #expect(bounded == baseline)
        #expect(await bot.core.lastCompletionTokenCount < 1024)
        let defaultAgain = await bot.getCompletion(from: prompt)
        #expect(defaultAgain == baseline)

        // A non-EOS stop string must be honored on the very first request.
        let stoppingBot = try #require(LLM(from: option.modelURL, stopSequence: " report", seed: 7,
            topK: 1, topP: 1, temp: 0, repeatPenalty: 1, historyLimit: 0, maxTokenCount: 4096))
        let stopped = await stoppingBot.getCompletionResult(from: prompt, maxNewTokens: 1024)
        #expect(stopped.stopReason == .endOfSequence)
        #expect(baseline.hasPrefix(stopped.text))
        #expect(stopped.text.count < baseline.count)

        let smallContext = try #require(LLM(from: option.modelURL, stopSequence: "<|im_end|>", seed: 7,
            topK: 1, topP: 1, temp: 0, repeatPenalty: 1, historyLimit: 0,
            maxTokenCount: Int32(promptTokens.count + 2)))
        let limited = await smallContext.getCompletionResult(from: prompt)
        #expect(limited.stopReason == .contextLimit)
        #expect(MuesliCleanupV2Prompt.guardedOutput(limited.text, input: prompt,
            generationCompleted: limited.stopReason == .endOfSequence) == prompt)
    }
}
