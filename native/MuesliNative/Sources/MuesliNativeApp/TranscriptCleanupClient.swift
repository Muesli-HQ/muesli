import Foundation

enum TranscriptCleanupError: LocalizedError {
    case rejectedOutput

    var errorDescription: String? {
        switch self {
        case .rejectedOutput:
            return "Transcript cleanup output was rejected by safety checks."
        }
    }
}

struct TranscriptCleanupResult {
    let rawOutput: String
    let cleanedOutput: String
}

enum TranscriptCleanupClient {
    static let defaultChatGPTModel = "gpt-5.4-mini"

    static func resolvedChatGPTModel(_ configuredModel: String) -> String {
        let trimmed = configuredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultChatGPTModel : trimmed
    }

    static func cleanWithChatGPT(
        text: String,
        systemPrompt: String,
        appContext: String?,
        model: String
    ) async throws -> TranscriptCleanupResult {
        let raw = try await ChatGPTResponsesClient.respond(
            systemPrompt: systemPrompt,
            userPrompt: Qwen3PostProcessorConfig.formatInput(text, appContext: appContext),
            model: resolvedChatGPTModel(model),
            logCategory: "postproc"
        )
        let cleaned = cleanChatGPTOutput(raw)
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, Qwen3DeletionCueDetector.containsDeletionCue(text) {
            return TranscriptCleanupResult(rawOutput: raw, cleanedOutput: trimmed)
        }
        if Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(cleaned: trimmed, input: text) {
            throw TranscriptCleanupError.rejectedOutput
        }
        return TranscriptCleanupResult(rawOutput: raw, cleanedOutput: trimmed)
    }

    static func cleanChatGPTOutput(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text
        result = result.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?is)<think\b[^>]*>[\s\S]*$"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"<\|im_(?:start|end)\|>"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"```[A-Za-z0-9_-]*\s*"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"```"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"^`+|`+$"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\[end of text\]"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?im)^\s*(?:[#>*-]+\s*)?(?:\*\*|__)?(?:transcription|cleaned transcription|output|response)(?:\*\*|__)?\s*:\s*"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\r\n?"#,
            with: "\n",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"[ \t]+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?m)[ \t]+$"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"[ \t]*\n[ \t]*"#,
            with: "\n",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return stripBalancedWrappingQuotes(result)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripBalancedWrappingQuotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs = [
            ("\"", "\""),
            ("\u{201C}", "\u{201D}"),
        ]

        for (open, close) in pairs where trimmed.hasPrefix(open) && trimmed.hasSuffix(close) {
            let start = trimmed.index(trimmed.startIndex, offsetBy: open.count)
            let end = trimmed.index(trimmed.endIndex, offsetBy: -close.count)
            guard start < end else { return trimmed }
            let body = String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? trimmed : body
        }

        return trimmed
    }
}
