import Foundation

/// Inference contract for the v12 fine-tune (same prompt contract as v10). Keep aligned with its training manifest.
enum MuesliCleanupV2Prompt {
    static let systemPrompt = """
    Clean up speech-to-text transcription. Only make changes when there is a clear error. If the text is already correct, output it exactly as-is.
    
    The user input may include an <APP-CONTEXT> section with focused app, document, URL, selected text, or OCR screen text. Use it only to resolve obvious transcription errors, names, acronyms, and formatting intent. Never copy app context into the output unless the user dictated it.
    
    You may: fix obvious misspellings, remove filler words (um, uh, like), apply 'scratch that' deletions, and format numbered or bullet lists when dictated.
    
    Do not: paraphrase, reword, add words, remove meaningful words, change the meaning in any way, wrap the output in markdown, code fences, tags, labels, or commentary, or repeat the output more than once. Preserve the speaker's original phrasing.
    """

    static func request(_ text: String, appContext: String?) -> String {
        var context = ""
        let appContext = appContext?.components(separatedBy: "\n").filter { line in
            !["Document context:", "OCR screen text:"].contains(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }.joined(separator: "\n")
        if let appContext, !appContext.isEmpty {
            context = "<APP-CONTEXT>\n\(String(appContext.prefix(1_200)))\n</APP-CONTEXT>\n\n"
        }
        return systemPrompt + "\n\n" + context + text
    }

    static func ggufRequest(_ text: String, appContext: String?, format: PostProcessorOption.InputFormat) -> String {
        let userText = request(text, appContext: appContext)
        let prefix = format == .muesliTrainedV12LFM ? "<|startoftext|>" : ""
        let suffix = format == .muesliTrainedV12Qwen ? "<think>\n\n</think>\n\n" : ""
        return prefix + "<|im_start|>user\n" + userText + "<|im_end|>\n<|im_start|>assistant\n" + suffix
    }

    struct GuardedOutput {
        let text: String
        let didFallback: Bool
    }

    static func guardedOutput(_ output: String, input: String, generationCompleted: Bool = true) -> String {
        guardResult(output, input: input, generationCompleted: generationCompleted).text
    }

    static func guardResult(_ output: String, input: String, generationCompleted: Bool = true) -> GuardedOutput {
        let cleaned = TranscriptCleanupClient.cleanOutput(cleanOutput(output, input: input))
        let rejected = !generationCompleted || cleaned.isEmpty || cleaned.count > input.count * 3
            || Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(cleaned: cleaned, input: input)
        return GuardedOutput(text: rejected ? input : cleaned, didFallback: rejected)
    }

    static func cleanOutput(_ output: String, input: String = "") -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // A dictated opening word is content, even when formatting puts it on its own line.
        let inputStartsWithModel = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^model\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        // Only strip exact leading markers or verbatim training instructions.
        let paragraphs = systemPrompt.components(separatedBy: "\n\n").filter { $0.count >= 30 }
        while !text.isEmpty {
            let previous = text
            if !inputStartsWithModel {
                if text == "model" { text = "" }
                else if text.hasPrefix("model\n") { text = String(text.dropFirst(6)) }
            }
            for marker in ["</APP-CONTEXT>", "<APP-CONTEXT>"] where text.hasPrefix(marker) {
                text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for paragraph in paragraphs where text == paragraph || text.hasPrefix(paragraph + "\n") {
                text = String(text.dropFirst(paragraph.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == previous { break }
        }
        return text
    }
}
