import Testing
import Foundation
import CoreAudio
@testable import MuesliNativeApp

@Suite("StreamingDictationController")
struct StreamingDictationControllerTests {

    @available(macOS 15, *)
    @Test("controller initializes without crash")
    func initDoesNotCrash() {
        let transcriber = ImmediateStreamingTranscriber()
        let _ = StreamingDictationController(transcriber: transcriber)
    }

    @available(macOS 15, *)
    @Test("stop returns empty string when not started")
    func stopWithoutStart() async {
        let transcriber = ImmediateStreamingTranscriber()
        let controller = StreamingDictationController(transcriber: transcriber)
        let result = await stop(controller)
        #expect(result.isEmpty)
    }

    @available(macOS 15, *)
    @Test("failed mic start resets active state")
    func failedMicStartResetsActiveState() {
        let transcriber = ImmediateStreamingTranscriber()
        let recorder = FailingStreamingDictationRecorder()
        let controller = StreamingDictationController(
            transcriber: transcriber,
            recorder: recorder
        )

        #expect(controller.start() == false)
        #expect(controller.start() == false)
        #expect(recorder.prepareCalls == 2)
        #expect(recorder.cancelCalls == 2)
    }

    @available(macOS 15, *)
    @Test("stream state failure cancels mic session and permits retry")
    func streamStateFailureCancelsMicSessionAndPermitsRetry() async {
        let transcriber = FailingStreamingTranscriber()
        let recorder = InspectableStreamingDictationRecorder()
        let failures = FailureCounter()
        let controller = StreamingDictationController(
            transcriber: transcriber,
            recorder: recorder
        )
        controller.onFailure = { _ in
            failures.increment()
        }

        #expect(controller.start() == true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(transcriber.makeStateCalls == 1)
        #expect(recorder.prepareCalls == 1)
        #expect(recorder.startCalls == 1)
        #expect(recorder.cancelCalls == 1)
        #expect(failures.value == 1)

        #expect(controller.start() == true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(transcriber.makeStateCalls == 2)
        #expect(recorder.prepareCalls == 2)
        #expect(recorder.startCalls == 2)
        #expect(recorder.cancelCalls == 2)
        #expect(failures.value == 2)
    }

    @available(macOS 15, *)
    @Test("start prepares routed input before mic capture")
    func startPreparesRoutedInputBeforeMicCapture() {
        let transcriber = FailingStreamingTranscriber()
        let recorder = InspectableStreamingDictationRecorder()
        let controller = StreamingDictationController(
            transcriber: transcriber,
            preferredInputDeviceID: 82,
            recorder: recorder
        )

        #expect(controller.start() == true)
        #expect(recorder.preparedPreferredInputDeviceID == 82)
        #expect(recorder.startedPreferredInputDeviceID == 82)
        #expect(recorder.prepareCalls == 1)
        #expect(recorder.startCalls == 1)
        controller.cancel()
    }

    @available(macOS 15, *)
    @Test("currentPower reflects streaming recorder level")
    func currentPowerReflectsStreamingRecorderLevel() {
        let transcriber = ImmediateStreamingTranscriber()
        let recorder = InspectableStreamingDictationRecorder()
        let controller = StreamingDictationController(
            transcriber: transcriber,
            recorder: recorder
        )

        recorder.power = -27

        #expect(controller.currentPower() == -27)
    }

    @available(macOS 15, *)
    @Test("stop waits for pending stream state before draining queued audio")
    func stopWaitsForPendingStreamStateBeforeDrainingQueuedAudio() async {
        let transcriber = DelayedStreamingTranscriber()
        let recorder = InspectableStreamingDictationRecorder()
        let controller = StreamingDictationController(
            transcriber: transcriber,
            recorder: recorder
        )

        #expect(controller.start() == true)
        recorder.emit(samples: [Float](repeating: 0.2, count: 8960))

        async let stoppedText = stop(controller)
        try? await Task.sleep(for: .milliseconds(25))
        #expect(await transcriber.transcribeCalls == 0)

        await transcriber.releaseState()
        let text = await stoppedText
        #expect(text == " hello")
        #expect(await transcriber.transcribeCalls == 1)
    }

