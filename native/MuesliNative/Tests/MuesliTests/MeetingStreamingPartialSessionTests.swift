import Foundation
import FluidAudio
import MuesliCore
import os
import Testing
@testable import MuesliNativeApp

@Suite("Meeting streaming partial session")
struct MeetingStreamingPartialSessionTests {
    @Test("stale live caption downloads cannot finish after an immediate restart")
    func liveCaptionDownloadGenerationRejectsStaleCompletion() {
        var state = ModelDownloadGenerationState()
        let firstDownload = state.begin()
        let cancellation = state.begin()
        let replacementDownload = state.begin()

        #expect(!state.contains(firstDownload))
        #expect(!state.contains(cancellation))
        #expect(state.contains(replacementDownload))
        let clearedFirstDownload = state.clear(firstDownload)
        let clearedCancellation = state.clear(cancellation)
        #expect(!clearedFirstDownload)
        #expect(!clearedCancellation)
        #expect(state.contains(replacementDownload))
        let clearedReplacement = state.clear(replacementDownload)
        #expect(clearedReplacement)
        #expect(state.current == nil)
    }

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
                try Data([0x01]).write(to: url.appendingPathComponent("coremldata.bin"))
                let weight = url.appendingPathComponent("weights/weight.bin")
                try FileManager.default.createDirectory(
                    at: weight.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data([0x01]).write(to: weight)
            } else {
                try Data("{}".utf8).write(to: url)
            }
        }

        let partialState = directory.appendingPathComponent(".muesli-download-state.json")
        try Data("{}".utf8).write(to: partialState)
        #expect(!MeetingLiveCaptionModelStore.isDownloaded(in: root))
        try FileManager.default.removeItem(at: partialState)
        #expect(MeetingLiveCaptionModelStore.isDownloaded(in: root))

        let plan = ManagedASRModelPlans.parakeetRealtimeEOU320(modelsRoot: root)
        let installedFiles = ModelNames.ParakeetEOU.requiredModels.flatMap { artifact in
            let relativePaths = artifact.hasSuffix(".mlmodelc")
                ? ["\(artifact)/coremldata.bin", "\(artifact)/weights/weight.bin"]
                : [artifact]
            return relativePaths.map { relativePath in
                ModelDownloadFile(
                    relativePath: relativePath,
                    remoteURL: URL(string: "https://example.com/model")!,
                    expectedByteCount: artifact.hasSuffix(".mlmodelc") ? 1 : 2
                )
            }
        }
        try plan.recordSuccessfulInstallation(ModelDownloadManifest(
            id: plan.modelID,
            version: "test-install",
            files: installedFiles
        ))
        #expect(MeetingLiveCaptionModelStore.isDownloaded(in: root))

        let firstCompiledModel = try #require(
            ModelNames.ParakeetEOU.requiredModels.first { $0.hasSuffix(".mlmodelc") }
        )
        let missingWeight = directory.appendingPathComponent(
            "\(firstCompiledModel)/weights/weight.bin"
        )
        try FileManager.default.removeItem(at: missingWeight)
        #expect(!MeetingLiveCaptionModelStore.isDownloaded(in: root))
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

    @Test("publishes progressive callbacks that arrive after audio submission")
    func publishesOutOfBandProgressiveCallback() async throws {
        let engine = DelayedPartialEngine(text: "中文实时字幕")
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))

        #expect(await waitUntil { collector.latest == "中文实时字幕" })
    }

    @Test("an asynchronous pre-pause callback cannot publish after resume")
    func prePauseAsynchronousCallbackCannotPublishAfterResume() async throws {
        let engine = DelayedPartialEngine(text: "stale", delayNanoseconds: 100_000_000)
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { engine.processCalls == 1 })
        session.suspend()
        session.resume()

        #expect(await remainsTrue(for: 0.5) { collector.latest == "" })
    }

    @Test("an asynchronous boundary freezes one segment without hiding the next")
    func asynchronousBoundaryKeepsSegmentsIndependent() async throws {
        let engine = ManualAsynchronousPartialEngine()
        let session = MeetingStreamingPartialSession(engine: engine, label: "Others")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { engine.processCalls == 1 })
        engine.emit("one")
        #expect(await waitUntil { collector.latest == "one" })

        let segmentID = UUID()
        session.markSegmentBoundary(id: segmentID)
        #expect(await waitUntil { engine.restartCalls == 1 })
        engine.emit("two")
        #expect(await waitUntil { collector.latest == "one two" })

        session.commitSegment(id: segmentID)
        #expect(await waitUntil { collector.latest == "two" })
    }

    @Test("multiple asynchronous boundaries retire only their matching frozen segments")
    func asynchronousBoundariesRetireInOrder() async throws {
        let engine = ManualAsynchronousPartialEngine()
        let session = MeetingStreamingPartialSession(engine: engine, label: "Others")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { engine.processCalls == 1 })
        engine.emit("one")
        #expect(await waitUntil { collector.latest == "one" })
        let firstID = UUID()
        session.markSegmentBoundary(id: firstID)
        #expect(await waitUntil { engine.restartCalls == 1 })

        engine.emit("two")
        #expect(await waitUntil { collector.latest == "one two" })
        let secondID = UUID()
        session.markSegmentBoundary(id: secondID)
        #expect(await waitUntil { engine.restartCalls == 2 })

        engine.emit("three")
        #expect(await waitUntil { collector.latest == "one two three" })
        session.commitSegment(id: firstID)
        #expect(await waitUntil { collector.latest == "two three" })
        session.commitSegment(id: secondID)
        #expect(await waitUntil { collector.latest == "three" })
    }

    @Test("a durable commit can retire frozen text while the analyzer restarts")
    func asynchronousCommitDuringRestartRetiresFrozenText() async throws {
        let engine = ManualAsynchronousPartialEngine(blocksRestart: true)
        let session = MeetingStreamingPartialSession(engine: engine, label: "Others")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { engine.processCalls == 1 })
        engine.emit("one")
        #expect(await waitUntil { collector.latest == "one" })

        let segmentID = UUID()
        session.markSegmentBoundary(id: segmentID)
        #expect(await waitUntil { engine.isRestarting })
        session.commitSegment(id: segmentID)
        #expect(await waitUntil { collector.latest == "" })

        engine.releaseRestart()
        #expect(await waitUntil { !engine.isRestarting })
    }

    @Test("an asynchronous failure during restart makes the session dormant")
    func asynchronousFailureDuringRestartGoesDormant() async throws {
        let engine = ManualAsynchronousPartialEngine(blocksRestart: true)
        let session = MeetingStreamingPartialSession(engine: engine, label: "Others")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        engine.emit("one")
        #expect(await waitUntil { collector.latest == "one" })
        session.markSegmentBoundary(id: UUID())
        #expect(await waitUntil { engine.isRestarting })

        engine.fail()

        #expect(await waitUntil { collector.latest == "" && engine.shutdownCalls > 0 })
        session.enqueue(samples(chunkCount: 1))
        #expect(await remainsTrue { engine.processCalls == 0 })
    }

    @Test("asynchronous frozen preview text has a fixed segment bound")
    func asynchronousFrozenPreviewIsBounded() async throws {
        let engine = ManualAsynchronousPartialEngine()
        let session = MeetingStreamingPartialSession(engine: engine, label: "Others")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        for index in 0..<(MeetingStreamingPartialSession.maxFrozenSegments + 2) {
            engine.emit("[segment\(index)]")
            #expect(await waitUntil { collector.latest?.contains("[segment\(index)]") == true })
            session.markSegmentBoundary(id: UUID())
            #expect(await waitUntil { engine.restartCalls == index + 1 })
        }

        let latest = try #require(collector.latest)
        #expect(!latest.contains("[segment0]"))
        #expect(!latest.contains("[segment1]"))
        #expect(latest.contains("[segment2]"))
        #expect(latest.contains("[segment13]"))
    }

    @Test("a capture source restart rebuilds an asynchronous partial engine")
    func sourceRestartRebuildsAsynchronousEngine() async throws {
        let engine = ManualAsynchronousPartialEngine()
        let session = MeetingStreamingPartialSession(engine: engine, label: "Others")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { engine.processCalls == 1 })
        engine.emit("before restart")
        #expect(await waitUntil { collector.latest == "before restart" })

        session.resetAfterSourceRestart()

        #expect(await waitUntil { engine.restartCalls == 1 && collector.latest == "" })
    }

    @Test("an asynchronous engine failure clears the tail and goes dormant")
    func asynchronousFailureGoesDormant() async throws {
        let engine = FailingAsynchronousPartialEngine()
        let session = MeetingStreamingPartialSession(engine: engine, label: "Others")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { engine.processCalls == 1 })
        engine.emit("before failure")
        #expect(await waitUntil { collector.latest == "before failure" })
        engine.fail()
        #expect(await waitUntil { collector.latest == "" && engine.shutdownCalls == 1 })

        session.enqueue(samples(chunkCount: 1))
        #expect(await remainsTrue { engine.processCalls == 1 })
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

