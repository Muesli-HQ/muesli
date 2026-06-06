import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("RouteAwareDictationRecorder")
struct RouteAwareDictationRecorderTests {
    @Test("default input uses system default recorder")
    func defaultInputUsesSystemDefaultRecorder() throws {
        let system = FakeRouteAwareChildRecorder()
        let appScoped = FakeRouteAwareChildRecorder()
        let recorder = RouteAwareDictationRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)

        try recorder.activateWarmEngine(preferredInputDeviceID: nil)
        _ = try recorder.start()

        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(system.activateCalls == 1)
        #expect(system.startCalls == 1)
        #expect(appScoped.activateCalls == 0)
        #expect(appScoped.startCalls == 0)
    }

    @Test("preferred input uses app scoped recorder")
    func preferredInputUsesAppScopedRecorder() throws {
        let system = FakeRouteAwareChildRecorder()
        let appScoped = FakeRouteAwareChildRecorder()
        let recorder = RouteAwareDictationRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)

        try recorder.activateWarmEngine(preferredInputDeviceID: 82)
        _ = try recorder.start()

        #expect(recorder.activeRecorderKindForDebug() == .appScoped)
        #expect(system.activateCalls == 0)
        #expect(system.startCalls == 0)
        #expect(appScoped.activateCalls == 1)
        #expect(appScoped.startCalls == 1)
        #expect(appScoped.preferredInputDeviceID == 82)
    }

    @Test("preferred input start without pre-activation uses app scoped recorder")
    func preferredInputStartWithoutPreActivationUsesAppScopedRecorder() throws {
        let system = FakeRouteAwareChildRecorder()
        let appScoped = FakeRouteAwareChildRecorder()
        let recorder = RouteAwareDictationRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)

        recorder.preferredInputDeviceID = 82
        _ = try recorder.start()

        #expect(recorder.activeRecorderKindForDebug() == .appScoped)
        #expect(system.activateCalls == 0)
        #expect(system.startCalls == 0)
        #expect(appScoped.activateCalls == 0)
        #expect(appScoped.startCalls == 1)
        #expect(appScoped.preferredInputDeviceID == 82)
    }

    @Test("preferred input explicit warmup uses app scoped recorder")
    func preferredInputExplicitWarmupUsesAppScopedRecorder() {
        let system = FakeRouteAwareChildRecorder()
        let appScoped = FakeRouteAwareChildRecorder()
        let recorder = RouteAwareDictationRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)

        recorder.beginExplicitWarmup(preferredInputDeviceID: 82)

        #expect(recorder.activeRecorderKindForDebug() == .appScoped)
        #expect(system.explicitWarmupCalls == 0)
        #expect(appScoped.explicitWarmupCalls == 1)
        #expect(appScoped.preferredInputDeviceID == 82)
    }


    @Test("latency events are forwarded from active child recorder")
    func latencyEventsAreForwardedFromActiveChildRecorder() throws {
        let system = FakeRouteAwareChildRecorder()
        let appScoped = FakeRouteAwareChildRecorder()
        let recorder = RouteAwareDictationRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)
        var events: [String] = []
        recorder.onLatencyEvent = { event, _ in
            events.append(event)
        }

        recorder.preferredInputDeviceID = 82
        _ = try recorder.start()
        appScoped.onLatencyEvent?("app_scoped_engine_start_end", Date())

        #expect(events == ["app_scoped_engine_start_end"])
    }

    @Test("callbacks from inactive child recorder are ignored")
    func callbacksFromInactiveChildRecorderAreIgnored() throws {
        let system = FakeRouteAwareChildRecorder()
        let appScoped = FakeRouteAwareChildRecorder()
        let recorder = RouteAwareDictationRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)
        var firstBufferCount = 0
        var speechCount = 0
        var timeoutCount = 0
        var failureCount = 0
        var latencyEvents: [String] = []
        recorder.onFirstCapturedAudioBuffer = { _ in firstBufferCount += 1 }
        recorder.onFirstSpeechDetected = { _ in speechCount += 1 }
        recorder.onNoAudioTimeout = { _ in timeoutCount += 1 }
        recorder.onRecordingFailed = { _, _ in failureCount += 1 }
        recorder.onLatencyEvent = { event, _ in latencyEvents.append(event) }

        _ = try recorder.start()
        appScoped.onFirstCapturedAudioBuffer?(Date())
        appScoped.onFirstSpeechDetected?(Date())
        appScoped.onNoAudioTimeout?(Date())
        appScoped.onRecordingFailed?(NSError(domain: "RouteAwareDictationRecorderTests", code: 1), UUID())
        appScoped.onLatencyEvent?("inactive_latency", Date())
        system.onFirstCapturedAudioBuffer?(Date())
        system.onLatencyEvent?("active_latency", Date())

        #expect(firstBufferCount == 1)
        #expect(speechCount == 0)
        #expect(timeoutCount == 0)
        #expect(failureCount == 0)
        #expect(latencyEvents == ["active_latency"])
    }

    @Test("switching recorder cancels inactive warmed graph")
    func switchingRecorderCancelsInactiveWarmedGraph() throws {
        let system = FakeRouteAwareChildRecorder()
        let appScoped = FakeRouteAwareChildRecorder()
        let recorder = RouteAwareDictationRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)

        try recorder.warmUp(preferredInputDeviceID: nil)
        try recorder.activateWarmEngine(preferredInputDeviceID: 82)

        #expect(recorder.activeRecorderKindForDebug() == .appScoped)
        #expect(system.warmUpCalls == 1)
        #expect(system.cancelCalls == 1)
        #expect(appScoped.activateCalls == 1)
    }

    @Test("cool down tears down both recorder graphs")
    func coolDownTearsDownBothRecorderGraphs() {
        let system = FakeRouteAwareChildRecorder()
        let appScoped = FakeRouteAwareChildRecorder()
        let recorder = RouteAwareDictationRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)

        recorder.coolDown()

        #expect(system.coolDownCalls == 1)
        #expect(appScoped.coolDownCalls == 1)
    }

    @Test("route switch waits for in-flight app scoped explicit warmup teardown")
    func routeSwitchWaitsForInFlightAppScopedExplicitWarmupTeardown() throws {
        let system = FakeRouteAwareChildRecorder()
        let appScopedStreaming = FakeRouteAwareStreamingRecorder()
        let prepareStarted = DispatchSemaphore(value: 0)
        let finishPrepare = DispatchSemaphore(value: 0)
        let routeSwitchReturned = DispatchSemaphore(value: 0)
        appScopedStreaming.onPrepareStarted = {
            prepareStarted.signal()
        }
        appScopedStreaming.prepareSemaphore = finishPrepare
        let appScoped = AppScopedDictationRecorder(
            recorder: appScopedStreaming,
            prepareQueue: DispatchQueue(label: "test.route-aware.app-scoped.prepare.route-switch")
        )
        let recorder = RouteAwareDictationRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)

        recorder.beginExplicitWarmup(preferredInputDeviceID: 82)
        #expect(prepareStarted.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global(qos: .userInitiated).async {
            try? recorder.warmUp(preferredInputDeviceID: nil)
            routeSwitchReturned.signal()
        }

        #expect(routeSwitchReturned.wait(timeout: .now() + 0.1) == .timedOut)
        finishPrepare.signal()
        #expect(routeSwitchReturned.wait(timeout: .now() + 1) == .success)

        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(system.warmUpCalls == 1)
        #expect(appScopedStreaming.prepareCalls == 1)
        #expect(appScopedStreaming.cancelCalls >= 1)
    }
}

