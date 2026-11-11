import Foundation
import MuesliCore

extension AnalyticsModel {
    /// These are code-owned catalogs only, never installed files or downloaded
    /// provider catalogs. Unknown/custom names are discarded, not hashed.
    private static let providers: Set<String> = Set(BackendOption.catalog(appleSpeechAvailable: true).all.map(\.backend)
        + MeetingSummaryBackendOption.all.map(\.backend)
        + ["mixed", "local", "gemma4-litert", "openai", "chatgpt", "openrouter"])

    private static let models: Set<String> = {
        let asr = BackendOption.catalog(appleSpeechAvailable: true).all.map(\.model)
        let hosted = (SummaryModelPreset.openAIModels + SummaryModelPreset.chatGPTModels
            + SummaryModelPreset.anthropicModels + SummaryModelPreset.claudeCodeModels
            + SummaryModelPreset.chatGPTTranscriptCleanupModels + SummaryModelPreset.openRouterModels).map(\.id)
        let planners = Gemma4LiteRTModel.generalPurpose.map { "local:gemma4-litert:" + $0.repoID }
        return Set(asr + hosted + planners + PostProcessorOption.all.map(\.id) + CotypistModel.allCases.map(\.rawValue) + Gemma4LiteRTModel.allCases.map(\.rawValue)
            + ["mixed", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"])
    }()
    static func catalog(provider: String, model: String) -> AnalyticsModel {
        // Custom endpoint model names are private even if they resemble public IDs.
        let custom = ["ollama", "lmstudio", "lm-studio", "custom-llm", "custom_llm"].contains(provider)
        return AnalyticsModel(provider: provider, model: custom ? "custom" : model,
                              providers: providers, models: models)
    }
    static func computerUse(_ config: AppConfig) -> AnalyticsModel {
        let model = ComputerUsePlannerClient.plannerModel(for: config)
        return catalog(provider: ComputerUseLocalPlanner.isLocal(model) ? "local" : "chatgpt", model: model)
    }
    static func summary(_ config: AppConfig) -> AnalyticsModel {
        catalog(provider: config.meetingSummaryBackend, model: MeetingTextGenerationClient.model(config))
    }
}

extension ChatAnalyticsSource {
    init(_ kind: GlobalSearchKind) {
        switch kind {
        case .meeting: self = .meeting
        case .dictation: self = .dictation
        case .command: self = .command
        case .quill: self = .quill
        case .cotypist: self = .cotypist
        case .screenHistory: self = .screen_history
        case .chat: self = .chat
        case .recap: self = .recap
        case .vidshot: self = .vidshot
        }
    }

    init(_ kind: ChatFileReference.Kind) {
        switch kind {
        case .image: self = .image
        case .pdf: self = .pdf
        case .markdown: self = .markdown
        case .text: self = .text
        }
    }
}