    @available(macOS 15, *)
    @Test("concurrent stops share one drain and transcript")
    func concurrentStopsShareOneDrainAndTranscript() async {
        let transcriber = DelayedStreamingTranscriber()
        let recorder = InspectableStreamingDictationRecorder()
        let controller = StreamingDictationController(
            transcriber: transcriber,
            recorder: recorder
        )

        #expect(controller.start() == true)
        recorder.emit(samples: [Float](repeating: 0.2, count: 8960))

        async let firstStop = stop(controller)
        async let secondStop = stop(controller)
        try? await Task.sleep(for: .milliseconds(25))
        #expect(recorder.stopCalls == 1)
        #expect(await transcriber.transcribeCalls == 0)

        await transcriber.releaseState()
        let results = await [firstStop, secondStop]
        #expect(results == [" hello", " hello"])
        #expect(await transcriber.transcribeCalls == 1)
    }

    @available(macOS 15, *)
    @Test("start during stop does not drop pending stop completion")
    func startDuringStopDoesNotDropPendingStopCompletion() async {
        let transcriber = DelayedStreamingTranscriber()
        let recorder = InspectableStreamingDictationRecorder()
        let controller = StreamingDictationController(
            transcriber: transcriber,
            recorder: recorder
        )

        #expect(controller.start() == true)
        recorder.emit(samples: [Float](repeating: 0.2, count: 8960))

        async let stoppedText = stop(controller)
        try? await Task.sleep(for: .milliseconds(25))
        #expect(controller.start() == false)
        #expect(recorder.stopCalls == 1)
        #expect(recorder.startCalls == 1)

        await transcriber.releaseState()
        let text = await stoppedText
        #expect(text == " hello")
        #expect(controller.start() == true)
        controller.cancel()
    }

    @available(macOS 15, *)
    @Test("stop removes unused recorder WAV output")
    func stopRemovesUnusedRecorderWavOutput() async throws {
        let transcriber = DelayedStreamingTranscriber()
        let recorder = InspectableStreamingDictationRecorder()
        let controller = StreamingDictationController(
            transcriber: transcriber,
            recorder: recorder
        )
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data([1, 2, 3]).write(to: wavURL)
        recorder.stopURL = wavURL

        #expect(controller.start() == true)
        async let stoppedText = stop(controller)
        await transcriber.releaseState()
        _ = await stoppedText

        #expect(!FileManager.default.fileExists(atPath: wavURL.path))
    }

    @available(macOS 15, *)
    @Test("chunk transcription failure cancels mic session and permits retry")
    func chunkTranscriptionFailureCancelsMicSessionAndPermitsRetry() async {
        let transcriber = ThrowingChunkStreamingTranscriber()
        let recorder = InspectableStreamingDictationRecorder()
        let failures = FailureCounter()
        let controller = StreamingDictationController(
            transcriber: transcriber,
            recorder: recorder
        )
        controller.onFailure = { _ in
            failures.increment()
        }

        #expect(controller.start() == true)
        recorder.emit(samples: [Float](repeating: 0.2, count: 8960))
        #expect(await waitUntil { recorder.cancelCalls == 1 && failures.value == 1 })

        #expect(await transcriber.transcribeCalls == 1)
        #expect(recorder.cancelCalls == 1)
        #expect(failures.value == 1)
        #expect(controller.start() == true)
        controller.cancel()
    }

