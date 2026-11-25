import Foundation

/// Decides whether a private meeting's content may be sent to a summary backend.
///
/// Nothing is trusted by default. Ollama, LM Studio, and Custom LLM can all point
/// at remote hosts, so the user lists the backends they trust for private meetings.
enum PrivateMeetingPolicy {
    /// The backend id the summary client will actually call for this config:
    /// an empty value means ChatGPT and an unknown value falls through to OpenAI.
    static func effectiveBackend(of config: AppConfig) -> String {
        let raw = config.meetingSummaryBackend.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.isEmpty { return MeetingSummaryBackendOption.chatGPT.backend }
        if MeetingSummaryBackendOption.all.contains(where: { $0.backend == raw }) { return raw }
        return MeetingSummaryBackendOption.openAI.backend
    }

    /// True when a private meeting may be sent to the backend `config` selects.
    static func allowsBackend(_ config: AppConfig) -> Bool {
        let trusted = Set(config.privateTrustedBackends.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        return trusted.contains(effectiveBackend(of: config))
    }

    private static func normalized(_ backend: String) -> String {
        backend.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isTrusted(_ backend: String, in trustedBackends: [String]) -> Bool {
        trustedBackends.contains { normalized($0) == normalized(backend) }
    }

    /// The trusted list after trusting or untrusting one backend, with one normalized entry per backend.
    static func updatedTrust(_ trustedBackends: [String], backend: String, trusted: Bool) -> [String] {
        let target = normalized(backend)
        let others = trustedBackends.map(normalized).filter { $0 != target }
        var seen = Set<String>()
        let unique = others.filter { seen.insert($0).inserted }
        return trusted ? unique + [target] : unique
    }

    /// True when content for this meeting may be sent to the selected backend.
    static func allowsContent(isPrivateMeeting: Bool, config: AppConfig) -> Bool {
        !isPrivateMeeting || allowsBackend(config)
    }

    static let blockedNotice = "Private meeting: summary skipped. Trust this backend for private meetings in Settings to enable it."
}
