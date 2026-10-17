import CoreAudio
import AVFoundation
import Foundation
import Testing
import os
@testable import MuesliNativeApp

@Suite("Meeting capture lifetime")
struct MeetingCaptureLifecycleTests {
    enum BufferedSource: CaseIterable { case direct, fallbackAfterPrepareFailure, fallbackAfterStartFailure }

    @Test("retired buffered source cannot reenter a paused unbuffered replacement or stop", arguments: [false, true])
    func bufferedHandoffTail(stopBeforeDelivery: Bool) async throws {
        let producer = BufferedLifetimeRecorder()
        let adapter = StreamingMeetingMicRecorderAdapter(recorder: producer, kind: .systemDefaultStreaming)
        let replacement = LifetimeMicrophone()
        let lifecycle = DispatchQueue(label: "test.buffered-handoff.lifecycle")
        let worker = DispatchQueue(label: "test.buffered-handoff.worker")
        let cleanup = DispatchQueue(label: "test.buffered-handoff.cleanup")
        let mic = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: adapter, appScopedRecorder: replacement,
            lifecycleQueue: lifecycle, handoffWorkerQueue: worker, cleanupQueue: cleanup,
            handoffTimeoutScheduler: { _, _ in }
        )
        let capture = MeetingCaptureLifecycle(microphone: mic, systemAudio: LifetimeSystemAudio())
        let received = OSAllocatedUnfairLock(initialState: [Int16]())
        mic.onRawPCMSamples = { samples in
            if capture.acceptsMicrophoneSamples(samples) { received.withLock { $0.append(contentsOf: samples.samples) } }
        }
        defer { producer.releaseDelivery.signal(); mic.onRawPCMSamples = nil }
        try await capture.start()
        try producer.emit(0.25)
        for await _ in producer.deliveryEntered.stream { break }
        try producer.emit(0.5)
        #expect(mic.requestHealthRecovery(.init(reason: "tail regression", requiresNonZeroSamples: false)) == .initiated)
        try await MeetingCaptureLifecycle.onDriverQueue { worker.sync {} }
        replacement.emit([1], at: 102, admitted: true)
        try await MeetingCaptureLifecycle.onDriverQueue { lifecycle.sync {} }
        #expect(mic.activeRecorderKindForDebug() == .appScoped)
        #expect(capture.setPaused(true))
        #expect(!mic.hasBufferedSampleAdmission) // Replacement cannot borrow old admission privileges.
        replacement.emit([99], at: 103) // Cannot borrow the retired producer's admission.
        try producer.emit(0.75) // Old graph's admission is already closed.
        if stopBeforeDelivery {
            let shutdown = capture.requestStop()
            producer.releaseDelivery.signal()
            #expect(!(await shutdown.value).timedOut)
        } else {
            producer.releaseDelivery.signal()
            try await MeetingCaptureLifecycle.onDriverQueue { cleanup.sync {} }
            #expect(!mic.hasBufferedSampleAdmission)
            #expect(!(await capture.requestStop().value).timedOut)
        }
        #expect(received.withLock { $0 } == [1]) // Old producer backlog is rejected after the source switch.
        capture.finishMicrophoneDelivery()
        #expect(!capture.acceptsMicrophoneSamples())
    }

    @Test("buffered meeting mic preserves pre-pause audio and rejects input throughout pause", arguments: [false, true], BufferedSource.allCases)
    func bufferedPauseTail(stopBeforeDelivery: Bool, source: BufferedSource) async throws {
        let producer = BufferedLifetimeRecorder()
        let recording: StreamingDictationRecording
        switch source {
        case .direct: recording = producer
        case .fallbackAfterPrepareFailure, .fallbackAfterStartFailure:
            recording = FallbackStreamingDictationRecorder(
                primary: FailingLifetimeRecorder(failPrepare: source == .fallbackAfterPrepareFailure),
                fallback: producer
            )
        }
        let adapter = StreamingMeetingMicRecorderAdapter(recorder: recording, kind: .systemDefaultStreaming)
        let mic = RouteAwareMeetingMicRecorder(systemDefaultRecorder: adapter)
        let capture = MeetingCaptureLifecycle(microphone: mic, systemAudio: LifetimeSystemAudio())
        let received = OSAllocatedUnfairLock(initialState: [Int16]())
        let delivered = DispatchSemaphore(value: 0)
        mic.onRawPCMSamples = { samples in
            if capture.acceptsMicrophoneSamples(samples) { received.withLock { $0.append(contentsOf: samples.samples) } }
            delivered.signal()
        }
        defer { producer.releaseDelivery.signal(); producer.releasePause.signal(); mic.onRawPCMSamples = nil }
        try await capture.start()
        try producer.emit(0.25)
        for await _ in producer.deliveryEntered.stream { break }
        try producer.emit(0.5) // Accepted, but blocked behind the first consumer.
        #expect(capture.setPaused(true))
        for await _ in producer.pauseEntered.stream { break }
        // The driver pause has not run yet. The lifecycle admission gate must
        // already reject this input without waiting for that driver operation.
        try producer.emit(0.75)
        producer.releasePause.signal()
        for await _ in producer.pauseCompleted.stream { break }
        try producer.emit(0.75)
        #expect(mic.hasBufferedSampleAdmission)

        let shutdown: Task<MeetingCaptureShutdown.Result, Never>
        if stopBeforeDelivery {
            shutdown = capture.requestStop()
            producer.releaseDelivery.signal()
        } else {
            producer.releaseDelivery.signal()
            let drained = try await MeetingCaptureLifecycle.onDriverQueue {
                delivered.wait(timeout: .now() + 5) == .success
                    && delivered.wait(timeout: .now() + 5) == .success
            }
            #expect(drained)
            #expect(received.withLock { $0 } == [8191, 16383])
            #expect(capture.setPaused(false))
            for await _ in producer.resumeCompleted.stream { break }
            try producer.emit(0.125)
            shutdown = capture.requestStop()
        }
        let result = await shutdown.value
        #expect(!result.timedOut)
        let url = try #require(result.microphone)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let expected: [Int16] = stopBeforeDelivery ? [8191, 16383] : [8191, 16383, 4095]
        #expect(data.count == 44 + expected.count * 2)
        #expect(received.withLock { $0 } == expected)
        capture.finishMicrophoneDelivery()
        try producer.emit(0.75)
        #expect(!capture.acceptsMicrophoneSamples())
    }

    @Test("early and repeated stop preserve accepted mic delivery until the session barrier", arguments: [false, true])
    func earlyStopPreservesMicrophoneDrain(startCapture: Bool) async throws {
        let mic = LifetimeMicrophone()
        let capture = MeetingCaptureLifecycle(microphone: mic, systemAudio: LifetimeSystemAudio())
        if startCapture { try await capture.start() }
        let received = OSAllocatedUnfairLock(initialState: [Int16]())
        mic.onRawPCMSamples = { samples in
            if capture.acceptsMicrophoneSamples(samples) { received.withLock { $0.append(contentsOf: samples.samples) } }
        }
        mic.stopAction = { mic.emit([1, 2, 3]) }
        defer { mic.onRawPCMSamples = nil; mic.stopAction = {} }
        // Same ordering as the controller: beginStoppingCapture, then session.stop.
        let earlyShutdown = capture.requestStop()
        _ = await earlyShutdown.value
        #expect(capture.phase == .stopped)
        _ = await capture.requestStop().value
        // Delivery already queued by the mic may run after native quiescence.
        mic.emit([4])
        #expect(received.withLock { $0 } == [1, 2, 3, 4])
        capture.finishMicrophoneDelivery()
        mic.emit([5])
        _ = await capture.requestStop().value
        #expect(!capture.acceptsMicrophoneSamples())
        #expect(received.withLock { $0 } == [1, 2, 3, 4])
        #expect(mic.stopCount == 1)
    }

    @Test("unbuffered paused stop and discard never admit microphone tail", arguments: [false, true])
    func closedMicrophoneDrain(discard: Bool) async throws {
        let mic = LifetimeMicrophone()
        let capture = MeetingCaptureLifecycle(microphone: mic, systemAudio: LifetimeSystemAudio())
        try await capture.start()
        if discard { capture.finishMicrophoneDelivery() }
        else { #expect(capture.setPaused(true)) }
        mic.stopAction = { #expect(!capture.acceptsMicrophoneSamples()) }
        defer { mic.stopAction = {} }
        _ = await capture.requestStop().value
        #expect(!capture.acceptsMicrophoneSamples())
        _ = await capture.requestStop().value
        #expect(!capture.acceptsMicrophoneSamples())
    }

    @Test("closing session delivery rejects callbacks from a still-retiring driver")
    func closeBeforeDriverQuiesces() async throws {
        let mic = LifetimeMicrophone()
        let capture = MeetingCaptureLifecycle(microphone: mic, systemAudio: LifetimeSystemAudio())
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        mic.stopAction = {
            entered.continuation.yield(())
            #expect(release.wait(timeout: .now() + 5) == .success)
            #expect(!capture.acceptsMicrophoneSamples())
        }
        defer { mic.stopAction = {} }
        try await capture.start()
        let shutdown = capture.requestStop()
        for await _ in entered.stream { break }
        #expect(capture.acceptsMicrophoneSamples())
        // The session's deadline/discard barrier must not wait for native stop.
        capture.finishMicrophoneDelivery()
        release.signal()
        _ = await shutdown.value
        #expect(!capture.acceptsMicrophoneSamples())
    }

    enum Stage: CaseIterable { case microphonePrepare, systemStart, microphoneStart }

    @Test("cancellation returns while a driver is blocked, stops the other track, and rejects late stages", arguments: Stage.allCases)
    func cancellationDuringStart(stage: Stage) async throws {
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let otherStopped = DispatchSemaphore(value: 0)
        let mic = LifetimeMicrophone()
        let system = LifetimeSystemAudio()
        let blocked = {
            #expect(!Thread.isMainThread)
            entered.continuation.yield(())
            #expect(release.wait(timeout: .now() + 5) == .success)
        }
        switch stage {
        case .microphonePrepare: mic.prepareAction = blocked
        case .microphoneStart: mic.startAction = blocked
        case .systemStart: system.startAction = blocked
        }
        if stage == .systemStart { mic.stopAction = { otherStopped.signal() } }
        else { system.stopAction = { otherStopped.signal() } }
        let capture = MeetingCaptureLifecycle(microphone: mic, systemAudio: system)
        let start = Task { try await capture.start() }
        for await _ in entered.stream { break }
        #expect(capture.phase == .preparing)
        #expect(!capture.phase.isRecording)
        start.cancel()
        do { try await start.value; Issue.record("Cancelled capture became ready") }
        catch { #expect(error is CancellationError) }
        #expect(await Task.detached { otherStopped.wait(timeout: .now() + 1) == .success }.value)
        #expect(capture.phase == .stopping)
        #expect(!capture.setPaused(false))
        release.signal()
        let result = await capture.stop()
        #expect(!result.timedOut)
        #expect(capture.phase == .stopped)
        #expect(mic.stopCount == 1)
        #expect(system.stopCount == 1)
        if stage != .microphoneStart { #expect(mic.startCount == 0) }
        if stage == .microphonePrepare { #expect(system.startCount == 0) }
        // Every caller joins the same shutdown; no duplicate native teardown.
        _ = await capture.stop()
        #expect(mic.stopCount == 1)
        #expect(system.stopCount == 1)
    }

    @Test("startup deadline reports unready without releasing driver ownership")
    func startupDeadline() async throws {
        let release = DispatchSemaphore(value: 0)
        let entered = AsyncStream<Void>.makeStream()
        let mic = LifetimeMicrophone()
        mic.prepareAction = {
            entered.continuation.yield(())
            #expect(release.wait(timeout: .now() + 5) == .success)
        }
        let capture = MeetingCaptureLifecycle(microphone: mic, systemAudio: LifetimeSystemAudio())
        let start = Task { try await capture.start(timeout: 0.1) }
        for await _ in entered.stream { break }
        do { try await start.value; Issue.record("Blocked start became ready") }
        catch { #expect(error is MeetingCaptureLifecycle.StartError) }
        #expect(capture.phase == .stopping)
        #expect(!capture.setPaused(false))
        release.signal()
        _ = await capture.stop()
        #expect(capture.phase == .stopped)
        #expect(mic.startCount == 0)
    }

    @Test("pause is idempotent and stop prevents every return to capture")
    func pauseAndStop() async throws {
        let mic = LifetimeMicrophone()
        let system = LifetimeSystemAudio()
        let release = DispatchSemaphore(value: 0)
        mic.stopAction = { #expect(release.wait(timeout: .now() + 5) == .success) }
        let capture = MeetingCaptureLifecycle(microphone: mic, systemAudio: system)
        #expect(!capture.setPaused(true))
        try await capture.start()
        #expect(capture.phase == .capturing)
        #expect(capture.phase.acceptsSamples)
        #expect(capture.setPaused(true))
        #expect(capture.phase == .paused)
        #expect(capture.phase.isRecording)
        #expect(!capture.phase.acceptsSamples)
        #expect(!capture.setPaused(true))
        #expect(capture.setPaused(false))
        #expect(capture.phase == .capturing)
        #expect(!capture.setPaused(false))
        capture.requestStop()
        #expect(capture.phase == .stopping)
        #expect(!capture.phase.isRecording)
        #expect(!capture.phase.acceptsSamples)
        #expect(!capture.setPaused(true))
        #expect(!capture.setPaused(false))
        release.signal()
        _ = await capture.stop()
        #expect(capture.phase == .stopped)
        #expect(!capture.setPaused(false))
        do { try await capture.start(); Issue.record("Stopped capture restarted") }
        catch { #expect(error is CancellationError) }
        #expect(mic.pauseCount == 1 && mic.resumeCount == 1)
        #expect(system.pauseCount == 1 && system.resumeCount == 1)
        #expect(mic.startCount == 1 && system.startCount == 1)
    }

    @Test("system recording callbacks stay on the file timeline across pause")
    func systemSamplesRemainDeliverableUntilTheRecordingBarrier() async throws {
        let capture = MeetingCaptureLifecycle(
            microphone: LifetimeMicrophone(), systemAudio: LifetimeSystemAudio()
        )
        let queue = DispatchQueue(label: "test.capture.system-timeline")
        let received = OSAllocatedUnfairLock(initialState: [Int16]())
        func emitRecordedSamples(_ sample: Int16) {
            capture.enqueueSystemSamples(on: queue) { received.withLock { $0.append(sample) } }
        }
        func drain() { queue.sync {} }

        try await capture.start()
        emitRecordedSamples(1)
        drain()

        #expect(capture.setPaused(true))
        // The native recorder can deliver a callback it already wrote while
        // its pause operation is still taking effect.
        emitRecordedSamples(2)
        drain()
        #expect(received.withLock { $0 } == [1, 2])

        #expect(capture.setPaused(false))
        emitRecordedSamples(3)
        drain()
        #expect(received.withLock { $0 } == [1, 2, 3])

        let shutdown = capture.requestStop()
        emitRecordedSamples(4)
        drain()
        #expect(received.withLock { $0 } == [1, 2, 3, 4])
        _ = await shutdown.value

        capture.finishMicrophoneDelivery()
        emitRecordedSamples(5)
        drain()
        #expect(received.withLock { $0 } == [1, 2, 3, 4])
    }

    @Test("failed system startup releases prepared microphone without starting it")
    func failedStart() async {
        let mic = LifetimeMicrophone()
        let system = LifetimeSystemAudio()
        system.startError = NSError(domain: "test.capture", code: 1)
        let capture = MeetingCaptureLifecycle(microphone: mic, systemAudio: system)
        do { try await capture.start(); Issue.record("Failed system capture became ready") }
        catch { #expect((error as NSError).domain == "test.capture") }
        _ = await capture.stop()
        #expect(mic.startCount == 0)
        #expect(mic.stopCount == 1)
        #expect(system.stopCount == 1)
    }
}

/// Real bounded recorder and meeting adapter, with only native graph startup
/// replaced. Gates model a delayed worker and delayed driver pause independently.
private final class BufferedLifetimeRecorder: StreamingDictationRecording, PausableStreamingDictationRecording, MicrophoneCaptureReporting {
    private let recorder = StreamingMicRecorder(directoryName: "meeting-pause-tail-tests")
    private var tap: AVAudioNodeTapBlock?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var firstDelivery = true // Recorder processing queue only.
    private var nextFrame: Int64 = 100
    let deliveryEntered = AsyncStream<Void>.makeStream()
    let pauseEntered = AsyncStream<Void>.makeStream()
    let pauseCompleted = AsyncStream<Void>.makeStream()
    let resumeCompleted = AsyncStream<Void>.makeStream()
    let releaseDelivery = DispatchSemaphore(value: 0)
    let releasePause = DispatchSemaphore(value: 0)
    var onCapturedAudio: ((MicrophoneCaptureAudio) -> Void)?
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var preferredInputDeviceID: AudioObjectID?
    var shouldAdmitSamples: (() -> Bool)? {
        get { recorder.shouldAdmitSamples }
        set { recorder.shouldAdmitSamples = newValue }
    }
    func prepare() throws {}
    func start() throws {
        recorder.onCapturedAudio = { [weak self] samples in
            guard let self else { return }
            if firstDelivery {
                firstDelivery = false
                deliveryEntered.continuation.yield(())
                #expect(releaseDelivery.wait(timeout: .now() + 5) == .success)
            }
            onCapturedAudio?(samples)
        }
        tap = try recorder.testing_startWithTap(format: format)
    }
    func emit(_ sample: Float) throws {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = sample
        tap?(buffer, AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: Double(nextFrame) / 16_000)))
        nextFrame += 1
    }
    func pause() {
        pauseEntered.continuation.yield(())
        #expect(releasePause.wait(timeout: .now() + 5) == .success)
        recorder.pause()
        pauseCompleted.continuation.yield(())
    }
    func resume() {
        recorder.resume()
        resumeCompleted.continuation.yield(())
    }
    func stop() -> URL? { recorder.stop() }
    func drainAcceptedAudio() { recorder.drainAcceptedAudio() }
    func cancel() { recorder.cancel() }
    func currentPower() -> Float { recorder.currentPower() }
    func invalidateForTeardown() { recorder.invalidateForTeardown() }
}

private final class FailingLifetimeRecorder: StreamingDictationRecording {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var preferredInputDeviceID: AudioObjectID?
    let failPrepare: Bool
    init(failPrepare: Bool) { self.failPrepare = failPrepare }
    func prepare() throws { if failPrepare { throw NSError(domain: "test.prepare", code: 1) } }
    func start() throws { throw NSError(domain: "test.start", code: 1) }
    func stop() -> URL? { nil }
    func cancel() {}
    func currentPower() -> Float { -160 }
}

private final class LifetimeMicrophone: MeetingMicRecording {
    var preferredInputDeviceID: AudioObjectID?
    var onRawPCMSamples: ((MicrophoneCaptureAudio) -> Void)?
    func emit(_ samples: [Int16], at frame: Int64? = nil, admitted: Bool = false) {
        onRawPCMSamples?(MicrophoneCaptureAudio(samples: samples,
            startFrame: frame ?? MicrophoneCaptureAudio.frame(atHostTime: mach_absolute_time()), admitted: admitted))
    }
    var onRecordingFailed: ((Error) -> Void)?
    var onHandoffOutcome: ((MeetingMicHandoffOutcome) -> Void)?
    var prepareAction: () -> Void = {}
    var startAction: () -> Void = {}
    var stopAction: () -> Void = {}
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func prepare() throws { prepareAction() }
    func start() throws { startCount += 1; startAction() }
    func stop() -> URL? { stopCount += 1; stopAction(); return nil }
    func cancel() { _ = stop() }
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }
    func currentPower() -> Float { -160 }
    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        .init(recorderKind: .systemDefaultStreaming, preferredInputDeviceID: nil, route: nil)
    }
}

private final class LifetimeSystemAudio: SystemAudioCapturing {
    var onPCMSamples: (([Int16]) -> Void)?
    let isRecording = false
    let isPaused = false
    var startAction: () -> Void = {}
    var stopAction: () -> Void = {}
    var startError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start() async throws {
        try await MeetingCaptureLifecycle.onDriverQueue { [self] in
            startCount += 1
            startAction()
            if let startError { throw startError }
        }
    }
    func stop() -> URL? { stopCount += 1; stopAction(); return nil }
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }
}
