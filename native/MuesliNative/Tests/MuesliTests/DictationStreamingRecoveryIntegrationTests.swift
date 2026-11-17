import CoreAudio
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

/// Exercises the real manager → route-aware/AppScoped recorder → buffered stream
/// → finalizer → recovery pipeline. Only the physical microphone and decoder are fakes.
@Suite("Dictation streaming recovery integration")
@MainActor
struct DictationStreamingRecoveryIntegrationTests {
    @Test("healthy streaming drains its final buffer, reuses recognition, and ignores the startup deadline during slow inference")
    func healthyStreaming() async throws {
        let gate = PipelineDecodeGate()
        let stream = BufferedTranscriptionSession(decode: { await gate.decode($0) },
            onUpdate: { _ in }, onFailure: { _ in Issue.record("Healthy stream failed") })
        let harness = try PipelineHarness(stream: stream)
        defer { harness.dispose() }
        harness.start()
        harness.flush()
        var entered = gate.entered.stream.makeAsyncIterator()
        _ = await entered.next() // Decoder is genuinely still waiting; mic is ready.
        harness.deadlines.fire(0)
        harness.flush()
        #expect(!harness.manager.isRetiringStartup)
        #expect(!stream.diagnostics.closed)
        #expect(harness.failureCount == 0)
        harness.manager.stop()
        harness.flush()
        #expect(stream.diagnostics.receivedSamples == 48_000) // Includes stop drain.
        #expect(harness.stoppedURL == harness.audio)
        await gate.release()
        var fullPasses = 0, cleanups = 0
        let result = try await BufferedDictationFinalizer.transcribe(session: stream,
            recordedSampleCount: BufferedDictationFinalizer.recordedSampleCount(at: harness.audio),
            reuse: { text in cleanups += 1; return .init(text: text, segments: []) },
            nonStreaming: { fullPasses += 1; return .init(text: "unexpected", segments: []) })
        #expect(result.text == "Hello")
        #expect(cleanups == 1)
        #expect(fullPasses == 0)
        DictationRecordingCleanup(wavURL: harness.audio).finish()
        #expect(!FileManager.default.fileExists(atPath: harness.audio.path))
        #expect(!FileManager.default.fileExists(atPath: harness.store.directory.path))
    }

    @Test("incomplete streaming creates one discoverable recovery, preserves its partial text, and retries without another capture")
    func incompleteStreaming() async throws {
        let updates = AsyncStream<Void>.makeStream()
        let stream = BufferedTranscriptionSession(decode: { _ in PipelineDecodeGate.window },
            onUpdate: { _ in updates.continuation.yield() }, onFailure: { _ in })
        let harness = try PipelineHarness(stream: stream)
        defer { harness.dispose(); updates.continuation.finish() }
        harness.start()
        harness.flush()
        var iterator = updates.stream.makeAsyncIterator()
        _ = await iterator.next()
        harness.manager.stop()
        harness.flush()
        var fullPasses = 0
        var cleanup = DictationRecordingCleanup(wavURL: harness.audio)
        do {
            _ = try await BufferedDictationFinalizer.transcribe(session: stream,
                recordedSampleCount: 48_001, reuse: { _ in
                    Issue.record("Incomplete recognition reused"); return .init(text: "", segments: [])
                }, nonStreaming: { fullPasses += 1; return .init(text: "", segments: []) })
            Issue.record("Expected structural streaming failure")
        } catch let error as BufferedDictationFinalizer.IncompleteStream {
            #expect(error.partialText == "Hello")
            #expect(DictationRecoveryPolicy.shouldPreserve(after: error, taskIsCancelled: false,
                isCurrentSession: true, isTestMode: false))
            cleanup.preserveOriginal = true
            let record = try harness.store.save(wavURL: harness.audio, startedAt: Date(),
                durationSeconds: 3, modelName: "Synthetic decoder", failureMessage: error.localizedDescription,
                partialTranscript: error.partialText)
            cleanup.preserveOriginal = false
            cleanup.finish()
            #expect(try harness.store.recordings() == [record])
            #expect(record.partialTranscript == "Hello")
            let textFile = harness.store.audioURL(for: record).deletingLastPathComponent().appendingPathComponent("transcript.txt")
            #expect(try String(contentsOf: textFile, encoding: .utf8) == "Hello")
            var saved: String?
            try await DictationRecoveryRetry.run(record: record, store: harness.store,
                transcribe: { _ in "Recovered full text" }, persist: { saved = $0 })
            #expect(saved == "Recovered full text")
            #expect(try harness.store.recordings().isEmpty)
        }
        #expect(fullPasses == 0)
        #expect(harness.child.startCalls == 1)
    }

    @Test("blocked microphone warning preserves streaming until cancellation and rejects late native samples without creating a recovery")
    func stalledMicrophone() throws {
        let stream = BufferedTranscriptionSession(decode: { _ in PipelineDecodeGate.window },
            onUpdate: { _ in Issue.record("Cancelled startup emitted text") }, onFailure: { _ in })
        let harness = try PipelineHarness(stream: stream)
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        harness.child.startGate = gate
        harness.child.entered = entered
        harness.start()
        defer { gate.signal(); harness.dispose() }
        #expect(entered.wait(timeout: .now() + 2) == .success)
        let lateAudio = harness.child.onAudioBuffer
        harness.deadlines.fire(0)
        harness.eventQueue.sync {}
        #expect(!harness.manager.isRetiringStartup)
        #expect(!stream.diagnostics.closed)
        #expect(harness.failureCount == 0)
        harness.manager.cancel(reason: "user")
        stream.cancel()
        #expect(harness.manager.isRetiringStartup)
        #expect(stream.diagnostics.closed)
        #expect(harness.failureCount == 0)
        lateAudio?([0.5])
        #expect(stream.diagnostics.receivedSamples == 0)
        gate.signal()
        harness.flush()
        #expect(!harness.manager.hasActiveSession)
        #expect(stream.diagnostics.receivedSamples == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.store.directory.path))
    }
}

