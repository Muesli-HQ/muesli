import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Buffered dictation preview delivery")
@MainActor
struct BufferedDictationPreviewDeliveryTests {
    private actor DecodeGate {
        var released = false
        var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { released = true; waiter?.resume(); waiter = nil }
    }

    @Test func finalizationTimeoutRejectsLateDecodeWithoutHangingFallback() async {
        let gate = DecodeGate()
        let session = BufferedTranscriptionSession(decode: { _ in
            await gate.wait()
            return .init(text: "late", words: [.init(text: "late", start: 0, end: 1)])
        }, onUpdate: { _ in }, onFailure: { _ in })
        session.enqueue(Array(repeating: 0.1, count: 32_000))
        let result = await BufferedDictationFinalization.transcript(from: session, timeout: .milliseconds(10))
        #expect(result == nil)
        #expect(session.diagnostics.closed)
        await gate.release()
        #expect(await session.finishTranscript() == nil)
    }

    @Test func finalizationReturnsWholeTranscriptBeforeDeadline() async {
        let session = BufferedTranscriptionSession(decode: { _ in
            .init(text: "complete words", words: [
                .init(text: "complete", start: 0, end: 0.5),
                .init(text: " words", start: 0.5, end: 1)
            ])
        }, onUpdate: { _ in }, onFailure: { _ in })
        session.enqueue(Array(repeating: 0.1, count: 32_000))
        #expect(await BufferedDictationFinalization.transcript(from: session) == "complete words")
    }

    @Test func completedWhisperTranscriptStillUsesFinalProcessingAndCustomWords() async throws {
        let coordinator = TranscriptionCoordinator()
        let result = try await coordinator.transcribeDictation(
            at: URL(fileURLWithPath: "/missing-buffered-whisper-test.wav"),
            backend: .whisperLargeTurbo,
            enablePostProcessor: false,
            customWords: [["word": "museli", "replacement": "Muesli"]],
            completedWhisperTranscript: "I use museli.")
        #expect(result.text == "I use Muesli.")
        #expect(result.segments.isEmpty)
    }

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