private final class DelayedPartialEngine: MeetingStreamingPartialEngine, @unchecked Sendable {
    let partialDeliveryMode = MeetingStreamingPartialDeliveryMode.asynchronous
    private let text: String
    private let delayNanoseconds: UInt64
    private let handler = OSAllocatedUnfairLock<(@Sendable (String) -> Void)?>(initialState: nil)
    private let calls = OSAllocatedUnfairLock(initialState: 0)

    init(text: String, delayNanoseconds: UInt64 = 20_000_000) {
        self.text = text
        self.delayNanoseconds = delayNanoseconds
    }

    var processCalls: Int { calls.withLock { $0 } }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        self.handler.withLock { $0 = handler }
    }

    func process(samples: [Float]) async throws {
        calls.withLock { $0 += 1 }
        let text = text
        let delayNanoseconds = delayNanoseconds
        let handler = handler.withLock { $0 }
        Task.detached {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            handler?(text)
        }
    }

    func shutdown() async {}
}

private final class ManualAsynchronousPartialEngine: MeetingStreamingPartialEngine, @unchecked Sendable {
    let partialDeliveryMode = MeetingStreamingPartialDeliveryMode.asynchronous
    private struct State {
        var handler: (@Sendable (String) -> Void)?
        var failureHandler: (@Sendable (Error) -> Void)?
        var processCalls = 0
        var restartCalls = 0
        var shutdownCalls = 0
        var restartContinuation: CheckedContinuation<Void, Never>?
        var isRestarting = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let blocksRestart: Bool

