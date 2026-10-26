import Foundation

/// A slow editor must not replay an unbounded queue of obsolete hypotheses.
/// Finish closes admission and drops pending previews; an already-started write
/// is allowed to finish its readback before the target's final replacement.
@MainActor
final class BufferedDictationPreviewDelivery {
    private let deliver: (BufferedTranscriptionUpdate) async -> Bool
    private let onResult: (BufferedTranscriptionUpdate, Bool) -> Void
    private var pending: BufferedTranscriptionUpdate?
    private var latestRevision: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var closed = false

    init(deliver: @escaping (BufferedTranscriptionUpdate) async -> Bool,
         onResult: @escaping (BufferedTranscriptionUpdate, Bool) -> Void = { _, _ in }) {
        self.deliver = deliver
        self.onResult = onResult
    }

    func offer(_ update: BufferedTranscriptionUpdate) {
        guard !closed, update.revision > latestRevision else { return }
        latestRevision = update.revision
        // Recognition retains its hypothesis for agreement/alignment, but the
        // destination only receives committed groups. Never revise a visible
        // draft while the user is speaking; final cleanup is a separate write.
        pending = BufferedTranscriptionUpdate(committedText: update.committedText,
                                              tail: "", revision: update.revision)
        guard worker == nil else { return }
        worker = Task { @MainActor in
            while !closed, let update = pending {
                pending = nil
                let accepted = await deliver(update)
                onResult(update, accepted)
                if !accepted { close() }
            }
            worker = nil
        }
    }

    func close() {
        closed = true
        pending = nil
    }

    func waitUntilIdle() async {
        await worker?.value
    }
}