    @available(macOS 15, *)
    @Test("recorder failure cancels streaming session and permits retry")
    func recorderFailureCancelsStreamingSessionAndPermitsRetry() async {
        let transcriber = ImmediateStreamingTranscriber()
        let recorder = InspectableStreamingDictationRecorder()
        let failures = FailureCounter()
        let controller = StreamingDictationController(
            transcriber: transcriber,
            recorder: recorder
        )
        controller.onFailure = { _ in
            failures.increment()
        }

        #expect(controller.start() == true)
        recorder.onRecordingFailed?(NSError(domain: "StreamingDictationControllerTests", code: 1))
        try? await Task.sleep(for: .milliseconds(25))

        #expect(recorder.cancelCalls == 1)
        #expect(failures.value == 1)
        #expect(recorder.onAudioBuffer == nil)
        #expect(recorder.onRecordingFailed == nil)
        #expect(controller.start() == true)
        controller.cancel()
    }

    @available(macOS 15, *)
    @Test("recorder failure after stop begins does not fail stopping session")
    func recorderFailureAfterStopBeginsDoesNotFailStoppingSession() async {
        let transcriber = DelayedStreamingTranscriber()
        let recorder = InspectableStreamingDictationRecorder()
        let failures = FailureCounter()
        let controller = StreamingDictationController(
            transcriber: transcriber,
            recorder: recorder
        )
        controller.onFailure = { _ in
            failures.increment()
        }

        #expect(controller.start() == true)
        recorder.emit(samples: [Float](repeating: 0.2, count: 8960))
        let capturedFailure = recorder.onRecordingFailed

        async let stoppedText = stop(controller)
        try? await Task.sleep(for: .milliseconds(25))
        capturedFailure?(NSError(domain: "StreamingDictationControllerTests", code: 2))

        await transcriber.releaseState()
        let text = await stoppedText
        #expect(text == " hello")
        #expect(recorder.cancelCalls == 0)
        #expect(failures.value == 0)
    }

    @available(macOS 15, *)
    @Test("stop completes when stream state initialization stalls")
    func stopCompletesWhenStreamStateInitializationStalls() async {
        let transcriber = HangingStreamingTranscriber()
        let recorder = InspectableStreamingDictationRecorder()
        let controller = StreamingDictationController(
            transcriber: transcriber,
            recorder: recorder,
            stopStreamStateTimeout: 1.0
        )

        #expect(controller.start() == true)
        recorder.emit(samples: [Float](repeating: 0.2, count: 8960))

        let startedAt = Date()
        let text = await stop(controller)
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(text.isEmpty)
        #expect(elapsed < 2.5)
    }

    @available(macOS 15, *)
    @Test("stop completes when stream state initialization ignores cancellation")
    func stopCompletesWhenStreamStateInitializationIgnoresCancellation() async {
        let transcriber = CancellationIgnoringStreamingTranscriber()
        let recorder = InspectableStreamingDictationRecorder()
        let controller = StreamingDictationController(
            transcriber: transcriber,
            recorder: recorder,
            stopStreamStateTimeout: 1.0
        )

        #expect(controller.start() == true)
        recorder.emit(samples: [Float](repeating: 0.2, count: 8960))

        let startedAt = Date()
        let text = await stop(controller)
        let elapsed = Date().timeIntervalSince(startedAt)
        await transcriber.releaseState()

        #expect(text.isEmpty)
        #expect(elapsed < 2.5)
    }

    @available(macOS 15, *)
    @Test("stop waits for cold stream state and drains final queued chunk")
    func stopWaitsForColdStreamStateAndDrainsFinalQueuedChunk() async {
        let transcriber = DelayedStreamingTranscriber()
        let recorder = InspectableStreamingDictationRecorder()
        let controller = StreamingDictationController(
            transcriber: transcriber,
            recorder: recorder,
            stopStreamStateTimeout: 2.0
        )

        #expect(controller.start() == true)
        recorder.emit(samples: [Float](repeating: 0.2, count: 8960))

        async let stoppedText = stop(controller)
        try? await Task.sleep(for: .milliseconds(1_100))
        await transcriber.releaseState()

        let text = await stoppedText
        #expect(text == " hello")
        #expect(await transcriber.transcribeCalls == 1)
    }

