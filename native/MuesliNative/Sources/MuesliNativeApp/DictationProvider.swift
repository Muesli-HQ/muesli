import Foundation

/// Selects which transcription engine handles dictation. Local models run on
/// device via CoreML; hosted providers use the user's own provider credential.
/// The local model selection (`sttBackend` / `sttModel`) is preserved so users
/// can switch back and fall back at any time.
enum DictationProvider: String, CaseIterable, Codable, Sendable {
    case local
    case openAI
    case openRouter

    static let defaultProvider: Self = .local

    var label: String {
        switch self {
        case .local:
            return "Local"
        case .openAI:
            return "OpenAI"
        case .openRouter:
            return "OpenRouter"
        }
    }

    var isHosted: Bool { self != .local }

    static func resolved(_ rawValue: String?) -> Self {
        guard let rawValue, let provider = Self(rawValue: rawValue) else {
            return defaultProvider
        }
        return provider
    }

    /// This flag is specifically for the local live-at-cursor backend. OpenAI
    /// streams audio to its hosted service while retaining the normal recorder
    /// lifecycle and final paste behavior.
    func usesStreamingBackend(_ backend: BackendOption) -> Bool {
        self == .local && backend.isStreamingDictationBackend
    }
}

enum OpenRouterDictationModelSelection {
    static func applyStatusMenuSelection(_ model: String, to config: inout AppConfig) {
        config.dictationProvider = DictationProvider.openRouter.rawValue
        config.openRouterDictationModel = OpenRouterTranscriptionClient.normalizedModel(model)
    }
}

struct HostedDictationModelVisibility: Equatable {
    let visibleProviders: [DictationProvider]

    static func resolve(
        openAIAPIKey: String,
        openRouterAPIKey: String
    ) -> Self {
        var providers: [DictationProvider] = []
        if !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            providers.append(.openAI)
        }
        if !openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            providers.append(.openRouter)
        }
        return Self(visibleProviders: providers)
    }

    func shows(_ provider: DictationProvider) -> Bool {
        visibleProviders.contains(provider)
    }
}