private final class FakeRouteAwareChildRecorder: DictationAudioRecording {
    var preferredInputDeviceID: AudioObjectID?
    var keepsAudioGraphWarm = false
    var onFirstCapturedAudioBuffer: ((Date) -> Void)?
    var onFirstSpeechDetected: ((Date) -> Void)?
    var onNoAudioTimeout: ((Date) -> Void)?
    var onRecordingFailed: ((Error, UUID) -> Void)?
    var onLatencyEvent: ((String, Date) -> Void)?

    var warmUpCalls = 0
    var explicitWarmupCalls = 0
    var activateCalls = 0
    var startCalls = 0
    var stopCalls = 0
    var coolDownCalls = 0
    var cancelCalls = 0

    func prepare() throws {}

    func beginExplicitWarmup(preferredInputDeviceID: AudioObjectID?) {
        explicitWarmupCalls += 1
        self.preferredInputDeviceID = preferredInputDeviceID
    }

    func warmUp(preferredInputDeviceID: AudioObjectID?) throws {
        warmUpCalls += 1
        self.preferredInputDeviceID = preferredInputDeviceID
    }

    func activateWarmEngine(preferredInputDeviceID: AudioObjectID?) throws {
        activateCalls += 1
        self.preferredInputDeviceID = preferredInputDeviceID
    }

    func coolDown() {
        coolDownCalls += 1
    }

    func start() throws -> UUID {
        startCalls += 1
        return UUID()
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

private final class FakeRouteAwareStreamingRecorder: StreamingDictationRecording {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var preferredInputDeviceID: AudioObjectID?

    var prepareCalls = 0
    var startCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var onPrepareStarted: (() -> Void)?
    var prepareSemaphore: DispatchSemaphore?

    func prepare() throws {
        prepareCalls += 1
        onPrepareStarted?()
        prepareSemaphore?.wait()
    }

    func start() throws {
        startCalls += 1
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
