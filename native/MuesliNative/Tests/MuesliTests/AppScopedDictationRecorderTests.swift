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
        let cancelReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            recorder.cancel()
            cancelReturned.signal()
        }
        #expect(cancelReturned.wait(timeout: .now() + 0.1) == .timedOut)
        finishPrepare.signal()
        #expect(cancelReturned.wait(timeout: .now() + 1) == .success)
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

    @Test("stop tears down child recorder graph after finalizing recording")
    func stopTearsDownChildRecorderGraphAfterFinalizingRecording() throws {
        let streamingRecorder = FakeStreamingRecorder()
        let recorder = AppScopedDictationRecorder(
            recorder: streamingRecorder,
            prepareQueue: DispatchQueue(label: "test.app-scoped-dictation.prepare.stop-teardown")
        )

        _ = try recorder.start()
        _ = recorder.stop()

        #expect(streamingRecorder.startCalls == 1)
        #expect(streamingRecorder.stopCalls == 1)
        #expect(streamingRecorder.cancelCalls == 1)
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

    @Test("cancel waits for in-flight child startup before returning")
    func cancelWaitsForInFlightChildStartupBeforeReturning() throws {
        let streamingRecorder = FakeStreamingRecorder()
        let startStarted = DispatchSemaphore(value: 0)
        let finishStart = DispatchSemaphore(value: 0)
        let cancelReturned = DispatchSemaphore(value: 0)
        streamingRecorder.onStartStarted = {
            startStarted.signal()
        }
        streamingRecorder.startSemaphore = finishStart
        let recorder = AppScopedDictationRecorder(
            recorder: streamingRecorder,
            prepareQueue: DispatchQueue(label: "test.app-scoped-dictation.prepare.startup-cancel")
        )

        let startQueue = DispatchQueue(label: "test.app-scoped-dictation.start")
        startQueue.async {
            _ = try? recorder.start()
        }

        #expect(startStarted.wait(timeout: .now() + 1) == .success)
        DispatchQueue.global(qos: .userInitiated).async {
            recorder.cancel()
            cancelReturned.signal()
        }

        #expect(cancelReturned.wait(timeout: .now() + 0.1) == .timedOut)
        finishStart.signal()
        #expect(cancelReturned.wait(timeout: .now() + 1) == .success)
        startQueue.sync {}

        #expect(streamingRecorder.startCalls == 1)
        #expect(streamingRecorder.cancelCalls >= 1)
    }

    @Test("stale startup failure after cancel does not cancel child twice")
    func staleStartupFailureAfterCancelDoesNotCancelChildTwice() throws {
        let error = NSError(domain: "AppScopedDictationRecorderTests", code: 2)
        let streamingRecorder = FakeStreamingRecorder()
        let startStarted = DispatchSemaphore(value: 0)
        let finishStart = DispatchSemaphore(value: 0)
        let cancelReturned = DispatchSemaphore(value: 0)
        streamingRecorder.onStartStarted = {
            startStarted.signal()
        }
        streamingRecorder.startSemaphore = finishStart
        streamingRecorder.startError = error
        let recorder = AppScopedDictationRecorder(
            recorder: streamingRecorder,
            prepareQueue: DispatchQueue(label: "test.app-scoped-dictation.prepare.stale-start-failure")
        )

        let startQueue = DispatchQueue(label: "test.app-scoped-dictation.stale-start-failure")
        startQueue.async {
            _ = try? recorder.start()
        }

        #expect(startStarted.wait(timeout: .now() + 1) == .success)
        DispatchQueue.global(qos: .userInitiated).async {
            recorder.cancel()
            cancelReturned.signal()
        }

        #expect(cancelReturned.wait(timeout: .now() + 0.1) == .timedOut)
        finishStart.signal()
        #expect(cancelReturned.wait(timeout: .now() + 1) == .success)
        startQueue.sync {}

        #expect(streamingRecorder.startCalls == 1)
        #expect(streamingRecorder.cancelCalls == 1)
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
    var onStartStarted: (() -> Void)?
    var startSemaphore: DispatchSemaphore?
    var startError: Error?

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
        onStartStarted?()
        startSemaphore?.wait()
        if let startError {
            throw startError
        }
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
