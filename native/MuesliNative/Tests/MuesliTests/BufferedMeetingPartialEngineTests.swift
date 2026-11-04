import Foundation
import os
import Testing
@testable import MuesliNativeApp

@Suite("Buffered meeting partial engine")
struct BufferedMeetingPartialEngineTests {
    @Test("buffered preview text cannot replace the saved batch transcript")
    func previewNeverSuppliesFinalText() async throws {
        let engine = BufferedMeetingPartialEngine(makeSession: makeSession)
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let updates = BufferedMeetingTestUpdates()
        session.onPartialUpdate = { updates.record($0) }
        await session.connect()
        defer { session.stop() }

        session.enqueue(Array(repeating: 0.1, count: 16_000))
        let segment = UUID()
        session.markSegmentBoundary(id: segment)
        #expect(await waitUntil { updates.latest == "preview words" })
        #expect(session.pendingSegmentText(id: segment) == nil)
        #expect(await session.finalizedSegmentText(id: segment) == nil)
        #expect(await session.finish() == nil)

        session.commitSegment(id: segment)
        #expect(await waitUntil { updates.latest == "" })
    }

    @Test("each VAD boundary creates a fresh bounded preview session")
    func boundariesResetBufferedAudio() async throws {
        let creations = OSAllocatedUnfairLock(initialState: 0)
        let engine = BufferedMeetingPartialEngine { update, failure in
            creations.withLock { $0 += 1 }
            return try await makeSession(update, failure)
        }
        let updates = BufferedMeetingTestUpdates()
        await engine.setPartialHandler { updates.record($0) }
        await engine.setFailureHandler { _ in Issue.record("Unexpected buffered preview failure") }
        try await engine.process(samples: Array(repeating: 0.1, count: 16_000))
        try await engine.finish()
        #expect(await engine.finalizedText() == "preview words")
        #expect(creations.withLock { $0 } == 1)

        try await engine.restart(partialHandler: { updates.record($0) }, failureHandler: { _ in })
        #expect(await engine.finalizedText() == "")
        try await engine.process(samples: Array(repeating: 0.1, count: 16_000))
        try await engine.finish()
        #expect(creations.withLock { $0 } == 2)
        #expect(await engine.finalizedText() == "preview words")
        await engine.shutdown()
    }

    @Test("a source restart and stop clear preview text and reject stale decoding")
    func restartRejectsLateResults() async throws {
        let gate = BufferedMeetingDecodeGate()
        let engine = BufferedMeetingPartialEngine { update, failure in
            BufferedTranscriptionSession(decode: { _ in
                await gate.wait()
                return window
            }, onUpdate: update, onFailure: failure)
        }
        let updates = BufferedMeetingTestUpdates()
        await engine.setPartialHandler { updates.record($0) }
        await engine.setFailureHandler { _ in }
        try await engine.process(samples: Array(repeating: 0.1, count: 32_000))
        let finishing = Task { try await engine.finish() }
        #expect(await waitUntil { gate.isWaiting })
        try await engine.restart(partialHandler: { updates.record($0) }, failureHandler: { _ in })
        await engine.shutdown()
        gate.release()
        _ = try await finishing.value
        #expect(await engine.finalizedText() == "")
        #expect(updates.latest == nil)
    }

    @Test("late and duplicate revisions cannot replace newer meeting preview text")
    func rejectsOutOfOrderUpdates() async throws {
        let callbacks = OSAllocatedUnfairLock(initialState: [@Sendable (BufferedTranscriptionUpdate) -> Void]())
        let engine = BufferedMeetingPartialEngine { update, failure in
            callbacks.withLock { $0.append(update) }
            return BufferedTranscriptionSession(decode: { _ in window }, onUpdate: update, onFailure: failure)
        }
        let updates = BufferedMeetingTestUpdates()
        await engine.setPartialHandler { updates.record($0) }
        await engine.setFailureHandler { _ in }
        // Below the decode threshold: invoke the real adapter callback explicitly
        // to exercise an ordering the production session normally serializes.
        try await engine.process(samples: [0.1])
        let first = callbacks.withLock { $0[0] }
        first(.init(committedText: "", tail: "newer", revision: 2))
        first(.init(committedText: "", tail: "older", revision: 1))
        first(.init(committedText: "", tail: "duplicate", revision: 2))
        #expect(updates.latest == "newer")
        #expect(await engine.finalizedText() == "newer")

        try await engine.restart(partialHandler: { updates.record($0) }, failureHandler: { _ in })
        try await engine.process(samples: [0.1])
        let second = callbacks.withLock { $0[1] }
        second(.init(committedText: "", tail: "new segment", revision: 1))
        first(.init(committedText: "", tail: "old generation", revision: 99))
        #expect(updates.latest == "new segment")
        #expect(await engine.finalizedText() == "new segment")
        await engine.shutdown()
    }

    private var makeSession: BufferedMeetingPartialEngine.SessionFactory {
        { update, failure in
            BufferedTranscriptionSession(decode: { _ in window }, onUpdate: update, onFailure: failure)
        }
    }

    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate()
    }
}

private var window: BufferedTranscriptionWindow {
    BufferedTranscriptionWindow(text: "preview words", words: [
        BufferedTranscriptionWord(text: "preview", start: 0, end: 0.2),
        BufferedTranscriptionWord(text: " words", start: 0.2, end: 0.4),
    ])
}

private final class BufferedMeetingTestUpdates: Sendable {
    private let value = OSAllocatedUnfairLock<String?>(initialState: nil)
    var latest: String? { value.withLock { $0 } }
    func record(_ text: String) { value.withLock { $0 = text } }
}

private final class BufferedMeetingDecodeGate: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var released = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var isWaiting: Bool { state.withLock { $0.continuation != nil } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let released = state.withLock { state -> Bool in
                guard !state.released else { return true }
                state.continuation = continuation
                return false
            }
            if released { continuation.resume() }
        }
    }

    func release() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.released = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }
}
