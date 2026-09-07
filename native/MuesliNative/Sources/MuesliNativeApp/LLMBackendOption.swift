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
    var isLocal: Bool { self == .local }
    var isGemma4LiteRT: Bool { self == .gemma4LiteRT }
    var isOnDevice: Bool { isLocal || isGemma4LiteRT }

    static let local = TranscriptCleanupBackendOption(
        backend: "local",
        label: "Local Model",
        llmBackend: nil
    )

    static let gemma4LiteRT = TranscriptCleanupBackendOption(
        backend: "gemma4-litert",
        label: "Gemma 4",
        llmBackend: nil
    )

    static func hosted(_ option: LLMBackendOption) -> TranscriptCleanupBackendOption {
        TranscriptCleanupBackendOption(
            backend: option.backend,
            label: option.label,
            llmBackend: option
        )
    }

    static let all: [TranscriptCleanupBackendOption] = [.local, .gemma4LiteRT] + LLMBackendOption.all.map(hosted)

    func isCompatible(with transcriptionBackend: BackendOption) -> Bool {
        !(isGemma4LiteRT && transcriptionBackend.backend == BackendOption.gemma4E2BLiteRT.backend)
    }

    static func available(for transcriptionBackend: BackendOption) -> [TranscriptCleanupBackendOption] {
        all.filter { $0.isCompatible(with: transcriptionBackend) }
    }

    static func resolved(_ backend: String?) -> TranscriptCleanupBackendOption {
        guard let backend, let option = all.first(where: { $0.backend == backend }) else {
            return .local
        }
        return option
    }
}

struct QuilModelSourceOption: Equatable, Identifiable {
    let id: String
    let label: String
    let hostedBackend: TranscriptCleanupBackendOption?

    static let localModels = QuilModelSourceOption(
        id: "local-models",
        label: "Local Models",
        hostedBackend: nil
    )

    static let hosted: [QuilModelSourceOption] = LLMBackendOption.all.map { option in
        QuilModelSourceOption(
            id: option.backend,
            label: option.label,
            hostedBackend: .hosted(option)
        )
    }

    static let all: [QuilModelSourceOption] = [.localModels] + hosted

    static func resolved(for backend: TranscriptCleanupBackendOption) -> QuilModelSourceOption {
        guard !backend.isOnDevice else { return .localModels }
        return hosted.first(where: { $0.hostedBackend == backend }) ?? .localModels
    }
}
