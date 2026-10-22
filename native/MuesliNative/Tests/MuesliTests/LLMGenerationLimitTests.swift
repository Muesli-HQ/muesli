import Foundation
import Testing
@testable import MuesliLLM
@testable import MuesliNativeApp

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
        let baseline = await bot.getCompletion(from: prompt)
        #expect(!baseline.isEmpty)
        for cap in [0, 1, 2, -1] {
            let output = await bot.getCompletion(from: prompt, maxNewTokens: cap)
            let generated = await bot.core.lastCompletionTokenCount
            #expect(generated == max(0, cap))
            if cap <= 0 { #expect(output.isEmpty) }
            else {
                #expect(!output.isEmpty)
                #expect(baseline.hasPrefix(output))
                #expect(output != baseline)
            }
        }
        let bounded = await bot.getCompletion(from: prompt, maxNewTokens: 1024)
        #expect(bounded == baseline)
        #expect(await bot.core.lastCompletionTokenCount < 1024)
        let defaultAgain = await bot.getCompletion(from: prompt)
        #expect(defaultAgain == baseline)
    }
}
