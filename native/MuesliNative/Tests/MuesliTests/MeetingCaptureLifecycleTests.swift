import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting capture lifetime")
struct MeetingCaptureLifecycleTests {
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

private final class LifetimeMicrophone: MeetingMicRecording {
    var preferredInputDeviceID: AudioObjectID?
    var onRawPCMSamples: (([Int16]) -> Void)?
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
