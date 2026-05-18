import Foundation

/// Comprehensive static map of vendor-documented maximum output-token limits.
///
/// Sources:
/// - OpenAI: platform.openai.com/docs/models (May 2026)
/// - Anthropic: docs.anthropic.com/en/docs/about-claude/models (May 2026)
/// - Google Gemini: ai.google.dev/gemini-api/docs/models
/// - Meta Llama: github.com/meta-llama/llama-models
/// - OpenRouter API: openrouter.ai/api/v1/models
/// - Ollama / GGUF community knowledge for open-weight models
enum ModelTokenCap {

    /// Lookup max output tokens by normalized model identifier.
    ///
    /// - If the exact ID is known (incl. dated snapshots), returns that cap.
    /// - If the exact ID is not found, strips the `:tag` or dated suffix and
    ///   tries again against known base models.
    static func maxOutputTokens(forModelID modelID: String) -> Int? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Exact match first
        if let exact = exactMap[trimmed] {
            return exact
        }

        // Normalize: remove provider prefixes ("anthropic/", "openai/", etc.)
        let normalized = normalize(modelID: trimmed)

        // Strip qualifiers (:latest, :free, dated snapshots, quantization tags)
        let base = stripTag(from: normalized)
        if let baseCap = exactMap[base] ?? exactMap[normalized] {
            return baseCap
        }

        // Vendor-specific fallback families
        if normalized.contains("claude-opus") { return 128_000 }
        if normalized.contains("claude-sonnet") { return 64_000 }
        if normalized.contains("claude-haiku") { return 64_000 }
        if normalized.contains("gpt-5.5") { return 128_000 }
        if normalized.contains("gpt-5.4") { return 128_000 }
        if normalized.contains("gpt-5") { return 64_000 }
        if normalized.contains("gpt-4o") { return 16_384 }
        if normalized.contains("o1") || normalized.contains("o3") { return 100_000 }
        if normalized.contains("gemini") { return 8_192 }
        if normalized.contains("llama-4-") { return 1_000_000 }
        if normalized.contains("llama-3.1-") || normalized.contains("llama3.1") { return 128_000 }
        if normalized.contains("llama-3-") || normalized.contains("llama3") { return 8_192 }
        if normalized.contains("qwen3") { return 128_000 }
        if normalized.contains("qwen2.5") { return 128_000 }
        if normalized.contains("qwen2") { return 128_000 }
        if normalized.contains("deepseek-v3") { return 8_192 }
        if normalized.contains("deepseek-coder") { return 128_000 }
        if normalized.contains("deepseek-v2") { return 128_000 }
        if normalized.contains("mistral-large") { return 128_000 }
        if normalized.contains("mixtral") { return 65_536 }
        if normalized.contains("phi-4") { return 128_000 }
        if normalized.contains("phi-3") { return 128_000 }
        if normalized.contains("command-r") { return 128_000 }
        if normalized.contains("yi-34b") { return 200_000 }
        if normalized.contains("yi-large") { return 32_768 }
        if normalized.contains("grok-4") { return 2_000_000 }

