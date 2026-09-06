import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("FallbackStreamingDictationRecorder")
struct FallbackStreamingDictationRecorderTests {
    @Test("fallback uses input changed while recovering from primary start failure")
    func changedInputDuringFallbackPreparation() throws {
        let primary = FakeFallbackStreamingRecorder()
        let fallback = FakeFallbackStreamingRecorder()
        primary.startResults = [.failure(NSError(domain: "test", code: 1))]
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        recorder.preferredInputDeviceID = 82
        fallback.prepareAction = { [weak recorder] in recorder?.preferredInputDeviceID = 93 }
        try recorder.prepare()
        try recorder.start()
        #expect(fallback.preparedInputDeviceIDs == [82])
        #expect(fallback.startedInputDeviceID == 93)
        recorder.cancel()
    }

    @Test("start applies a route changed after preparation", arguments: [false, true])
    func changedPreparedRoute(useFallback: Bool) throws {
        let primary = FakeFallbackStreamingRecorder()
        let fallback = FakeFallbackStreamingRecorder()
        if useFallback { primary.prepareResults = [.failure(NSError(domain: "test", code: 1))] }
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        recorder.preferredInputDeviceID = 82
        try recorder.prepare()
        recorder.preferredInputDeviceID = 93
        try recorder.start()
        #expect((useFallback ? fallback : primary).startedInputDeviceID == 93)
        recorder.cancel()
    }

    @Test("child startup can synchronously await a forwarded callback")
    func callbacksDoNotWaitForStartupLock() throws {
        let primary = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: FakeFallbackStreamingRecorder())
        let delivered = DispatchSemaphore(value: 0)
        recorder.onAudioBuffer = { _ in delivered.signal() }
        primary.startAction = { [weak primary] in
            let callback = primary?.onAudioBuffer
            Thread.detachNewThread { callback?([0.25]) }
            #expect(delivered.wait(timeout: .now() + 1) == .success)
        }
        try recorder.start()
    }

    @Test("invalidation during startup cannot activate the fallback", arguments: [false, true])
    func invalidationRejectsFallback(startFails: Bool) {
        let primary = FakeFallbackStreamingRecorder()
        let fallback = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        primary.startAction = { [weak recorder] in recorder?.invalidateForTeardown() }
        if startFails { primary.startResults = [.failure(NSError(domain: "test", code: 1))] }
        #expect(throws: Error.self) { try recorder.start() }
        #expect(fallback.prepareCalls == 0)
        #expect(fallback.startCalls == 0)
    }

    @Test("callbacks captured before cancellation cannot reach a reused primary")
    func oldCallbacksAfterReuse() throws {
        let primary = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: FakeFallbackStreamingRecorder())
        var received = 0
        recorder.onAudioBuffer = { _ in received += 1 }
        try recorder.prepare()
        let oldCallback = primary.onAudioBuffer
        recorder.cancel()
        try recorder.prepare()
        oldCallback?([0.1])
        #expect(received == 0)
        primary.onAudioBuffer?([0.2])
        #expect(received == 1)
    }

    @Test("prepare falls back when primary prepare fails")
    func prepareFallsBackWhenPrimaryPrepareFails() throws {
        let error = NSError(domain: "FallbackStreamingDictationRecorderTests", code: 1)
        let primary = FakeFallbackStreamingRecorder()
        primary.prepareResults = [.failure(error)]
        let fallback = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        recorder.preferredInputDeviceID = 82
        var latencyEvents: [String] = []
        recorder.onLatencyEvent = { event, _ in latencyEvents.append(event) }

        try recorder.prepare()

        #expect(primary.prepareCalls == 1)
        #expect(primary.cancelCalls == 1)
        #expect(fallback.prepareCalls == 1)
        #expect(primary.preparedInputDeviceIDs == [82])
        #expect(fallback.preparedInputDeviceIDs == [82])
        #expect(latencyEvents.contains("streaming_recorder_primary_prepare_failed"))
        #expect(latencyEvents.contains("streaming_recorder_selected slot=fallback recorder=FakeFallbackStreamingRecorder preferredInput=82"))
        #expect(latencyEvents.contains("streaming_recorder_fallback_prepare_end"))
    }

    @Test("prepare emits selected primary recorder latency event")
    func prepareEmitsSelectedPrimaryRecorderLatencyEvent() throws {
        let primary = FakeFallbackStreamingRecorder()
        let fallback = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        var latencyEvents: [String] = []
        recorder.onLatencyEvent = { event, _ in latencyEvents.append(event) }

        try recorder.prepare()

        #expect(latencyEvents == [
            "streaming_recorder_selected slot=primary recorder=FakeFallbackStreamingRecorder preferredInput=default",
        ])
    }

    @Test("start falls back when prepared primary start fails")
    func startFallsBackWhenPreparedPrimaryStartFails() throws {
        let error = NSError(domain: "FallbackStreamingDictationRecorderTests", code: 2)
        let primary = FakeFallbackStreamingRecorder()
        primary.startResults = [.failure(error)]
        let fallback = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        recorder.preferredInputDeviceID = 82

        try recorder.prepare()
        try recorder.start()

        #expect(primary.prepareCalls == 1)
        #expect(primary.startCalls == 1)
        #expect(primary.cancelCalls == 1)
        #expect(fallback.prepareCalls == 1)
        #expect(fallback.startCalls == 1)
        #expect(fallback.startedInputDeviceID == 82)
    }

    @Test("fallback start failure cleans up fallback recorder")
    func fallbackStartFailureCleansUpFallbackRecorder() throws {
        let primaryError = NSError(domain: "FallbackStreamingDictationRecorderTests", code: 20)
        let fallbackError = NSError(domain: "FallbackStreamingDictationRecorderTests", code: 21)
        let primary = FakeFallbackStreamingRecorder()
        primary.startResults = [.failure(primaryError)]
        let fallback = FakeFallbackStreamingRecorder()
        fallback.startResults = [.failure(fallbackError)]
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)

        try recorder.prepare()
        #expect(throws: Error.self) {
            try recorder.start()
        }

        #expect(primary.cancelCalls == 1)
        #expect(fallback.prepareCalls == 1)
        #expect(fallback.startCalls == 1)
        #expect(fallback.cancelCalls == 1)
    }

    @Test("callbacks are rewired after child cancel")
    func callbacksAreRewiredAfterChildCancel() throws {
        let error = NSError(domain: "FallbackStreamingDictationRecorderTests", code: 4)
        let primary = FakeFallbackStreamingRecorder()
        primary.startResults = [.failure(error)]
        let fallback = FakeFallbackStreamingRecorder()
        fallback.clearsCallbacksOnCancel = true
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        var bufferCount = 0
        recorder.onAudioBuffer = { _ in bufferCount += 1 }

        recorder.cancel()
        try recorder.prepare()
        try recorder.start()
        fallback.onAudioBuffer?([0.3])

        #expect(fallback.cancelCalls == 1)
        #expect(fallback.startCalls == 1)
        #expect(bufferCount == 1)
    }

    @Test("callbacks from inactive recorder are ignored after fallback")
    func callbacksFromInactiveRecorderAreIgnoredAfterFallback() throws {
        let error = NSError(domain: "FallbackStreamingDictationRecorderTests", code: 3)
        let primary = FakeFallbackStreamingRecorder()
        primary.prepareResults = [.failure(error)]
        let fallback = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        var bufferCount = 0
        var failureCount = 0
        recorder.onAudioBuffer = { _ in bufferCount += 1 }
        recorder.onRecordingFailed = { _ in failureCount += 1 }

        try recorder.prepare()
        primary.onAudioBuffer?([0.1])
        primary.onRecordingFailed?(error)
        fallback.onAudioBuffer?([0.2])

        #expect(bufferCount == 1)
        #expect(failureCount == 0)
    }

    @Test("pause and resume delegate to active recorder")
    func pauseAndResumeDelegateToActiveRecorder() throws {
        let error = NSError(domain: "FallbackStreamingDictationRecorderTests", code: 5)
        let primary = FakeFallbackStreamingRecorder()
        primary.prepareResults = [.failure(error)]
        let fallback = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)

        try recorder.prepare()
        recorder.pause()
        recorder.resume()

        #expect(primary.pauseCalls == 0)
        #expect(primary.resumeCalls == 0)
        #expect(fallback.pauseCalls == 1)
        #expect(fallback.resumeCalls == 1)
    }
}

