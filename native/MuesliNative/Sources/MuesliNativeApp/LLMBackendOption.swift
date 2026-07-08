import Foundation

struct LLMBackendOption: Equatable, Identifiable {
    let backend: String
    let label: String

    var id: String { backend }

    static let chatGPT = LLMBackendOption(backend: "chatgpt", label: "ChatGPT")
    static let openAI = LLMBackendOption(backend: "openai", label: "OpenAI")
    static let openRouter = LLMBackendOption(backend: "openrouter", label: "OpenRouter")
    static let ollama = LLMBackendOption(backend: "ollama", label: "Ollama")
    static let lmStudio = LLMBackendOption(backend: "lmstudio", label: "LM Studio")
    static let customLLM = LLMBackendOption(backend: "custom_llm", label: "Custom LLM")

    static let all: [LLMBackendOption] = [.chatGPT, .openAI, .openRouter, .ollama, .lmStudio, .customLLM]

    static func resolved(_ backend: String?) -> LLMBackendOption? {
        guard let backend else { return nil }
        return all.first { $0.backend == backend }
    }
}

struct TranscriptCleanupBackendOption: Equatable, Identifiable {
    let backend: String
    let label: String
    let llmBackend: LLMBackendOption?

    var id: String { backend }
    var isLocal: Bool { llmBackend == nil }

    static let local = TranscriptCleanupBackendOption(
        backend: "local",
        label: "Local Model",
        llmBackend: nil
    )

    static func hosted(_ option: LLMBackendOption) -> TranscriptCleanupBackendOption {
        TranscriptCleanupBackendOption(
            backend: option.backend,
            label: option.label,
            llmBackend: option
        )
    }

    static let all: [TranscriptCleanupBackendOption] = [.local] + LLMBackendOption.all.map(hosted)

    static func resolved(_ backend: String?) -> TranscriptCleanupBackendOption {
        guard let backend, let option = all.first(where: { $0.backend == backend }) else {
            return .local
        }
        return option
    }
}
