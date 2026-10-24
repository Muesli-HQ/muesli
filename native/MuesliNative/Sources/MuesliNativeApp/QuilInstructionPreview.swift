import Foundation

/// Shared ownership keeps the recording alive until both the edit and any
/// cancelled-but-still-unwinding preview have stopped reading it.
final class QuilRecordedAudio: Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Best-effort display only. Callers never await this task to generate or paste
/// an edit. Identity checks suppress late results after cancellation/new input.
@MainActor
final class QuilInstructionPreview {
    private var requestID: UUID?
    private var task: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var text: String?
    var isPending: Bool { task != nil }

    func start(audio: QuilRecordedAudio, requestID: UUID, timeout: Duration = .seconds(10),
               transcribe: @escaping @Sendable (URL) async throws -> String,
               display: @escaping @MainActor (String) -> Void) {
        stop()
        self.requestID = requestID
        text = nil
        let startedAt = Date()
        task = Task(priority: .utility) { [weak self] in
            defer { withExtendedLifetime(audio) {} }
            do {
                let result = try await transcribe(audio.url).trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard let self, self.requestID == requestID else { return }
                self.deadline?.cancel()
                self.deadline = nil
                self.task = nil
                if !result.isEmpty {
                    self.text = result
                    display(result)
                }
                Gemma4LiteRTLogging.profile("quill request=\(requestID) preview_completed seconds=\(Date().timeIntervalSince(startedAt)) empty=\(result.isEmpty)")
            } catch {
                guard let self, self.requestID == requestID, !Task.isCancelled else { return }
                self.deadline?.cancel()
                self.deadline = nil
                self.task = nil
                Gemma4LiteRTLogging.profile("quill request=\(requestID) preview_unavailable seconds=\(Date().timeIntervalSince(startedAt))")
            }
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.requestID == requestID else { return }
            self.stop(requestID: requestID)
            Gemma4LiteRTLogging.profile("quill request=\(requestID) preview_timeout")
        }
    }

    /// Returns only a transcript already available; never waits for ASR.
    /// An old edit's defer must not cancel a newer edit's preview.
    @discardableResult
    func stop(requestID expectedID: UUID? = nil) -> String? {
        if let expectedID, requestID != expectedID { return nil }
        requestID = nil
        task?.cancel(); task = nil
        deadline?.cancel(); deadline = nil
        let result = text
        text = nil
        return result
    }
}