    init(blocksRestart: Bool = false) {
        self.blocksRestart = blocksRestart
    }

    var processCalls: Int { state.withLock { $0.processCalls } }
    var restartCalls: Int { state.withLock { $0.restartCalls } }
    var shutdownCalls: Int { state.withLock { $0.shutdownCalls } }
    var isRestarting: Bool { state.withLock { $0.isRestarting } }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        state.withLock { $0.handler = handler }
    }

    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async {
        state.withLock { $0.failureHandler = handler }
    }

    func process(samples: [Float]) async throws {
        state.withLock { $0.processCalls += 1 }
    }

    func restart(
        partialHandler: @escaping @Sendable (String) -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) async throws {
        state.withLock { s in
            s.handler = partialHandler
            s.failureHandler = failureHandler
            s.restartCalls += 1
        }
        guard blocksRestart else { return }
        await withCheckedContinuation { continuation in
            state.withLock { s in
                s.isRestarting = true
                s.restartContinuation = continuation
            }
        }
        state.withLock { $0.isRestarting = false }
    }

    func releaseRestart() {
        let continuation = state.withLock { s -> CheckedContinuation<Void, Never>? in
            let continuation = s.restartContinuation
            s.restartContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func emit(_ text: String) {
        state.withLock { $0.handler }?(text)
    }

    func fail() {
        state.withLock { $0.failureHandler }?(
            NSError(domain: "ManualAsynchronousPartialEngine", code: 1)
        )
    }

    func shutdown() async {
        releaseRestart()
        state.withLock { $0.shutdownCalls += 1 }
    }
}

private final class FailingAsynchronousPartialEngine: MeetingStreamingPartialEngine, @unchecked Sendable {
    let partialDeliveryMode = MeetingStreamingPartialDeliveryMode.asynchronous
    private struct State {
        var partialHandler: (@Sendable (String) -> Void)?
        var failureHandler: (@Sendable (Error) -> Void)?
        var processCalls = 0
        var shutdownCalls = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var processCalls: Int { state.withLock { $0.processCalls } }
    var shutdownCalls: Int { state.withLock { $0.shutdownCalls } }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        state.withLock { $0.partialHandler = handler }
    }

    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async {
        state.withLock { $0.failureHandler = handler }
    }

    func process(samples: [Float]) async throws {
        state.withLock { $0.processCalls += 1 }
    }

    func emit(_ text: String) {
        state.withLock { $0.partialHandler }?(text)
    }

    func fail() {
        state.withLock { $0.failureHandler }?(
            NSError(domain: "FailingAsynchronousPartialEngine", code: 1)
        )
    }

    func shutdown() async {
        state.withLock { $0.shutdownCalls += 1 }
    }
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