    @available(macOS 15, *)
    @Test("stop drains final queued chunk with Nemotron 3.5 chunk size")
    func stopDrainsFinalQueuedChunkWithNemotron35ChunkSize() async {
        let transcriber = DelayedStreamingTranscriber()
        let recorder = InspectableStreamingDictationRecorder()
        let controller = StreamingDictationController(
            transcriber: transcriber,
            recorder: recorder,
            stopStreamStateTimeout: 2.0,
            chunkSamples: 35_840
        )

        #expect(controller.start() == true)
        recorder.emit(samples: [Float](repeating: 0.2, count: 35_840))

        async let stoppedText = stop(controller)
        try? await Task.sleep(for: .milliseconds(1_100))
        await transcriber.releaseState()

        let text = await stoppedText
        #expect(text == " hello")
        #expect(await transcriber.transcribeCalls == 1)
    }
}

private final class FailingStreamingDictationRecorder: StreamingDictationRecording {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var preferredInputDeviceID: AudioObjectID?
    var prepareCalls = 0
    var startCalls = 0
    var cancelCalls = 0

    func prepare() throws {
        prepareCalls += 1
        throw NSError(domain: "FailingStreamingDictationRecorder", code: 1)
    }

    func start() throws {
        startCalls += 1
    }

    func stop() -> URL? {
        nil
    }

    func cancel() {
        cancelCalls += 1
    }

    func currentPower() -> Float {
        -160
    }
}

@available(macOS 15, *)
private final class FailingStreamingTranscriber: NemotronStreamingTranscribing {
    var makeStateCalls = 0

    func makeStreamState() async throws -> RNNTStreamState {
        makeStateCalls += 1
        throw NSError(domain: "FailingStreamingTranscriber", code: 1)
    }

    func transcribeChunk(
        samples: [Float],
        state: inout RNNTStreamState
    ) async throws -> String {
        ""
    }
}

private final class InspectableStreamingDictationRecorder: StreamingDictationRecording {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var preferredInputDeviceID: AudioObjectID?
    var prepareCalls = 0
    var startCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var preparedPreferredInputDeviceID: AudioObjectID?
    var startedPreferredInputDeviceID: AudioObjectID?
    var stopURL: URL?
    var power: Float = -160

    func prepare() throws {
        prepareCalls += 1
        preparedPreferredInputDeviceID = preferredInputDeviceID
    }

    func start() throws {
        startCalls += 1
        startedPreferredInputDeviceID = preferredInputDeviceID
    }

    func emit(samples: [Float]) {
        onAudioBuffer?(samples)
    }

    func stop() -> URL? {
        stopCalls += 1
        return stopURL
    }

    func cancel() {
        cancelCalls += 1
    }

    func currentPower() -> Float {
        power
    }
}

@available(macOS 15, *)
private actor DelayedStreamingTranscriber: NemotronStreamingTranscribing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var transcribeCalls = 0

    func makeStreamState() async throws -> RNNTStreamState {
        if !released {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return try makeTestNemotronStreamState()
    }

    func releaseState() {
        released = true
        if let continuation {
            self.continuation = nil
            continuation.resume()
        }
    }

    func transcribeChunk(
        samples: [Float],
        state: inout RNNTStreamState
    ) async throws -> String {
        transcribeCalls += 1
        return " hello"
    }
}

@available(macOS 15, *)
private actor ImmediateStreamingTranscriber: NemotronStreamingTranscribing {
    func makeStreamState() async throws -> RNNTStreamState {
        try makeTestNemotronStreamState()
    }

    func transcribeChunk(
        samples: [Float],
        state: inout RNNTStreamState
    ) async throws -> String {
        ""
    }
}

@available(macOS 15, *)
private actor ThrowingChunkStreamingTranscriber: NemotronStreamingTranscribing {
    private(set) var transcribeCalls = 0

    func makeStreamState() async throws -> RNNTStreamState {
        try makeTestNemotronStreamState()
    }

    func transcribeChunk(
        samples: [Float],
        state: inout RNNTStreamState
    ) async throws -> String {
        transcribeCalls += 1
        throw NSError(domain: "ThrowingChunkStreamingTranscriber", code: 1)
    }
}

