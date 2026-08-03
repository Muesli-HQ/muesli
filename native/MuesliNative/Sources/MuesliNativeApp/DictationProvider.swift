import Foundation

/// Selects which transcription engine handles dictation. Local models run on
/// device via CoreML; OpenAI runs the user's own API key through the OpenAI
/// audio transcriptions endpoint. The local model selection (`sttBackend` /
/// `sttModel`) is preserved so users can switch back and fall back at any time.
enum DictationProvider: String, CaseIterable, Codable, Sendable {
    case local
    case openAI

    static let defaultProvider: Self = .local

    var label: String {
        switch self {
        case .local:
            return "Local"
        case .openAI:
            return "OpenAI"
        }
    }

    /// Descriptive subtitle shown in Settings.
    var settingsDescription: String {
        switch self {
        case .local:
            return "Runs on your Mac. Private, free, low latency."
        case .openAI:
            return "Uses your OpenAI API key. Best accuracy for long-form dictation."
        }
    }

    static func resolved(_ rawValue: String?) -> Self {
        guard let rawValue, let provider = Self(rawValue: rawValue) else {
            return defaultProvider
        }
        return provider
    }
}