private actor PipelineDecodeGate {
    nonisolated let entered = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    static var window: BufferedTranscriptionWindow {
        .init(text: "Hello", words: [.init(text: "Hello", start: 0.2, end: 0.6, confidence: 0.99)])
    }
    func decode(_ samples: [Float]) async -> BufferedTranscriptionWindow {
        if !released {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.continuation.yield()
            }
        }
        return Self.window
    }
    func release() { released = true; continuation?.resume(); continuation = nil; entered.continuation.finish() }
}

private final class PipelineHarness {
    let root: URL
    let audio: URL
    let child = PipelineMicrophone()
    let deadlines = StartupTestScheduler()
    let manager: DictationAudioSessionManager
    let stream: BufferedTranscriptionSession
    let store: DictationRecoveryStore
    let queue = DispatchQueue(label: "test.streaming.capture")
    let eventQueue = DispatchQueue(label: "test.streaming.events")
    private(set) var stoppedURL: URL?
    private(set) var failureCount = 0

    init(stream: BufferedTranscriptionSession) throws {
        self.stream = stream
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        audio = root.appendingPathComponent("recording.wav")
        try (WavWriter.header(dataSize: 48_000 * 2) + Data(repeating: 0, count: 48_000 * 2)).write(to: audio)
        store = DictationRecoveryStore(directory: root.appendingPathComponent("recovery"))
        child.audio = audio
        let recorder = RouteAwareDictationRecorder(
            systemDefaultRecorder: AppScopedDictationRecorder(recorder: child),
            appScopedRecorder: AppScopedDictationRecorder(recorder: PipelineMicrophone()))
        let controls = PipelineControls()
        manager = DictationAudioSessionManager(recorder: recorder, duckingController: controls,
            mediaPlaybackController: controls, routingController: PipelineRouting(), queue: queue,
            eventQueue: eventQueue, startupScheduler: deadlines.schedule)
        let pending = BufferedDictationCaptureAudio()
        manager.onAudioBuffer = { pending.append($0) }
        precondition(pending.attach { stream.enqueue($0) })
        manager.onEvent = { [weak self] event in
            guard let self else { return }
            if case .stopped(_, let url) = event { self.stoppedURL = url }
            if case .failed = event {
                self.failureCount += 1
                self.manager.onAudioBuffer = nil
                self.stream.cancel() // Mirrors controller cancelHostedDictation/cancelBufferedDictation.
            }
        }
    }
    func start() { manager.beginRecording(mode: "toggle", duckingEnabled: false, mediaPauseEnabled: false) }
    func flush() { queue.sync {}; queue.sync {}; eventQueue.sync {} }
    func dispose() {
        manager.cancel(reason: "test_cleanup")
        flush()
        stream.cancel()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class PipelineMicrophone: StreamingDictationRecording {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var preferredInputDeviceID: AudioObjectID?
    var audio: URL?
    var startGate: DispatchSemaphore?
    var entered: DispatchSemaphore?
    var startCalls = 0
    func prepare() throws {}
    func start() throws {
        startCalls += 1
        entered?.signal()
        startGate?.wait()
        onAudioBuffer?(Array(repeating: 0.1, count: 32_000))
    }
    func stop() -> URL? { onAudioBuffer?(Array(repeating: 0.1, count: 16_000)); return audio }
    func cancel() {}
    func currentPower() -> Float { -20 }
}

private final class PipelineControls: AudioDuckingManaging, MediaPlaybackManaging {
    func beginDictationDucking(enabled: Bool) {}
    func ensureCurrentDefaultDucked() {}
    func restoreDictationDucking(completion: (() -> Void)?) { completion?() }
    func beginDictationMediaPause(enabled: Bool, routeKind: AudioOutputRouteKind) {}
    func restoreDictationMediaPause() {}
}

private final class PipelineRouting: DictationAudioRouting {
    var onPreferredInputDeviceChanged: ((AudioObjectID?) -> Void)?
    var selectedInputDeviceUID: String?
    func refreshRouteCache() {}
    func preferredInputDeviceIDForDictation() -> AudioObjectID? { nil }
    func cachedPreferredInputDeviceIDForDictation() -> AudioObjectID? { nil }
    func availableInputDevices() -> [AudioInputDeviceInfo] { [] }
    func isDefaultOutputHeadphoneLike() -> Bool { false }
    func currentOutputRouteKindForDebug() -> AudioOutputRouteKind { .speakerLike }
    func currentRouteDebugDescription() -> String { "synthetic_route" }
    func systemDefaultInputIsBuiltInForDictation() -> Bool { true }
    func refreshRouteAfterDictationSession() {}
}