@available(macOS 15, *)
private final class HangingStreamingTranscriber: NemotronStreamingTranscribing {
    func makeStreamState() async throws -> RNNTStreamState {
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func transcribeChunk(
        samples: [Float],
        state: inout RNNTStreamState
    ) async throws -> String {
        "should not be reached"
    }
}

@available(macOS 15, *)
private actor CancellationIgnoringStreamingTranscriber: NemotronStreamingTranscribing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func makeStreamState() async throws -> RNNTStreamState {
        if !released {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return try makeTestNemotronStreamState()
    }

    func releaseState() {
        released = true
        if let continuation {
            self.continuation = nil
            continuation.resume()
        }
    }

    func transcribeChunk(
        samples: [Float],
        state: inout RNNTStreamState
    ) async throws -> String {
        "should not be reached"
    }
}

private final class FailureCounter {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock {
            storage += 1
        }
    }
}

@Suite("Delta paste logic")
struct DeltaPasteTests {

    @Test("delta from empty previous text")
    func deltaFromEmpty() {
        let fullText = "hello world"
        let previousText = ""
        let delta = String(fullText.dropFirst(previousText.count))
        #expect(delta == "hello world")
    }

    @Test("delta appends new words only")
    func deltaAppendsOnly() {
        let previousText = "hello "
        let fullText = "hello world"
        let delta = String(fullText.dropFirst(previousText.count))
        #expect(delta == "world")
    }

    @Test("delta is empty when text unchanged")
    func deltaEmptyNoChange() {
        let text = "same text"
        let delta = String(text.dropFirst(text.count))
        #expect(delta.isEmpty)
    }

    @Test("delta handles multi-chunk accumulation")
    func multiChunkDelta() {
        var previous = ""
        let chunks = ["Hello ", "Hello world ", "Hello world how ", "Hello world how are you"]

        var deltas: [String] = []
        for fullText in chunks {
            let delta = String(fullText.dropFirst(previous.count))
            if !delta.isEmpty {
                deltas.append(delta)
            }
            previous = fullText
        }

        #expect(deltas == ["Hello ", "world ", "how ", "are you"])
    }

    @Test("delta with unicode characters")
    func deltaUnicode() {
        let previousText = "café "
        let fullText = "café résumé"
        let delta = String(fullText.dropFirst(previousText.count))
        #expect(delta == "résumé")
    }
}

@Suite("Transcript accumulation")
struct TranscriptAccumulationTests {

    @Test("SentencePiece leading space preserved in concatenation")
    func sentencePieceSpacing() {
        // Simulates what happens when decodeTokens(trim: false) returns chunks
        // with SentencePiece ▁ → " " preserved
        var transcript = ""
        let chunks = [" Hello", " world", " how", " are", " you"]
        for chunk in chunks {
            transcript += chunk
        }
        #expect(transcript == " Hello world how are you")
    }

    @Test("chunks without leading space concatenate correctly")
    func noLeadingSpace() {
        // Some chunks may not start with space (mid-word continuation)
        var transcript = ""
        let chunks = [" hel", "lo", " wor", "ld"]
        for chunk in chunks {
            transcript += chunk
        }
        #expect(transcript == " hello world")
    }

    @Test("empty chunks don't affect transcript")
    func emptyChunks() {
        var transcript = ""
        let chunks = [" Hello", "", " world", "", ""]
        for chunk in chunks {
            if !chunk.isEmpty {
                transcript += chunk
            }
        }
        #expect(transcript == " Hello world")
    }