private final class FakeFallbackStreamingRecorder: StreamingDictationRecording, PausableStreamingDictationRecording {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var preferredInputDeviceID: AudioObjectID?

    var prepareResults: [Result<Void, Error>] = []
    var startResults: [Result<Void, Error>] = []
    var startAction: (() -> Void)?
    var prepareAction: (() -> Void)?
    var preparedInputDeviceIDs: [AudioObjectID?] = []
    var startedInputDeviceID: AudioObjectID?
    var prepareCalls = 0
    var startCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var pauseCalls = 0
    var resumeCalls = 0
    var clearsCallbacksOnCancel = false

    func prepare() throws {
        prepareCalls += 1
        preparedInputDeviceIDs.append(preferredInputDeviceID)
        prepareAction?()
        if !prepareResults.isEmpty {
            try prepareResults.removeFirst().get()
        }
    }

    func start() throws {
        startCalls += 1
        startAction?()
        startedInputDeviceID = preferredInputDeviceID
        if !startResults.isEmpty {
            try startResults.removeFirst().get()
        }
    }

    func stop() -> URL? {
        stopCalls += 1
        return nil
    }

    func cancel() {
        cancelCalls += 1
        if clearsCallbacksOnCancel {
            onAudioBuffer = nil
            onRecordingFailed = nil
        }
    }

    func pause() {
        pauseCalls += 1
    }

    func resume() {
        resumeCalls += 1
    }

    func currentPower() -> Float {
        -160
    }
}
