import Foundation

/// Selects which transcription engine handles dictation. Local models run on
/// device via CoreML; OpenAI runs the user's own API key through the OpenAI
/// Realtime transcription WebSocket. The local model selection (`sttBackend` /
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