    @Test("delta paste tracks correctly with SentencePiece spaces")
    func deltaPasteWithSpaces() {
        var previous = ""
        var deltas: [String] = []

        let partials = [" Hello", " Hello world", " Hello world how are you"]
        for full in partials {
            let delta = String(full.dropFirst(previous.count))
            if !delta.isEmpty { deltas.append(delta) }
            previous = full
        }

        #expect(deltas == [" Hello", " world", " how are you"])
    }
}

@Suite("StreamingDictationController lifecycle")
struct StreamingDictationControllerLifecycleTests {

    @available(macOS 15, *)
    @Test("double stop is safe")
    func doubleStop() async {
        let transcriber = ImmediateStreamingTranscriber()
        let controller = StreamingDictationController(transcriber: transcriber)
        let result1 = await stop(controller)
        let result2 = await stop(controller)
        #expect(result1.isEmpty)
        #expect(result2.isEmpty)
    }

    @available(macOS 15, *)
    @Test("warmup does not crash without loaded models")
    func warmupWithoutModels() {
        let transcriber = ImmediateStreamingTranscriber()
        let controller = StreamingDictationController(transcriber: transcriber)
        // warmup should handle errors gracefully
        controller.warmup()
    }
}

@available(macOS 15, *)
private func stop(_ controller: StreamingDictationController) async -> String {
    await withCheckedContinuation { continuation in
        controller.stop { text in
            continuation.resume(returning: text)
        }
    }
}

private func waitUntil(
    timeout: TimeInterval = 2.0,
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func makeTestNemotronStreamState() throws -> RNNTStreamState {
    try nemotronMakeStreamState(
        config: NemotronRNNTConfig(
            chunkSamples: 35840,
            cacheChannelFrames: 42,
            totalMelFrames: 233,
            encoderDim: 1024,
            decoderHiddenSize: 640,
            blankTokenId: 13087,
            promptId: 101,
            stripAngleBracketTags: true
        )
    )
}

@Suite("Nemotron dictation mode policy")
struct NemotronDictationModePolicyTests {

    @Test("Nemotron 3.5 is the only streaming dictation backend")
    func onlyNemotron35Streams() {
        let streaming = BackendOption.all.filter(\.isStreamingDictationBackend)
        #expect(streaming == [.nemotron35Multilingual])
    }

    @MainActor
    @Test("showWarning is callable without crash in idle state")
    func showWarningIdleNoCrash() {
        let configStore = ConfigStore()
        let config = configStore.load()
        let indicator = FloatingIndicatorController(configStore: configStore)
        // First setState creates the panel so subsequent calls are correctly sequenced
        indicator.setState(.idle, config: config)
        indicator.showWarning("test warning", icon: "⚡", duration: 0.01)
        indicator.close()
    }

    @MainActor
    @Test("showWarning is a no-op when indicator is in recording state")
    func showWarningIgnoredDuringRecording() {
        let configStore = ConfigStore()
        let config = configStore.load()
        let indicator = FloatingIndicatorController(configStore: configStore)
        // Create panel first so setState(.recording) sets state correctly
        indicator.setState(.idle, config: config)
        // Now set to recording — showWarning guard should fire
        indicator.setState(.recording, config: config)
        // Should return early without crashing or changing state
        indicator.showWarning("should be ignored", duration: 0.01)
        indicator.close()
    }
}

@Suite("Nemotron35 backend")
struct Nemotron35StreamStateTests {

    @available(macOS 15, *)
    @Test("makeStreamState uses the 3.5 multilingual cache shapes")
    func makeStreamStateShapes() async throws {
        let transcriber = Nemotron35StreamingTranscriber()
        let state = try await transcriber.makeStreamState()

        // 3.5 att_context left = 42 (EN backend uses 70)
        #expect(state.cacheChannel.shape == [1, 24, 42, 1024])
        #expect(state.cacheTime.shape == [1, 24, 1024, 8])
        #expect(state.cacheLen.shape == [1])
        #expect(state.hState.shape == [2, 1, 640])
        #expect(state.cState.shape == [2, 1, 640])
        #expect(state.lastToken == 0)
        #expect(state.allTokens.isEmpty)
        #expect(state.cacheLen[0].intValue == 0)
    }

    @available(macOS 15, *)
    @Test("transcribeChunk throws when models not loaded")
    func chunkThrowsWithoutModels() async throws {
        let transcriber = Nemotron35StreamingTranscriber()
        var state = try await transcriber.makeStreamState()
        let samples = [Float](repeating: 0, count: transcriber.chunkSamples)

        await #expect(throws: (any Error).self) {
            try await transcriber.transcribeChunk(samples: samples, state: &state)
        }
    }

    @available(macOS 15, *)
    @Test("chunkSamples matches the 2240ms tier")
    func chunkSamplesTier() {
        let transcriber = Nemotron35StreamingTranscriber()
        #expect(transcriber.chunkSamples == 35840)  // 2240ms * 16kHz
    }

    @available(macOS 15, *)
    @Test("3.5 transcriber conforms to the streaming protocol and drives the controller")
    func conformsToStreamingProtocol() {
        let transcriber = Nemotron35StreamingTranscriber()
        // Protocol-typed init + chunkSamples override compiles and constructs.
        let _: NemotronStreamingTranscribing = transcriber
        let _ = StreamingDictationController(
            transcriber: transcriber as NemotronStreamingTranscribing,
            chunkSamples: 35840
        )
    }
}

