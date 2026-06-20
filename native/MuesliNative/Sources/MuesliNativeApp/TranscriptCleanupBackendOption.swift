import Foundation

struct TranscriptCleanupBackendOption: Equatable {
    let backend: String
    let label: String

    static let local = TranscriptCleanupBackendOption(
        backend: "local",
        label: "Local Model"
    )

    static let chatGPT = TranscriptCleanupBackendOption(
        backend: "chatgpt",
        label: "ChatGPT"
    )

    static let all: [TranscriptCleanupBackendOption] = [.local, .chatGPT]

    static func resolved(_ backend: String?) -> TranscriptCleanupBackendOption {
        guard let backend, let option = all.first(where: { $0.backend == backend }) else {
            return .local
        }
        return option
    }
}
