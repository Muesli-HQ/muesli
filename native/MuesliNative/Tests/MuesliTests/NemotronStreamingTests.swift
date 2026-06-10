import Testing
import Foundation
import CoreAudio
import CoreML
@testable import MuesliNativeApp

@Suite("NemotronStreamState")
struct NemotronStreamStateTests {

    @available(macOS 15, *)
    @Test("makeStreamState creates zero-initialized state")
    func makeStreamStateZeroInit() async throws {
        let transcriber = NemotronStreamingTranscriber()
        // Models aren't loaded, so makeStreamState should still create valid arrays
        let state = try await transcriber.makeStreamState()

        // Verify shapes
        #expect(state.cacheChannel.shape == [1, 24, 70, 1024])
        #expect(state.cacheTime.shape == [1, 24, 1024, 8])
        #expect(state.cacheLen.shape == [1])
        #expect(state.hState.shape == [2, 1, 640])
        #expect(state.cState.shape == [2, 1, 640])

        // Verify initial token state
        #expect(state.lastToken == 0)
        #expect(state.allTokens.isEmpty)

        // Verify cache is zero
        #expect(state.cacheLen[0].intValue == 0)
    }

    @available(macOS 15, *)
    @Test("makeStreamState creates independent states")
    func independentStates() async throws {
        let transcriber = NemotronStreamingTranscriber()
        var state1 = try await transcriber.makeStreamState()
        let state2 = try await transcriber.makeStreamState()

        // Mutating one shouldn't affect the other
        state1.lastToken = 42
        state1.allTokens.append(99)

        #expect(state2.lastToken == 0)
        #expect(state2.allTokens.isEmpty)
    }

    @available(macOS 15, *)
    @Test("transcribeChunk throws when models not loaded")
    func chunkThrowsWithoutModels() async throws {
        let transcriber = NemotronStreamingTranscriber()
        var state = try await transcriber.makeStreamState()
        let samples = [Float](repeating: 0, count: 8960)

        await #expect(throws: (any Error).self) {
            try await transcriber.transcribeChunk(samples: samples, state: &state)
        }
    }
}

@Suite("StreamingDictationController")
struct StreamingDictationControllerTests {

    @available(macOS 15, *)
    @Test("controller initializes without crash")
    func initDoesNotCrash() {
        let transcriber = NemotronStreamingTranscriber()
        let _ = StreamingDictationController(transcriber: transcriber)
    }

    @available(macOS 15, *)
    @Test("stop returns empty string when not started")
    func stopWithoutStart() async {
        let transcriber = NemotronStreamingTranscriber()
        let controller = StreamingDictationController(transcriber: transcriber)
        let result = await stop(controller)
        #expect(result.isEmpty)
    }

    @available(macOS 15, *)
    @Test("failed mic start resets active state")
    func failedMicStartResetsActiveState() {
        let transcriber = NemotronStreamingTranscriber()
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
        let transcriber = FailingNemotronStreamingTranscriber()
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
        let transcriber = FailingNemotronStreamingTranscriber()
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
    @Test("stop waits for pending stream state before draining queued audio")
    func stopWaitsForPendingStreamStateBeforeDrainingQueuedAudio() async {
        let transcriber = DelayedNemotronStreamingTranscriber()
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
        let transcriber = DelayedNemotronStreamingTranscriber()
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
        let transcriber = DelayedNemotronStreamingTranscriber()
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
        let transcriber = DelayedNemotronStreamingTranscriber()
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
        let transcriber = ThrowingChunkNemotronStreamingTranscriber()
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
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await transcriber.transcribeCalls == 1)
        #expect(recorder.cancelCalls == 1)
        #expect(failures.value == 1)
        #expect(controller.start() == true)
        controller.cancel()
    }

