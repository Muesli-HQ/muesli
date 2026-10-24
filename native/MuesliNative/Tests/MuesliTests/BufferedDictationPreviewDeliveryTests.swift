import Testing
@testable import MuesliNativeApp

@Suite("Buffered dictation preview delivery")
@MainActor
struct BufferedDictationPreviewDeliveryTests {
    @MainActor
    private final class Editor {
        var revisions: [UInt64] = []
        var blocked: [UInt64: CheckedContinuation<Bool, Never>] = [:]
        var entered: [UInt64: CheckedContinuation<Void, Never>] = [:]

        func deliver(_ update: BufferedTranscriptionUpdate) async -> Bool {
            revisions.append(update.revision)
            return await withCheckedContinuation { continuation in
                blocked[update.revision] = continuation
                entered.removeValue(forKey: update.revision)?.resume()
            }
        }

        func waitFor(_ revision: UInt64) async {
            if blocked[revision] != nil { return }
            await withCheckedContinuation { entered[revision] = $0 }
        }

        func acknowledge(_ revision: UInt64, accepted: Bool = true) {
            blocked.removeValue(forKey: revision)?.resume(returning: accepted)
        }
    }

    private func update(_ revision: UInt64) -> BufferedTranscriptionUpdate {
        .init(committedText: "stable ", tail: "draft \(revision)", revision: revision)
    }

    @Test func slowEditorReceivesOnlyCurrentAndNewestPreview() async {
        let editor = Editor()
        var completed: [UInt64] = []
        let delivery = BufferedDictationPreviewDelivery(deliver: editor.deliver,
            onResult: { completed.append($0.revision); #expect($1) })
        delivery.offer(update(1))
        await editor.waitFor(1)
        for revision in UInt64(2)...1000 { delivery.offer(update(revision)) }
        #expect(editor.revisions == [1])
        editor.acknowledge(1)
        await editor.waitFor(1000)
        #expect(editor.revisions == [1, 1000])
        editor.acknowledge(1000)
        await delivery.waitUntilIdle()
        #expect(completed == [1, 1000])
    }

    @Test func stoppingDiscardsPendingButAllowsActiveAcknowledgment() async {
        let editor = Editor()
        let delivery = BufferedDictationPreviewDelivery(deliver: editor.deliver)
        delivery.offer(update(1))
        await editor.waitFor(1)
        delivery.offer(update(2))
        delivery.close()
        delivery.offer(update(3))
        editor.acknowledge(1)
        await delivery.waitUntilIdle()
        #expect(editor.revisions == [1])
    }

    @Test func failedWriteNeverDispatchesQueuedOrLaterPreviews() async {
        let editor = Editor()
        var results: [Bool] = []
        let delivery = BufferedDictationPreviewDelivery(deliver: editor.deliver,
            onResult: { _, accepted in results.append(accepted) })
        delivery.offer(update(1))
        await editor.waitFor(1)
        delivery.offer(update(2))
        editor.acknowledge(1, accepted: false)
        await delivery.waitUntilIdle()
        delivery.offer(update(3))
        await delivery.waitUntilIdle()
        #expect(editor.revisions == [1])
        #expect(results == [false])
    }

    @Test func staleAndDuplicateRevisionsCannotReplaceNewest() async {
        let editor = Editor()
        let delivery = BufferedDictationPreviewDelivery(deliver: editor.deliver)
        delivery.offer(update(2))
        delivery.offer(update(1))
        await editor.waitFor(2)
        delivery.offer(update(4))
        delivery.offer(update(3))
        delivery.offer(update(2))
        editor.acknowledge(2)
        await editor.waitFor(4)
        editor.acknowledge(4)
        await delivery.waitUntilIdle()
        #expect(editor.revisions == [2, 4])
        delivery.offer(update(4))
        await delivery.waitUntilIdle()
        #expect(editor.revisions == [2, 4])
    }
}
