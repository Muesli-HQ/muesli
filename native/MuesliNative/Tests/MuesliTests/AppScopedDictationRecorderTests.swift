import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("AppScopedDictationRecorder")
struct AppScopedDictationRecorderTests {
    @Test("stop forwards the final drained buffer and rejects late callbacks after reuse")
    func stopDrainsCurrentRecordingOnly() throws {
        let child = FakeStreamingRecorder()
        child.stopSamples = [0.25, -0.5]
        let recorder = AppScopedDictationRecorder(recorder: child)
        var received: [[Float]] = []
        recorder.onAudioBuffer = { received.append($0) }
        let firstID = try recorder.start()
        let oldAudio = child.onAudioBuffer
        _ = recorder.stop()
        #expect(received == [[0.25, -0.5]])
        oldAudio?([0.75])
        #expect(received.count == 1)

        let nextID = try recorder.start()
        #expect(nextID != firstID)
        oldAudio?([0.9])
        child.onAudioBuffer?([0.1])
        #expect(received == [[0.25, -0.5], [0.1]])
        recorder.cancel()
    }

    @Test("cancellation during blocked stop suppresses the remaining drain")
    func cancelRetiresCallbacksDuringStop() async throws {
        let child = FakeStreamingRecorder()
        let stopStarted = AsyncStream<Void>.makeStream()
        let finishStop = DispatchSemaphore(value: 0)
        let stopReturned = AsyncStream<Void>.makeStream()
        let cancelReturned = AsyncStream<Void>.makeStream()
        child.onStopStarted = { stopStarted.continuation.yield() }
        child.stopSemaphore = finishStop
        child.stopSamples = [0.75]
        let recorder = AppScopedDictationRecorder(recorder: child)
        let counter = CapturedBufferCounter()
        recorder.onAudioBuffer = { _ in counter.increment() }
        _ = try recorder.start()
        let audio = child.onAudioBuffer
        // Dedicated threads own the intentionally blocking recorder operations;
        // neither the test executor nor the shared dispatch pool waits on them.
        Thread.detachNewThread {
            _ = recorder.stop()
            stopReturned.continuation.yield()
            stopReturned.continuation.finish()
        }
        var starts = stopStarted.stream.makeAsyncIterator()
        _ = await starts.next()
        stopStarted.continuation.finish()
        Thread.detachNewThread {
            recorder.cancel()
            cancelReturned.continuation.yield()
            cancelReturned.continuation.finish()
        }
        // Observe identity retirement directly through the captured callback.
        // Cancellation cannot return until the blocked child stop is released.
        var retired = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            let before = counter.value
            audio?([0.1])
            if counter.value == before { retired = true; break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        // Under a loaded test executor the suspended poll can resume after its
        // deadline even though cancellation already retired the identity.
        if !retired {
            let before = counter.value
            audio?([0.1])
            retired = counter.value == before
        }
        #expect(retired)
        let countAtCancellation = counter.value
        finishStop.signal()
        var stops = stopReturned.stream.makeAsyncIterator()
        var cancellations = cancelReturned.stream.makeAsyncIterator()
        _ = await stops.next()
        _ = await cancellations.next()
        #expect(counter.value == countAtCancellation)
        audio?([0.9])
        #expect(counter.value == countAtCancellation)
    }

    @Test("accepted audio keeps its original sink when a callback replaces the recording")
    func replacementDuringDelivery() throws {
        let child = FakeStreamingRecorder()
        let recorder = AppScopedDictationRecorder(recorder: child)
        var oldBuffers = 0
        var newBuffers = 0
        recorder.onAudioBuffer = { _ in oldBuffers += 1 }
        recorder.onFirstCapturedAudioBuffer = { [weak recorder] _ in
            guard let recorder else { return }
            recorder.cancel()
            recorder.onFirstCapturedAudioBuffer = nil
            recorder.onAudioBuffer = { _ in newBuffers += 1 }
            _ = try? recorder.start()
        }
        _ = try recorder.start()
        child.onAudioBuffer?([0.25])
        #expect(oldBuffers == 1 && newBuffers == 0)
        child.onAudioBuffer?([0.5])
        #expect(newBuffers == 1)
        recorder.cancel()
    }

    @Test("previous recording callbacks cannot populate or fail a replacement recording")
    func retiredCallbacksAfterReuse() throws {
        let child = FakeStreamingRecorder()
        let recorder = AppScopedDictationRecorder(recorder: child)
        _ = try recorder.start()
        let oldAudio = child.onAudioBuffer
        let oldFailure = child.onRecordingFailed
        recorder.cancel()
        var buffers = 0
        var failures = 0
        var firstBuffers = 0
        recorder.onAudioBuffer = { _ in buffers += 1 }
        recorder.onRecordingFailed = { _, _ in failures += 1 }
        recorder.onFirstCapturedAudioBuffer = { _ in firstBuffers += 1 }
        _ = try recorder.start()
        oldAudio?([0.25])
        oldFailure?(NSError(domain: "old recording", code: 1))
        #expect(buffers == 0 && failures == 0 && firstBuffers == 0)
        child.onAudioBuffer?([0.5])
        #expect(buffers == 1 && firstBuffers == 1)
        recorder.cancel()
    }

    @Test("audio buffers are forwarded without changing capture callbacks")
    func audioBuffersAreForwarded() throws {
        let streamingRecorder = FakeStreamingRecorder()
        let recorder = AppScopedDictationRecorder(
            recorder: streamingRecorder,
            prepareQueue: DispatchQueue(label: "test.app-scoped-dictation.audio-forwarding")
        )
        var received: [[Float]] = []
        var firstBufferCount = 0
        recorder.onAudioBuffer = { received.append($0) }
        recorder.onFirstCapturedAudioBuffer = { _ in firstBufferCount += 1 }

        _ = try recorder.start()
        streamingRecorder.onAudioBuffer?([0.25, -0.5])
        streamingRecorder.onAudioBuffer?([0.75])

        #expect(received == [[0.25, -0.5], [0.75]])
        #expect(firstBufferCount == 1)
    }

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

    @Test("stop finalizes recording and keeps the child graph warm")
    func stopKeepsChildRecorderGraphWarm() throws {
        let streamingRecorder = FakeStreamingRecorder()
        let recorder = AppScopedDictationRecorder(
            recorder: streamingRecorder,
            prepareQueue: DispatchQueue(label: "test.app-scoped-dictation.prepare.stop-teardown")
        )

        _ = try recorder.start()
        _ = recorder.stop()

        #expect(streamingRecorder.startCalls == 1)
        #expect(streamingRecorder.stopCalls == 1)
        #expect(streamingRecorder.cancelCalls == 0)
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
    var onStopStarted: (() -> Void)?
    var stopSemaphore: DispatchSemaphore?
    var stopSamples: [Float]?

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
        let audio = onAudioBuffer
        onStopStarted?()
        stopSemaphore?.wait()
        if let stopSamples { audio?(stopSamples) }
        return nil
    }

    func cancel() {
        cancelCalls += 1
    }

    func currentPower() -> Float {
        -160
    }
}

private final class CapturedBufferCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