    @available(macOS 15, *)
    @Test("recorder failure cancels streaming session and permits retry")
    func recorderFailureCancelsStreamingSessionAndPermitsRetry() async {
        let transcriber = ImmediateNemotronStreamingTranscriber()
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
        let transcriber = DelayedNemotronStreamingTranscriber()
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
        let transcriber = HangingNemotronStreamingTranscriber()
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
        let transcriber = CancellationIgnoringNemotronStreamingTranscriber()
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
        let transcriber = DelayedNemotronStreamingTranscriber()
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
private final class FailingNemotronStreamingTranscriber: NemotronStreamingTranscribing {
    var makeStateCalls = 0

    func makeStreamState() async throws -> NemotronStreamingTranscriber.StreamState {
        makeStateCalls += 1
        throw NSError(domain: "FailingNemotronStreamingTranscriber", code: 1)
    }

    func transcribeChunk(
        samples: [Float],
        state: inout NemotronStreamingTranscriber.StreamState
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
        -160
    }
}

@available(macOS 15, *)
private actor DelayedNemotronStreamingTranscriber: NemotronStreamingTranscribing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var transcribeCalls = 0

    func makeStreamState() async throws -> NemotronStreamingTranscriber.StreamState {
        if !released {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return try await NemotronStreamingTranscriber().makeStreamState()
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
        state: inout NemotronStreamingTranscriber.StreamState
    ) async throws -> String {
        transcribeCalls += 1
        return " hello"
    }
}

@available(macOS 15, *)
private actor ImmediateNemotronStreamingTranscriber: NemotronStreamingTranscribing {
    func makeStreamState() async throws -> NemotronStreamingTranscriber.StreamState {
        let cacheChannel = try MLMultiArray(shape: [1, 24, 70, 1024], dataType: .float32)
        let cacheTime = try MLMultiArray(shape: [1, 24, 1024, 8], dataType: .float32)
        let cacheLen = try MLMultiArray(shape: [1], dataType: .int32)
        let hState = try MLMultiArray(shape: [2, 1, 640], dataType: .float32)
        let cState = try MLMultiArray(shape: [2, 1, 640], dataType: .float32)
        return NemotronStreamingTranscriber.StreamState(
            cacheChannel: cacheChannel,
            cacheTime: cacheTime,
            cacheLen: cacheLen,
            hState: hState,
            cState: cState,
            lastToken: 0,
            allTokens: []
        )
    }

    func transcribeChunk(
        samples: [Float],
        state: inout NemotronStreamingTranscriber.StreamState
    ) async throws -> String {
        ""
    }
}

@available(macOS 15, *)
private actor ThrowingChunkNemotronStreamingTranscriber: NemotronStreamingTranscribing {
    private(set) var transcribeCalls = 0

    func makeStreamState() async throws -> NemotronStreamingTranscriber.StreamState {
        try await NemotronStreamingTranscriber().makeStreamState()
    }

    func transcribeChunk(
        samples: [Float],
        state: inout NemotronStreamingTranscriber.StreamState
    ) async throws -> String {
        transcribeCalls += 1
        throw NSError(domain: "ThrowingChunkNemotronStreamingTranscriber", code: 1)
    }
}

@available(macOS 15, *)
private final class HangingNemotronStreamingTranscriber: NemotronStreamingTranscribing {
    func makeStreamState() async throws -> NemotronStreamingTranscriber.StreamState {
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func transcribeChunk(
        samples: [Float],
        state: inout NemotronStreamingTranscriber.StreamState
    ) async throws -> String {
        "should not be reached"
    }
}

@available(macOS 15, *)
private actor CancellationIgnoringNemotronStreamingTranscriber: NemotronStreamingTranscribing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func makeStreamState() async throws -> NemotronStreamingTranscriber.StreamState {
        if !released {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return try await NemotronStreamingTranscriber().makeStreamState()
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
        state: inout NemotronStreamingTranscriber.StreamState
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
        let transcriber = NemotronStreamingTranscriber()
        let controller = StreamingDictationController(transcriber: transcriber)
        let result1 = await stop(controller)
        let result2 = await stop(controller)
        #expect(result1.isEmpty)
        #expect(result2.isEmpty)
    }

    @available(macOS 15, *)
    @Test("warmup does not crash without loaded models")
    func warmupWithoutModels() {
        let transcriber = NemotronStreamingTranscriber()
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

@Suite("Nemotron backend metadata")
struct NemotronBackendMetadataTests {

    @Test("nemotron label contains Experimental")
    func experimentalLabel() {
        #expect(BackendOption.nemotronStreaming.label.contains("Experimental"))
    }

    @Test("nemotron description warns about limitations")
    func descriptionWarnings() {
        let desc = BackendOption.nemotronStreaming.description
        #expect(desc.contains("Experimental"))
        #expect(desc.contains("Handsfree"))
        #expect(desc.contains("punctuation") || desc.contains("No punctuation"))
    }

    @Test("nemotron is not recommended")
    func notRecommended() {
        #expect(!BackendOption.nemotronStreaming.recommended)
    }

    @Test("nemotron backend identifier is nemotron")
    func backendId() {
        #expect(BackendOption.nemotronStreaming.backend == "nemotron")
    }
}

@Suite("Nemotron hold-to-talk block policy")
struct NemotronHoldToTalkPolicyTests {

    @Test("nemotron is the only backend blocked from hold-to-talk")
    func onlyNemotronIsBlocked() {
        // MuesliController.handleStart() checks `selectedBackend.backend == "nemotron"`
        // to intercept hold-to-talk and route users to handsfree mode instead.
        let blocked = BackendOption.all.filter { $0.backend == "nemotron" }
        #expect(blocked.count == 1)
        #expect(blocked[0] == .nemotronStreaming)
    }

    @Test("all non-nemotron backends are allowed in hold-to-talk")
    func nonNemotronBackendsAllowHoldToTalk() {
        let allowed = BackendOption.all.filter { $0.backend != "nemotron" }
        for backend in allowed {
            #expect(backend.backend != "nemotron",
                    "\(backend.label) should not be blocked from hold-to-talk")
        }
        #expect(allowed.count == BackendOption.all.count - 1)
    }

    @MainActor
    @Test("showWarning is callable without crash in idle state")
    func showWarningIdleNoCrash() {
        let configStore = ConfigStore()
        let config = configStore.load()
        let indicator = FloatingIndicatorController(configStore: configStore)
        // First setState creates the panel so subsequent calls are correctly sequenced
        indicator.setState(.idle, config: config)
        indicator.showWarning("Double-tap for Nemotron handsfree mode", icon: "⚡", duration: 0.01)
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

@Suite("TranscriptionCoordinator Nemotron accessor")
struct TranscriptionCoordinatorNemotronTests {

    @available(macOS 15, *)
    @Test("getNemotronTranscriber returns valid instance via lazy init")
    func nemotronLazyInit() async {
        let coordinator = TranscriptionCoordinator()
        let transcriber = await coordinator.getNemotronTranscriber()
        let state = try? await transcriber.makeStreamState()
        #expect(state != nil)
    }
}
