import Foundation
import MuesliCore

enum ChatPDFProcessingError: Error, LocalizedError {
    case contextTooSmall
    var errorDescription: String? {
        "The selected model has too little context for this question and its attachments. Shorten the question, remove an attachment, or choose a model with a larger context window."
    }
}

/// Preparation discloses metadata only. Documents are read by explicit model tool
/// calls inside the answer loop; no upfront extraction or condensation requests.
enum ChatPDFProcessing {
    static func prepare(_ files: [ChatFileReference], config: AppConfig, question: String,
        budget: MeetingChatContextBudget, historyReserve: Int = 0, sessionID: UUID = UUID(),
        generator: any MeetingTextGenerating,
        progress: @Sendable (String) async -> Void = { _ in }
    ) async throws -> PreparedChatFiles {
        try ChatFileReader.validate(files)
        var prepared = try ChatFileReader.prepareNonPDF(files.filter { $0.kind == .image }, config: config)
        prepared.documents = files.filter { $0.kind != .image }
        if !prepared.documents.isEmpty { prepared.context += try ChatDocumentTools.manifest(prepared.documents) }
        return prepared
    }
}