@Suite("Nemotron35 backend metadata")
struct Nemotron35BackendMetadataTests {

    @Test("nemotron35 description explains live usage and limitations")
    func descriptionWarnings() {
        let desc = BackendOption.nemotron35Multilingual.description
        #expect(!BackendOption.nemotron35Multilingual.label.contains("Experimental"))
        #expect(!desc.contains("Experimental"))
        #expect(desc.contains("hold-to-talk"))
        #expect(desc.contains("hands-free"))
        #expect(desc.contains("Hindi"))
        #expect(desc.contains("punctuation"))
        #expect(desc.contains("does not go back to correct"))
    }

    @Test("nemotron35 backend identifier is nemotron35")
    func backendId() {
        #expect(BackendOption.nemotron35Multilingual.backend == "nemotron35")
    }
}

@Suite("Nemotron35 language selection")
struct Nemotron35LanguageTests {

    @Test("prompt ids match the model's prompt_dictionary")
    func promptIds() {
        #expect(Nemotron35Language.auto.promptId == 101)
        #expect(Nemotron35Language.english.promptId == 0)
        #expect(Nemotron35Language.hindi.promptId == 6)
        #expect(Nemotron35Language.spanish.promptId == 3)
        #expect(Nemotron35Language.chinese.promptId == 4)
        #expect(Nemotron35Language.japanese.promptId == 10)
    }

    @Test("default is auto-detect")
    func defaultIsAuto() {
        #expect(Nemotron35Language.defaultLanguage == .auto)
        #expect(Nemotron35Language.defaultLanguage.promptId == 101)
    }

    @Test("resolved falls back to auto for unknown/nil")
    func resolvedFallback() {
        #expect(Nemotron35Language.resolved("hi") == .hindi)
        #expect(Nemotron35Language.resolved(nil) == .auto)
        #expect(Nemotron35Language.resolved("not-a-language") == .auto)
        #expect(Nemotron35Language.resolvedCode("hi") == "hi")
        #expect(Nemotron35Language.resolvedCode(nil) == "auto")
    }

    @Test("every language has a non-empty label and is unique by prompt id sense")
    func labelsAndCoverage() {
        var promptIds: Set<Int32> = []
        for lang in Nemotron35Language.allCases {
            #expect(!lang.label.isEmpty)
            #expect(promptIds.insert(lang.promptId).inserted, "Duplicate prompt id \(lang.promptId) for \(lang)")
        }
        // Hindi requires the multilingual track — it must be offered.
        #expect(Nemotron35Language.allCases.contains(.hindi))
    }

