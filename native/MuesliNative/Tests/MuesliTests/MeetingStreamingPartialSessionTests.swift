import Foundation
import FluidAudio
import os
import Testing
@testable import MuesliNativeApp

@Suite("Meeting streaming partial session")
struct MeetingStreamingPartialSessionTests {
    @Test("live caption model is ready only when every EOU artifact exists")
    func modelAvailabilityRequiresEveryArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = MeetingLiveCaptionModelStore.modelDirectory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        #expect(!MeetingLiveCaptionModelStore.isDownloaded(in: root))
        for artifact in ModelNames.ParakeetEOU.requiredModels {
            let url = directory.appendingPathComponent(artifact)
            if artifact.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data("{}".utf8).write(to: url)
            }
        }
        #expect(MeetingLiveCaptionModelStore.isDownloaded(in: root))
    }

    @Test("publishes cumulative Parakeet partials")
    func accumulatesAndPublishes() async throws {
        let engine = ScriptedPartialEngine(script: ["one", "one two"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 2))

        #expect(await waitUntil { collector.latest == "one two" })
        #expect(engine.processCalls == 2)
    }

    @Test("coalesces rapid partials and suppresses duplicate UI updates")
    func coalescesAndDeduplicatesPartials() async throws {
        let engine = ScriptedPartialEngine(script: ["one", "one", "one two"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 3))

        #expect(await waitUntil { collector.latest == "one two" })
        #expect(collector.all == ["one two"])
        #expect(engine.processCalls == 3)
    }

    @Test("filters engine control tags before publishing live captions")
    func filtersEngineArtifacts() async throws {
        let engine = ScriptedPartialEngine(script: [">> [BLANK_AUDIO]"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))

        #expect(await waitUntil { collector.latest == "" })
        #expect(!collector.all.contains { $0.localizedCaseInsensitiveContains("blank_audio") })
    }

    @Test("buffers sub-chunk sample batches until a feed interval is available")
    func buffersSubChunkBatches() async throws {
        let engine = ScriptedPartialEngine(script: ["hello"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        let firstCount = MeetingStreamingPartialSession.feedSamples - 1
        session.enqueue([Float](repeating: 0, count: firstCount))
        #expect(await remainsTrue { engine.processCalls == 0 })

        session.enqueue([0])
        #expect(await waitUntil { collector.latest == "hello" })
    }

    @Test("VAD boundary freezes the prefix and durable commit drops it")
    func boundaryAndCommit() async throws {
        let engine = ScriptedPartialEngine(script: ["one two", "one two three"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one two" })

        let segmentID = UUID()
        session.markSegmentBoundary(id: segmentID)
        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one two three" })

        session.commitSegment(id: segmentID)
        #expect(await waitUntil { collector.latest == " three" })
    }

    @Test("frozen streaming text is available as a durable fallback")
    func pendingSegmentFallback() async throws {
        let engine = ScriptedPartialEngine(script: ["नमस्ते दुनिया", "नमस्ते दुनिया फिर"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "Others")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "नमस्ते दुनिया" })
        let segmentID = UUID()
        session.markSegmentBoundary(id: segmentID)
        #expect(session.pendingSegmentText(id: segmentID) == "नमस्ते दुनिया")

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "नमस्ते दुनिया फिर" })
        session.commitSegment(id: segmentID)
        #expect(await waitUntil { collector.latest == " फिर" })
    }

    @Test("concurrent durable chunks retire their VAD boundaries in order")
    func queuedBoundariesCommitInOrder() async throws {
        let engine = ScriptedPartialEngine(script: ["one", "one two", "one two three"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one" })
        let firstSegmentID = UUID()
        session.markSegmentBoundary(id: firstSegmentID)

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one two" })
        let secondSegmentID = UUID()
        session.markSegmentBoundary(id: secondSegmentID)

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one two three" })

        session.commitSegment(id: firstSegmentID)
        #expect(await waitUntil { collector.latest == " two three" })
        session.commitSegment(id: secondSegmentID)
        #expect(await waitUntil { collector.latest == " three" })
    }

    @Test("out-of-order chunk completion resolves the matching VAD boundary")
    func outOfOrderCommitUsesSegmentID() async throws {
        let engine = ScriptedPartialEngine(script: ["one", "one two", "one two three"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one" })
        let firstSegmentID = UUID()
        session.markSegmentBoundary(id: firstSegmentID)

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one two" })
        let secondSegmentID = UUID()
        session.markSegmentBoundary(id: secondSegmentID)

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one two three" })
        #expect(session.pendingSegmentText(id: firstSegmentID) == "one")
        #expect(session.pendingSegmentText(id: secondSegmentID) == "two")

        session.commitSegment(id: secondSegmentID)
        #expect(await remainsTrue { collector.latest == "one two three" })
        session.commitSegment(id: firstSegmentID)
        #expect(await waitUntil { collector.latest == " three" })
    }

    @Test("commit without a VAD boundary publishes nothing")
    func commitWithoutBoundaryIsNoOp() async throws {
        let engine = ScriptedPartialEngine(script: ["one"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one" })
        let updatesBefore = collector.all.count

        session.commitSegment(id: UUID())
        #expect(await remainsTrue { collector.all.count == updatesBefore })
    }

    @Test("pause hides prior text and resume publishes only new speech")
    func suspendAndResume() async throws {
        let engine = ScriptedPartialEngine(script: ["one", "one two"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one" })

        session.suspend()
        #expect(await waitUntil { collector.latest == "" })

        session.enqueue(samples(chunkCount: 1))
        #expect(await remainsTrue { engine.processCalls == 1 })

        session.resume()
        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == " two" })
    }

    @Test("a chunk retiring after pause cannot restore its stale tail")
    func commitAfterSuspendDoesNotRepublish() async throws {
        let engine = ScriptedPartialEngine(script: ["one"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one" })
        let segmentID = UUID()
        session.markSegmentBoundary(id: segmentID)

        session.suspend()
        #expect(await waitUntil { collector.latest == "" })
        session.commitSegment(id: segmentID)
        #expect(await remainsTrue { collector.latest == "" })
    }

    @Test("inference started before pause cannot publish after resume")
    func prePauseInferenceCannotPublishAfterResume() async throws {
        let engine = BlockingPartialEngine(text: "stale")
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { engine.isWaiting })

        session.suspend()
        session.resume()
        engine.release()

        #expect(await remainsTrue(for: 0.5) { collector.latest == "" })
    }

    @Test("an EOU inference failure clears the tail and goes dormant")
    func failureGoesDormant() async throws {
        let engine = ThrowingPartialEngine()
        let session = MeetingStreamingPartialSession(engine: engine, label: "Others")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "" })
        let callsAfterFailure = engine.processCalls

        session.enqueue(samples(chunkCount: 2))
        #expect(await remainsTrue { engine.processCalls == callsAfterFailure })
    }

    @Test("stop drops buffered audio and suppresses further updates")
    func stopSuppressesUpdates() async throws {
        let engine = ScriptedPartialEngine(script: ["one", "one two"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one" })

        session.stop()
        let updatesBefore = collector.all.count
        session.enqueue(samples(chunkCount: 2))
        #expect(await remainsTrue { collector.all.count == updatesBefore && engine.processCalls == 1 })
    }

    @Test("finish drains residual audio and returns the finalized tail")
    func finishDrainsResidualAudio() async throws {
        let engine = ScriptedPartialEngine(script: ["partial"], finishText: "partial final")
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        await session.connect()

        session.enqueue([Float](repeating: 0, count: MeetingStreamingPartialSession.feedSamples - 1))

        let tail = await session.finish()

        #expect(engine.processCalls == 1)
        #expect(engine.finishCalls == 1)
        #expect(tail == "partial final")
    }

    @Test("finish abandons a hung streaming inference so meeting stop can recover")
    func finishTimesOutHungInference() async throws {
        let engine = BlockingPartialEngine(text: "late")
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { engine.isWaiting })

        let tail = await session.finish(drainTimeoutNanoseconds: 20_000_000)

        #expect(tail == nil)
        #expect(await waitUntil { !engine.isWaiting })
    }

    @Test("backpressure keeps only the freshest EOU feed intervals")
    func backpressureDropsOldestChunks() async throws {
        let engine = EchoPartialEngine()
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        var input: [Float] = []
        for chunkIndex in 0..<7 {
            input.append(contentsOf: [Float](
                repeating: Float(chunkIndex),
                count: MeetingStreamingPartialSession.feedSamples
            ))
        }
        session.enqueue(input)

        #expect(await waitUntil { collector.latest == "c4 c5 c6" })
        #expect(engine.processCalls == MeetingStreamingPartialSession.maxQueuedChunks)
    }
}

private final class ScriptedPartialEngine: MeetingStreamingPartialEngine, @unchecked Sendable {
    private struct State {
        var script: [String]
        var finishText: String?
        var handler: (@Sendable (String) -> Void)?
        var processCalls = 0
        var finishCalls = 0
        var shutdownCalls = 0
    }
    private let state: OSAllocatedUnfairLock<State>

    init(script: [String], finishText: String? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(script: script, finishText: finishText))
    }

    var processCalls: Int { state.withLock { $0.processCalls } }
    var finishCalls: Int { state.withLock { $0.finishCalls } }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        state.withLock { $0.handler = handler }
    }

    func process(samples: [Float]) async throws {
        let update: (String, (@Sendable (String) -> Void)?)? = state.withLock { s in
            s.processCalls += 1
            guard !s.script.isEmpty else { return nil }
            return (s.script.removeFirst(), s.handler)
        }
        if let update {
            update.1?(update.0)
        }
    }

    func finish() async throws {
        let update: (String, (@Sendable (String) -> Void)?)? = state.withLock { s in
            s.finishCalls += 1
            guard let finishText = s.finishText else { return nil }
            return (finishText, s.handler)
        }
        if let update {
            update.1?(update.0)
        }
    }

    func shutdown() async {
        state.withLock { $0.shutdownCalls += 1 }
    }
}

private final class ThrowingPartialEngine: MeetingStreamingPartialEngine, @unchecked Sendable {
    private let calls = OSAllocatedUnfairLock(initialState: 0)

    var processCalls: Int { calls.withLock { $0 } }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {}

    func process(samples: [Float]) async throws {
        calls.withLock { $0 += 1 }
        throw NSError(domain: "ThrowingPartialEngine", code: 1)
    }

    func shutdown() async {}
}

private final class BlockingPartialEngine: MeetingStreamingPartialEngine, @unchecked Sendable {
    private struct State {
        var handler: (@Sendable (String) -> Void)?
        var continuation: CheckedContinuation<Void, Never>?
        var isWaiting = false
    }
    private let text: String
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(text: String) {
        self.text = text
    }

    var isWaiting: Bool { state.withLock { $0.isWaiting } }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        state.withLock { $0.handler = handler }
    }

    func process(samples: [Float]) async throws {
        await withCheckedContinuation { continuation in
            state.withLock { s in
                s.isWaiting = true
                s.continuation = continuation
            }
        }
        state.withLock { $0.handler }?(text)
    }

    func release() {
        let continuation = state.withLock { s -> CheckedContinuation<Void, Never>? in
            let continuation = s.continuation
            s.continuation = nil
            s.isWaiting = false
            return continuation
        }
        continuation?.resume()
    }

    func shutdown() async {
        release()
    }
}

private final class EchoPartialEngine: MeetingStreamingPartialEngine, @unchecked Sendable {
    private struct State {
        var handler: (@Sendable (String) -> Void)?
        var processCalls = 0
        var text = ""
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var processCalls: Int { state.withLock { $0.processCalls } }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        state.withLock { $0.handler = handler }
    }

    func process(samples: [Float]) async throws {
        let update = state.withLock { s -> (String, (@Sendable (String) -> Void)?) in
            s.processCalls += 1
            let marker = samples.first.map { Int($0) } ?? -1
            s.text += " c\(marker)"
            return (s.text, s.handler)
        }
        update.1?(update.0)
    }

    func shutdown() async {}
}

private final class PartialCollector: @unchecked Sendable {
    private let updates = OSAllocatedUnfairLock(initialState: [String]())

    func record(_ text: String) {
        updates.withLock { $0.append(text) }
    }

    var all: [String] { updates.withLock { $0 } }
    var latest: String? { all.last }
}

private func samples(chunkCount: Int, marker: Float = 0) -> [Float] {
    [Float](
        repeating: marker,
        count: MeetingStreamingPartialSession.feedSamples * chunkCount
    )
}

private func remainsTrue(
    for duration: TimeInterval = 0.2,
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        if !condition() { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

private func waitUntil(
    timeout: TimeInterval = 2.0,
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
