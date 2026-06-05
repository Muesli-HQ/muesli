import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("FallbackStreamingDictationRecorder")
struct FallbackStreamingDictationRecorderTests {
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
        #expect(latencyEvents.contains("streaming_recorder_fallback_prepare_end"))
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
}

private final class FakeFallbackStreamingRecorder: StreamingDictationRecording {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var preferredInputDeviceID: AudioObjectID?

    var prepareResults: [Result<Void, Error>] = []
    var startResults: [Result<Void, Error>] = []
    var preparedInputDeviceIDs: [AudioObjectID?] = []
    var startedInputDeviceID: AudioObjectID?
    var prepareCalls = 0
    var startCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var clearsCallbacksOnCancel = false

    func prepare() throws {
        prepareCalls += 1
        preparedInputDeviceIDs.append(preferredInputDeviceID)
        if !prepareResults.isEmpty {
            try prepareResults.removeFirst().get()
        }
    }

    func start() throws {
        startCalls += 1
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

    func currentPower() -> Float {
        -160
    }
}
