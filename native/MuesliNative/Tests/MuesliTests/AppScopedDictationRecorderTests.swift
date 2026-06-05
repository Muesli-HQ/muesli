import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("AppScopedDictationRecorder")
struct AppScopedDictationRecorderTests {
    @Test("cancelled queued explicit warmup does not prepare microphone")
    func cancelledQueuedExplicitWarmupDoesNotPrepareMicrophone() {
        let streamingRecorder = FakeStreamingRecorder()
        let prepareQueue = DispatchQueue(label: "test.app-scoped-dictation.prepare.cancelled")
        prepareQueue.suspend()
        let recorder = AppScopedDictationRecorder(
            recorder: streamingRecorder,
            prepareQueue: prepareQueue
        )

        recorder.beginExplicitWarmup(preferredInputDeviceID: 82)
        recorder.cancel()
        prepareQueue.resume()
        prepareQueue.sync {}

        #expect(streamingRecorder.prepareCalls == 0)
        #expect(streamingRecorder.cancelCalls == 1)
    }

    @Test("cancelled in-flight explicit warmup is torn down and not reused")
    func cancelledInFlightExplicitWarmupIsTornDownAndNotReused() {
        let streamingRecorder = FakeStreamingRecorder()
        let prepareStarted = DispatchSemaphore(value: 0)
        let finishPrepare = DispatchSemaphore(value: 0)
        streamingRecorder.onPrepareStarted = {
            prepareStarted.signal()
        }
        streamingRecorder.prepareSemaphore = finishPrepare
        let prepareQueue = DispatchQueue(label: "test.app-scoped-dictation.prepare.in-flight-cancel")
        let recorder = AppScopedDictationRecorder(
            recorder: streamingRecorder,
            prepareQueue: prepareQueue
        )

        recorder.beginExplicitWarmup(preferredInputDeviceID: 82)
        #expect(prepareStarted.wait(timeout: .now() + 1) == .success)
        recorder.cancel()
        finishPrepare.signal()
        prepareQueue.sync {}

        streamingRecorder.prepareSemaphore = nil
        recorder.beginExplicitWarmup(preferredInputDeviceID: 82)
        prepareQueue.sync {}

        #expect(streamingRecorder.prepareCalls == 2)
        #expect(streamingRecorder.cancelCalls == 2)
        #expect(streamingRecorder.preparedInputDeviceIDs == [82, 82])
    }

    @Test("failed explicit warmup is retried on next hotkey prepare")
    func failedExplicitWarmupIsRetriedOnNextHotkeyPrepare() {
        let error = NSError(domain: "AppScopedDictationRecorderTests", code: 1)
        let streamingRecorder = FakeStreamingRecorder()
        streamingRecorder.prepareResults = [
            .failure(error),
            .success(()),
        ]
        let prepareQueue = DispatchQueue(label: "test.app-scoped-dictation.prepare.retry")
        let recorder = AppScopedDictationRecorder(
            recorder: streamingRecorder,
            prepareQueue: prepareQueue
        )

        recorder.beginExplicitWarmup(preferredInputDeviceID: 82)
        prepareQueue.sync {}
        recorder.beginExplicitWarmup(preferredInputDeviceID: 82)
        prepareQueue.sync {}

        #expect(streamingRecorder.prepareCalls == 2)
        #expect(streamingRecorder.cancelCalls == 1)
        #expect(streamingRecorder.preparedInputDeviceIDs == [82, 82])
    }

    @Test("successful explicit warmup is reused by start")
    func successfulExplicitWarmupIsReusedByStart() throws {
        let streamingRecorder = FakeStreamingRecorder()
        let prepareQueue = DispatchQueue(label: "test.app-scoped-dictation.prepare.reuse")
        let recorder = AppScopedDictationRecorder(
            recorder: streamingRecorder,
            prepareQueue: prepareQueue
        )

        recorder.beginExplicitWarmup(preferredInputDeviceID: 82)
        prepareQueue.sync {}
        _ = try recorder.start()

        #expect(streamingRecorder.prepareCalls == 1)
        #expect(streamingRecorder.startCalls == 1)
        #expect(streamingRecorder.startedInputDeviceID == 82)
    }

    @Test("stop clears explicit preparation so rapid re-arm re-prepares")
    func stopClearsExplicitPreparationBeforeRapidRearm() throws {
        let streamingRecorder = FakeStreamingRecorder()
        let prepareQueue = DispatchQueue(label: "test.app-scoped-dictation.prepare.stop-rearm")
        let recorder = AppScopedDictationRecorder(
            recorder: streamingRecorder,
            prepareQueue: prepareQueue
        )

        recorder.beginExplicitWarmup(preferredInputDeviceID: 82)
        prepareQueue.sync {}
        _ = try recorder.start()
        _ = recorder.stop()

        recorder.beginExplicitWarmup(preferredInputDeviceID: 82)
        prepareQueue.sync {}

        #expect(streamingRecorder.prepareCalls == 2)
        #expect(streamingRecorder.stopCalls == 1)
        #expect(streamingRecorder.preparedInputDeviceIDs == [82, 82])
    }

    @Test("cool down clears explicit preparation so next arm re-warms")
    func coolDownClearsExplicitPreparation() {
        let streamingRecorder = FakeStreamingRecorder()
        let prepareQueue = DispatchQueue(label: "test.app-scoped-dictation.prepare.cooldown")
        let recorder = AppScopedDictationRecorder(
            recorder: streamingRecorder,
            prepareQueue: prepareQueue
        )

        recorder.beginExplicitWarmup(preferredInputDeviceID: 82)
        prepareQueue.sync {}
        recorder.coolDown()
        recorder.beginExplicitWarmup(preferredInputDeviceID: 82)
        prepareQueue.sync {}

        #expect(streamingRecorder.prepareCalls == 2)
        #expect(streamingRecorder.cancelCalls == 1)
        #expect(streamingRecorder.preparedInputDeviceIDs == [82, 82])
    }
}

private final class FakeStreamingRecorder: StreamingDictationRecording {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var preferredInputDeviceID: AudioObjectID?

    var prepareResults: [Result<Void, Error>] = []
    var preparedInputDeviceIDs: [AudioObjectID?] = []
    var prepareCalls = 0
    var startCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var startedInputDeviceID: AudioObjectID?
    var onPrepareStarted: (() -> Void)?
    var prepareSemaphore: DispatchSemaphore?

    func prepare() throws {
        prepareCalls += 1
        preparedInputDeviceIDs.append(preferredInputDeviceID)
        onPrepareStarted?()
        prepareSemaphore?.wait()
        if !prepareResults.isEmpty {
            try prepareResults.removeFirst().get()
        }
    }

    func start() throws {
        startCalls += 1
        startedInputDeviceID = preferredInputDeviceID
    }

    func stop() -> URL? {
        stopCalls += 1
        return nil
    }

    func cancel() {
        cancelCalls += 1
    }

    func currentPower() -> Float {
        -160
    }
}