    @Test("config persists the selected language via snake_case key")
    func configRoundTrip() throws {
        var cfg = AppConfig()
        cfg.nemotron35Language = Nemotron35Language.hindi.rawValue
        let data = try JSONEncoder().encode(cfg)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["nemotron35_language"] as? String == "hi")
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.resolvedNemotron35Language == .hindi)
    }

    @Test("missing language config falls back to auto-detect")
    func configMissingLanguageDefaultsToAuto() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(decoded.resolvedNemotron35Language == .auto)
        #expect(decoded.nemotron35Language == Nemotron35Language.auto.rawValue)
    }
}

@Suite("WhisperKitLanguage")
struct WhisperKitLanguageTests {

    @Test("default is auto-detect")
    func defaultIsAuto() {
        #expect(WhisperKitLanguage.defaultLanguage == .auto)
        #expect(WhisperKitLanguage.defaultLanguage.rawValue == "auto")
    }

    @Test("resolved falls back to auto for unknown/nil")
    func resolvedFallback() {
        #expect(WhisperKitLanguage.resolved("de") == .german)
        #expect(WhisperKitLanguage.resolved(nil) == .auto)
        #expect(WhisperKitLanguage.resolved("not-a-language") == .auto)
        #expect(WhisperKitLanguage.resolvedCode("de") == "de")
        #expect(WhisperKitLanguage.resolvedCode(nil) == "auto")
        #expect(WhisperKitLanguage.resolved(" DE ") == .german)
    }

    @Test("every language has a non-empty unique label")
    func labelsAndCoverage() {
        var labels: Set<String> = []
        for lang in WhisperKitLanguage.allCases {
            #expect(!lang.label.isEmpty)
            #expect(labels.insert(lang.label).inserted, "Duplicate label \(lang.label) for \(lang)")
        }
        #expect(WhisperKitLanguage.allCases.contains(.auto))
        #expect(WhisperKitLanguage.allCases.contains(.german))
    }

    @Test("config persists the selected language via snake_case key")
    func configRoundTrip() throws {
        var cfg = AppConfig()
        cfg.whisperLanguage = WhisperKitLanguage.german.rawValue
        let data = try JSONEncoder().encode(cfg)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["whisper_language"] as? String == "de")
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.resolvedWhisperLanguage == .german)
    }

    @Test("missing language config falls back to auto-detect")
    func configMissingLanguageDefaultsToAuto() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(decoded.resolvedWhisperLanguage == .auto)
        #expect(decoded.whisperLanguage == WhisperKitLanguage.auto.rawValue)
    }

    @Test("english-only models ignore pinned and auto language preferences")
    func englishOnlyModelsIgnoreLanguagePreference() {
        #expect(WhisperKitLanguage.isEnglishOnlyModel("tiny.en"))
        #expect(WhisperKitLanguage.isEnglishOnlyModel("small.en"))
        #expect(WhisperKitLanguage.isEnglishOnlyModel("medium.en"))
        #expect(!WhisperKitLanguage.isEnglishOnlyModel("tiny"))
        #expect(!WhisperKitLanguage.isEnglishOnlyModel("small"))
        #expect(!WhisperKitLanguage.isEnglishOnlyModel("large-v3-v20240930_626MB"))

        #expect(WhisperKitLanguage.preferenceForLoadedModel(.german, modelName: "tiny.en") == nil)
        #expect(WhisperKitLanguage.preferenceForLoadedModel(.auto, modelName: "small.en") == nil)
        #expect(WhisperKitLanguage.preferenceForLoadedModel(.german, modelName: "tiny") == .german)
        #expect(WhisperKitLanguage.preferenceForLoadedModel(.auto, modelName: "small") == .auto)
        #expect(WhisperKitLanguage.preferenceForLoadedModel(.german, modelName: "large-v3-v20240930_626MB") == .german)
        #expect(WhisperKitLanguage.preferenceForLoadedModel(.auto, modelName: "large-v3-v20240930_626MB") == .auto)
    }
}