        return nil
    }

    /// Total context length for local models (used when we don't know the
    /// vendor-enforced output cap, e.g. for Ollama or LM Studio).
    static func contextLengthHint(forModelID modelID: String) -> Int? {
        // Many open models default to their training context.  Use the same
        // heuristic as `maxOutputTokens` but fall back to general families.
        let normalized = normalize(modelID: modelID)
        if normalized.contains("llama-4-scout") || normalized.contains("llama4scout") { return 10_000_000 }
        if normalized.contains("llama-4-maverick") || normalized.contains("llama4maverick") { return 1_000_000 }
        if normalized.contains("llama-4-") || normalized.contains("llama4") { return 1_000_000 }
        if normalized.contains("llama-3.1-") || normalized.contains("llama3.1") { return 128_000 }
        if normalized.contains("llama-3-") || normalized.contains("llama3") { return 8_192 }
        if normalized.contains("qwen3") { return 128_000 }
        if normalized.contains("qwen2.5") { return 128_000 }
        if normalized.contains("qwen2") { return 128_000 }
        if normalized.contains("deepseek-v3") { return 64_000 }
        if normalized.contains("deepseek-coder-v2") { return 128_000 }
        if normalized.contains("deepseek-v2") { return 128_000 }
        if normalized.contains("mistral-large") { return 128_000 }
        if normalized.contains("mixtral-8x22b") { return 65_536 }
        if normalized.contains("mixtral-8x7b") { return 32_768 }
        if normalized.contains("phi-4") { return 128_000 }
        if normalized.contains("phi-3") { return 128_000 }
        if normalized.contains("command-r") { return 128_000 }
        if normalized.contains("yi-34b") { return 200_000 }
        if normalized.contains("yi-large") { return 32_768 }
        if normalized.contains("gemma-2") { return 8_192 }
        if normalized.contains("gemma") { return 8_192 }
        return nil
    }

    // MARK: - Private helpers

    private static func normalize(modelID: String) -> String {
        var s = modelID.lowercased()
        // Strip common provider prefixes used by OpenRouter / LiteLLM
        let prefixes = [
            "anthropic/", "openai/", "google/", "meta-llama/",
            "mistralai/", "cohere/", "x-ai/", "deepseek/",
            "microsoft/", "nvidia/", "qwen/", "01-ai/",
            "openrouter/", "perplexity/", "fireworks/",
        ]
        for p in prefixes {
            if s.hasPrefix(p) {
                s.removeFirst(p.count)
                break
            }
        }
        return s
    }

    private static func stripTag(from modelID: String) -> String {
        let parts = modelID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        return String(parts[0])
    }

    // MARK: - Exact vendor-documented caps

    private static let exactMap: [String: Int] = [
        // OpenAI 2026-05
        "gpt-5.5": 128_000,
        "gpt-5.5-2026-05-07": 128_000,
        "gpt-5.5-pro": 128_000,
        "gpt-5.4": 128_000,
        "gpt-5.4-2026-05-07": 128_000,
        "gpt-5.4-pro": 128_000,
        "gpt-5.4-mini": 128_000,
        "gpt-5.4-nano": 64_000,
        "gpt-5.2": 128_000,
        "gpt-5.2-2026-05-07": 128_000,
        "gpt-5-mini": 64_000,

        // OpenAI legacy
        "gpt-4o": 16_384,
        "gpt-4o-2024-11-20": 16_384,
        "gpt-4o-2024-08-06": 16_384,
        "gpt-4o-mini": 16_384,
        "gpt-4o-mini-2024-07-18": 16_384,
        "o1": 100_000,
        "o1-2024-12-17": 100_000,
        "o1-mini": 65_000,
        "o1-mini-2024-09-12": 65_000,
        "o3-mini": 65_000,
        "gpt-4-turbo": 4_096,
        "gpt-4": 8_192,
        "gpt-4-0613": 8_192,
        "gpt-3.5-turbo": 4_096,
        "gpt-3.5-turbo-0125": 4_096,

        // Anthropic Claude 4
        "claude-opus-4-7-2026-05-05": 128_000,
        "claude-opus-4-7": 128_000,
        "claude-opus-4-6-2026-03-24": 128_000,
        "claude-opus-4-6": 128_000,
        "claude-sonnet-4-6-2026-03-24": 64_000,
        "claude-sonnet-4-6": 64_000,
        "claude-haiku-4-5-20251001": 64_000,
        "claude-haiku-4-5": 64_000,

        // Anthropic legacy
        "claude-opus-4-5-20251101": 64_000,
        "claude-opus-4-5": 64_000,
        "claude-opus-4-1-20250805": 32_000,
        "claude-opus-4-1": 32_000,
        "claude-sonnet-4-5-20250929": 64_000,
        "claude-sonnet-4-5": 64_000,

        // Google Gemini
        "gemini-3.1-pro": 8_192,
        "gemini-3.1-flash": 8_192,
        "gemini-3.1-flash-lite": 8_192,
        "gemini-2.5-pro": 8_192,
        "gemini-2.5-pro-preview": 8_192,
        "gemini-2.5-flash": 8_192,
        "gemini-2.5-flash-preview": 8_192,
        "gemini-2.0-flash": 8_192,
        "gemini-2.0-flash-001": 8_192,
        "gemini-2.0-flash-lite": 8_192,
        "gemini-2.0-pro": 8_192,
        "gemini-1.5-pro": 8_192,
        "gemini-1.5-pro-002": 8_192,
        "gemini-1.5-flash": 8_192,
        "gemini-1.5-flash-002": 8_192,
        "gemini-1.5-flash-8b": 8_192,
        "gemini-1.0-pro": 2_048,

        // Meta Llama 4 / 3.1 / 3
        "llama-4-scout-17b-16e-instruct": 10_000_000,
        "llama-4-scout-17b-128e-instruct": 10_000_000,
        "llama-4-scout": 10_000_000,
        "llama-4-maverick-17b-128e-instruct": 1_000_000,
        "llama-4-maverick": 1_000_000,
        "llama-4": 1_000_000,
        "llama-3.1-8b-instruct": 128_000,
        "llama-3.1-70b-instruct": 128_000,
        "llama-3.1-405b-instruct": 128_000,
        "llama-3.1-8b": 128_000,
        "llama-3.1-70b": 128_000,
        "llama-3.1-405b": 128_000,
        "llama-3-8b-instruct": 8_192,
        "llama-3-70b-instruct": 8_192,
        "llama-3-8b": 8_192,
        "llama-3-70b": 8_192,

        // Qwen
        "qwen3-235b-a22b-instruct": 128_000,
        "qwen3-235b": 128_000,
        "qwen3-30b-a3b-instruct": 128_000,
        "qwen3-8b-instruct": 128_000,
        "qwen3-4b-instruct": 128_000,
        "qwen3-1.7b-instruct": 128_000,
        "qwen3-0.6b-instruct": 128_000,
        "qwen2.5-72b-instruct": 128_000,
        "qwen2.5-32b-instruct": 128_000,
        "qwen2.5-14b-instruct": 128_000,
        "qwen2.5-7b-instruct": 128_000,
        "qwen2.5-3b-instruct": 128_000,
        "qwen2.5-1.5b-instruct": 128_000,
        "qwen2.5-0.5b-instruct": 128_000,
        "qwen2.5": 128_000,
        "qwen2-72b-instruct": 128_000,
        "qwen2-7b-instruct": 128_000,
        "qwen2-1.5b-instruct": 128_000,
        "qwen2": 128_000,

        // Mistral
        "mistral-large-2411": 128_000,
        "mistral-large": 128_000,
        "mixtral-8x22b-instruct": 65_536,
        "mixtral-8x7b-instruct": 32_768,
        "mixtral-8x22b": 65_536,
        "mixtral-8x7b": 32_768,

        // DeepSeek
        "deepseek-v3": 8_192,
        "deepseek-v3-0324": 8_192,
        "deepseek-coder-v2-236b": 128_000,
        "deepseek-coder-v2": 128_000,
        "deepseek-v2-236b": 128_000,
        "deepseek-v2": 128_000,

        // Phi
        "phi-4": 128_000,
        "phi-3.5-mini-instruct": 128_000,
        "phi-3-medium-128k-instruct": 128_000,
        "phi-3-mini-128k-instruct": 128_000,
        "phi-3-small-128k-instruct": 128_000,
        "phi-3": 128_000,

        // Cohere
        "command-r-08-2024": 128_000,
        "command-r-plus-08-2024": 128_000,
        "command-r": 128_000,
        "command-r-plus": 128_000,

        // Yi
        "yi-34b-200k": 200_000,
        "yi-34b": 200_000,
        "yi-large": 32_768,

        // Grok
        "grok-4": 2_000_000,
        "grok-4.1": 2_000_000,
        "grok-4.3": 1_000_000,
        "grok-4.20": 2_000_000,
        "grok-4.20-reasoning": 2_000_000,

        // Stepfun (OpenRouter preset)
        "stepfun/step-3.5-flash:free": 128_000,
        "step-3.5-flash:free": 128_000,
        "step-3.5-flash": 128_000,
    ]
}
